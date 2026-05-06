import yaml
from typing import Tuple, Any, Dict, List
from copy import deepcopy

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


def separate_argo_templates(workflow: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Receives a  Workflow/WorkflowTemplate and returns each item in spec.templates
    as an independent template dict.
    """
    kind = workflow.get("kind")

    if kind != "WorkflowTemplate" and kind != "Workflow":
        raise ValueError("Expected kind: Workflow or WorkflowTemplate")

    spec = workflow.get("spec", {})
    templates = spec.get("templates", [])

    if not isinstance(templates, list):
        raise ValueError("spec.templates must be a list")

    return [deepcopy(template) for template in templates]
