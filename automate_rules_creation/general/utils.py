import yaml
from typing import Tuple

def get_argo_resource_name(manifest: yaml) -> Tuple[str, str]:
    """
    - Receives file and determines whether it is a Workflow, or a WorkflowTemplate.
    It then extracts its name's prefix in case it is a Workflow, and its name in case of a WorkflowTemplate.

    Args:
    - data (yaml): Path to the YAML file.

    Returns:
    - [str, str]: The name/name-prefix and the kind of file
    """

    kind = manifest.get("kind")
    metadata = manifest.get("metadata", {})

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
    
