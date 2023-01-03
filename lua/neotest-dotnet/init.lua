local lib = require("neotest.lib")
local logger = require("neotest.logging")
local async = require("neotest.async")
local result_utils = require("neotest-dotnet.result-utils")
local trx_utils = require("neotest-dotnet.trx-utils")
local dap_utils = require("neotest-dotnet.dap-utils")
local framework_utils = require("neotest-dotnet.frameworks.test-framework-utils")
local attribute_utils = require("neotest-dotnet.frameworks.test-attribute-utils")
local scan = require("plenary.scandir")

local DotnetNeotestAdapter = { name = "neotest-dotnet" }
local dap_args
local custom_attribute_args

local function get_test_nodes_data(tree)
  local test_nodes = {}
  for _, node in tree:iter_nodes() do
    if node:data().type == "test" then
      table.insert(test_nodes, node)
    end
  end

  return test_nodes
end

DotnetNeotestAdapter.root = lib.files.match_root_pattern("**/*.csproj", "**/*.fsproj")

DotnetNeotestAdapter.is_test_file = function(file_path)
  if vim.endswith(file_path, ".cs") or vim.endswith(file_path, ".fs") then
    local content = lib.files.read(file_path)

    local found_derived_attribute
    local found_standard_test_attribute

    -- Combine all attribute list arrays into one
    local all_attributes = attribute_utils.all_test_attributes

    for _, test_attribute in ipairs(all_attributes) do
      if string.find(content, "%[" .. test_attribute) then
        found_standard_test_attribute = true
        break
      end
    end

    if custom_attribute_args then
      for _, framework_attrs in pairs(custom_attribute_args) do
        for _, value in ipairs(framework_attrs) do
          if string.find(content, "%[" .. value) then
            found_derived_attribute = true
            break
          end
        end
      end
    end

    return found_standard_test_attribute or found_derived_attribute
  else
    return false
  end
end

DotnetNeotestAdapter.filter_dir = function(name)
  return name ~= "bin" and name ~= "obj"
end

DotnetNeotestAdapter._build_position = function(...)
  return framework_utils.build_position(...)
end

DotnetNeotestAdapter._position_id = function(...)
  return framework_utils.position_id(...)
end

---Implementation of core neotest function.
---@param path any
---@return neotest.Tree
DotnetNeotestAdapter.discover_positions = function(path)
  local content = lib.files.read(path)
  local test_framework = framework_utils.get_test_framework_utils(content, custom_attribute_args)
  local framework_queries = test_framework.get_treesitter_queries(custom_attribute_args)

  local query = [[
    ;; --Namespaces
    ;; Matches namespace
    (namespace_declaration
      [
        name: (identifier) @namespace.name
        name: (qualified_name) @namespace.name
      ]
    ) @namespace.definition

    ;; Matches file-scoped namespaces
    (file_scoped_namespace_declaration
      [
        name: (identifier) @namespace.name
        name: (qualified_name) @namespace.name
      ]
    ) @namespace.definition
  ]] .. framework_queries

  local tree = lib.treesitter.parse_positions(path, query, {
    nested_namespaces = true,
    nested_tests = true,
    build_position = "require('neotest-dotnet')._build_position",
    position_id = "require('neotest-dotnet')._position_id",
  })

  return tree
end

