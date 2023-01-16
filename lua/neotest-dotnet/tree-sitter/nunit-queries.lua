local attribute_utils = require("neotest-dotnet.frameworks.test-attribute-utils")

local M = {}

function M.get_queries(custom_attributes)
  -- Don't include parameterized test attribute indicators so we don't double count them
  local custom_test_attributes = custom_attributes
      and attribute_utils.join_test_attributes(custom_attributes.nunit)
      or ""

  return [[
    ;; Matches SpecFlow generated classes
    (class_declaration
      (attribute_list
        (attribute 
          (attribute_argument_list
            (attribute_argument
              (string_literal) @attribute_argument (#match? @attribute_argument "SpecFlow\"$")
            )
          )
        )
      ) 
      name: (identifier) @class.name
    ) @class.definition

    ;; Specflow - NUnit
    (method_declaration
      (attribute_list
        (attribute
          name: (qualified_name) @attribute_name (#match? @attribute_name "TestAttribute$")
        )
      )
      name: (identifier) @test.name
    ) @test.definition

    ;; Matches test classes
    (class_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute_name (#eq? @attribute_name "TestFixture")
        )
      )
      name: (identifier) @class.name
    ) @class.definition

    ;; Matches test methods
    (method_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute_name (#eq? @attribute_name "Test" ]] .. custom_test_attributes .. [[)
        )
      )
      name: (identifier) @test.name
    ) @test.definition

    ;; Matches parameterized test methods
    (method_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute_name (#match? @attribute_name "^TestCase")
        )
      )+
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
