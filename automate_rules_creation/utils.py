import yaml
from typing import Tuple, Any, Dict, List, Optional
from copy import deepcopy
from pathlib import Path

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

def load_covered_fields(path: str) -> set[str]:
    """Load the fields whose data has been collected and place in the covered_fields file"""
    with open(path, "r") as f:
        return {
            line.strip()
            for line in f
            if line.strip()
        }

def get_covered_fields(manifest: dict) -> List[Tuple[str, Any]]:
    """Receive a template, and return its covered fields"""

    covered_fields = load_covered_fields(Path("covered_fields"))

    covered_present = [
        (key, manifest[key])
        for key in manifest
        if key in covered_fields
    ]

    return covered_present

def get_container_template_name(template: Dict[str, Any]) -> Optional[str]:
    """
    Checks if an Argo template contains an active container execution context.
    
    Returns:
        str: The name of the template if it runs a container.
        None: If the template has no container context or is invalid.
    """
    if not isinstance(template, dict):
        return None
        
    # Define fields that imply active container execution
    container_keys = {"container", "script", "containerSet"}
    
    has_sidecars = (
        "sidecars" in template 
        and isinstance(template["sidecars"], list) 
        and len(template["sidecars"]) > 0
    )
    
    # If it has any container-centric field, return its template name
    if has_sidecars or any(key in template for key in container_keys):
        return template.get("name")
        
    return None