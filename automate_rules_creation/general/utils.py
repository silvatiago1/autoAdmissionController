import yaml
from typing import Tuple

def get_argo_resource_name(yaml_file_path: str) -> Tuple[str, str]:
    """
    - Receives file and determines whether it is a Workflow, or a WorkflowTemplate.
    It then extracts its name's prefix in case it is a Workflow, and its name in case of a WorkflowTemplate.

    Args:
    - yaml_file_path (str): Path to the YAML file.

    Returns:
    - [str, str]: The name/name-prefix and the kind of file
    """
    with open(yaml_file_path, "r") as f:
        data = yaml.safe_load(f)

    kind = data.get("kind")
    metadata = data.get("metadata", {})

    if kind == "Workflow":
        if "generateName" not in metadata:
            raise ValueError("Workflow must have metadata.generateName")
        return [metadata["generateName"], kind]

    elif kind == "WorkflowTemplate":
        if "name" not in metadata:
            raise ValueError("WorkflowTemplate must have metadata.name")
        return [metadata["name"], kind]

    else:
        raise ValueError(f"Unsupported kind: {kind}")