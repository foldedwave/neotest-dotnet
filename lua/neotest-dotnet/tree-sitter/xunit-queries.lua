local attribute_utils = require("neotest-dotnet.frameworks.test-attribute-utils")

local M = {}

function M.get_queries(custom_attributes)
  -- Don't include parameterized test attribute indicators so we don't double count them
  local custom_fact_attributes = custom_attributes
      and attribute_utils.join_test_attributes(custom_attributes.xunit)
    or ""

  return [[
    ;; Matches XUnit test class (has no specific attributes on class)
    (class_declaration
      name: (identifier) @class.name
    ) @class.definition

    ;; Matches test methods
    (method_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute_name (#any-of? @attribute_name "Fact" ]] .. custom_fact_attributes .. [[)
        )
      )
      name: (identifier) @test.name
    ) @test.definition

    ;; Specflow - XUnit
    (method_declaration
      (attribute_list
        (attribute
          name: (qualified_name) @attribute_name (#match? @attribute_name "SkippableFactAttribute$")
        )
      )
      name: (identifier) @test.name
    ) @test.definition

    ;; Matches parameterized test methods
    (method_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute_name (#any-of? @attribute_name "Theory")
        )
      )
      name: (identifier) @test.parameterized.name
      parameters: (parameter_list
        (parameter
          name: (identifier)
        )*
      ) @parameter_list
    ) @test.parameterized.definition
  ]]
end

return M
