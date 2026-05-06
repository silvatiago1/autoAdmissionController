import sys
from utils import *

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script.py <workflow.yaml>")
        sys.exit(1)

    yaml_path = sys.argv[1]

    # Get a Workflow/WorkflowTemplate and receive its name-prefix/name
    try:
        with open(yaml_path, "r") as f:
            yaml_data = yaml.safe_load(f)
        name, kind = get_argo_resource_name(yaml_data)
        
        print(f"Workflow name's prefix: {name}") if kind == "Workflow" else print(f"Workflow Template's name: {name}")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    # Separate each template in the workflow
    try:
        templates = separate_argo_templates(yaml_data)

        for template in templates:
            print(yaml.safe_dump(template, sort_keys=False))
            print("---")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)