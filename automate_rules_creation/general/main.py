import sys
from utils import get_argo_resource_name

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script.py <workflow.yaml>")
        sys.exit(1)

    yaml_path = sys.argv[1]

    try:
        name, kind = get_argo_resource_name(yaml_path)
        
        print(f"Workflow name's prefix: {name}") if kind == "Workflow" else print(f"Workflow Template's name: {name}")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)