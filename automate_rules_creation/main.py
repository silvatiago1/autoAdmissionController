import sys
from utils import *
from falco_utils import *
from rule_templates import *

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 main.py <workflow.yaml>")
        sys.exit(1)

    yaml_path = sys.argv[1]

    ### Get a Workflow/WorkflowTemplate and receive its name-prefix/name
    try:
        with open(yaml_path, "r") as f:
            yaml_data = yaml.safe_load(f)
        name, kind = get_argo_resource_name(yaml_data)
        
        print(f"Workflow name's prefix: {name}") if kind == "Workflow" else print(f"Workflow Template's name: {name}")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    ### Separate each template in the workflow
    templates = separate_argo_templates(yaml_data)
    print("banana\n".join(str(t) for t in templates))

    ### Build the rules for each template
    for template in templates:
        print(yaml.safe_dump(template, sort_keys=False))
        print("---")
        container=get_container_template_name(template)

        #TODO: Only works for inputs and containers so far
        print("---------------Custom Rule:-------------:")
        covered_fields = get_covered_fields(template)
        with open(f"./created_rules/{name}rules.yaml", "w") as f:
            for i in covered_fields:
                customRule = build_fields_rule(i, name_prefix=name, extra_template_container=container)
                print(yaml.safe_dump(customRule))

                f.write("---\n")
                yaml.safe_dump(customRule, f, sort_keys=False)  
        