local function build_single_spec(args, test_root, position, fqn, proj)
  local results_path = async.fn.tempname() .. ".trx"
  local filter = ""
  if position.type == "class" then
    filter = '--filter FullyQualifiedName~"' .. fqn .. '"'
  end
  if position.type == "namespace" then
    filter = '--filter FullyQualifiedName~"' .. fqn .. '"'
  end
  if position.type == "test" then
    -- Allow a more lenient 'contains' match for the filter, accepting tradeoff that it may
    -- also run tests with similar names. This allows us to run parameterized tests individually
    -- or as a group.
    filter = '--filter FullyQualifiedName~"' .. fqn .. '"'
  end

  local command = {
    "dotnet",
    "test",
    proj,
    filter,
    "--results-directory",
    vim.fn.fnamemodify(results_path, ":h"),
    "--logger",
    '"trx;logfilename=' .. vim.fn.fnamemodify(results_path, ":t:h") .. '"',
  }

  local command_string = table.concat(command, " ")
  local spec = {
    command = command_string,
    context = {
      results_path = results_path,
      file = test_root,
      id = test_root,
    },
  }

  if args.strategy == "dap" then
    local send_debug_start, await_debug_start = async.control.channel.oneshot()
    logger.debug("neotest-dotnet: Running tests in debug mode")

    dap_utils.start_debuggable_test(command_string, function(dotnet_test_pid)
      spec.strategy = dap_utils.get_dap_adapter_config(dotnet_test_pid, dap_args)
      spec.command = nil
      logger.debug("neotest-dotnet: Sending debug start")
      send_debug_start()
    end)

    await_debug_start()
  end

  return spec
end

DotnetNeotestAdapter.build_spec = function(args)
  local position = args.tree:data()
  local results_path = async.fn.tempname() .. ".trx"
  local fqn
  local segments = vim.split(position.id, "::")
  for _, segment in ipairs(segments) do
    if not (vim.fn.has("win32") and segment == "C") then
      if not string.find(segment, ".cs$") then
        -- Remove any test parameters as these don't work well with the dotnet filter formatting.
        segment = segment:gsub("%b()", "")
        fqn = fqn and fqn .. "." .. segment or segment
      end
    end
  end

  local project_dir = DotnetNeotestAdapter.root(position.path)

  -- This returns the directory of the .csproj or .fsproj file. The dotnet command works with the directory name, rather
  -- than the full path to the file.
  local test_root = project_dir

  local retval = {}
  for _, proj in ipairs(scan.scan_dir(test_root, {search_pattern = "**.csproj$"})) do
    local proj_root = DotnetNeotestAdapter.root(proj)
    table.insert(retval, build_single_spec(args, proj_root, position, fqn, proj))
  end
  for _, proj in ipairs(scan.scan_dir(test_root, {search_pattern = "**.fsproj$"})) do
    local proj_root = DotnetNeotestAdapter.root(proj)
    table.insert(retval, build_single_spec(args, proj_root, position, fqn, proj))
  end

  return retval
end

---@async
---@param spec neotest.RunSpec
---@param _ neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
DotnetNeotestAdapter.results = function(spec, _, tree)
  local output_file = spec.context.results_path
  local parsed_data = trx_utils.parse_trx(output_file)
  local test_results = parsed_data.TestRun and parsed_data.TestRun.Results
  local test_definitions = parsed_data.TestRun and parsed_data.TestRun.TestDefinitions

  -- No test results. Something went wrong. Check for runtime error
  if not test_results then
    return result_utils.get_runtime_error(spec.context.id)
  end

  local test_nodes = get_test_nodes_data(tree)

  for _, node in ipairs(test_nodes) do
    local full_name = string.gsub(node:data().id, node:data().path.."::", "")
    full_name = string.gsub(full_name, "::", ".");
    node:data().full_name = full_name
  end

  if #test_results.UnitTestResult > 1 then
    test_results = test_results.UnitTestResult
  end
  if #test_definitions.UnitTest > 1 then
    test_definitions = test_definitions.UnitTest
  end

  local test_nodes = get_test_nodes_data(tree)
  local intermediate_results = result_utils.create_intermediate_results(test_results, test_definitions)

  local neotest_results =
    result_utils.convert_intermediate_results(intermediate_results, test_nodes)

  return neotest_results
end

setmetatable(DotnetNeotestAdapter, {
  __call = function(_, opts)
    if type(opts.dap) == "table" then
      dap_args = opts.dap
    end
    if type(opts.custom_attributes) == "table" then
      custom_attribute_args = opts.custom_attributes
    end
    return DotnetNeotestAdapter
  end,
})

return DotnetNeotestAdapter
