from __future__ import annotations

from pathlib import Path
from typing import Any, Dict
from collections.abc import Mapping
from rule_templates import *


def matched_specs(banana, orange):
    """
    Return a list of {"command": ..., "events": ..., "flags": ...}
    for every banana subtree whose key-path exists in orange.

    Matching rules:
    - dict keys must exist along the path
    - lists/tuples in orange match if ANY element matches
    - leaf values under the matched banana node are returned as-is
    """

    def path_exists(path, node):
        if not path:
            return True

        key = path[0]

        if isinstance(node, Mapping):
            return key in node and path_exists(path[1:], node[key])

        if isinstance(node, (list, tuple)):
            return any(path_exists(path, item) for item in node)

        return False

    def walk(node, path=()):
        if not isinstance(node, Mapping):
            return

        # If this node has the payload keys and its path exists in orange, keep it.
        if all(k in node for k in ("command", "events", "flags")) and path_exists(path, orange):
            yield {
                "command": node["command"],
                "events": node["events"],
                "flags": node["flags"],
            }

        # Recurse into children
        for k, v in node.items():
            if isinstance(v, Mapping):
                yield from walk(v, path + (k,))
            elif isinstance(v, (list, tuple)):
                for item in v:
                    if isinstance(item, Mapping):
                        yield from walk(item, path + (k,))

    return list(walk(banana))

def load_field_specs(field, spec_dir):
    """
    Loads the specs file of the specific field
    """
    field_type = field[0]
    specs_file = Path(spec_dir) / f"{field_type}.yaml"

    with specs_file.open("r") as f:
        return yaml.safe_load(f)


def build_fields_rule(
    field: Dict[str, Any],
    name_prefix,
    namespace: str = "argo",
    spec_dir: str | Path = "field_specs",
    extra_template_container: str = None,
) -> Dict[str, Any]:
    """
    Receives a template's field section of an Argo template, and creates a Falco rule based on that.
    """
    if(field[0]!="container"):
        field_specs= load_field_specs(field, spec_dir)
        cmd_evt_flags = matched_specs(field_specs, field)
        
    key = list(field[1].keys())[0]

    # Extract path, if it exists
    if('path' in field[1][key][0]):
        extraction_path = (field[1])[key][0]['path']
        art_name = (field[1])[key][0]['name']
    
    field_type = field[0]
    match field_type:
        case "container":
            command_name = field[1]["command"][0]
            command = " ".join(field[1]["command"])
            args = " ".join(field[1]["args"])
            return container_rules_create(namespace, name_prefix, extra_template_container, command_name, command, args)
        case "inputs":
            return extraction_rules_create(cmd_evt_flags[0], extraction_path, namespace, name_prefix, art_name, extra_template_container)
        case _:
            return "Error, field type not configured"
