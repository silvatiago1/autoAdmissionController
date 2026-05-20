from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Any, Dict, Set
from dataclasses import dataclass, field
from textwrap import dedent
import yaml
from collections.abc import Mapping

class LiteralStr(str):
    pass

yaml.SafeDumper.add_representer(
    LiteralStr,
    lambda dumper, data: dumper.represent_scalar(
        "tag:yaml.org,2002:str", data, style="|"
    ),
)

def _indent(text, n=4):
    pad = " " * n
    return "\n".join(pad + line if line else line for line in text.splitlines())

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
    
def extraction_rule_create(cmd_evt_flags, path, namespace, name_prefix):
    proc_name = cmd_evt_flags['command'][0]
    evt_type = cmd_evt_flags['events']['items'][0]
    flags = cmd_evt_flags['flags']['items']
    
    # Construct the condition strings
    # Joining flags with 'and' for the macro
    flags_condition = " and ".join([f"evt.arg.flags contains {f}" for f in flags])
    #TODO:add argoexec init command when receiving input artifacts
    macro_cmd_events = dedent(f"""\
(proc.name = {proc_name} and
      {_indent(f'evt.type={evt_type}',2)} and
      {_indent(f'({flags_condition}))',2)}
        """).strip()

    # Define the rule structure and create said rule
    yaml_content = dedent(f"""\
    - macro: cmd_events_flags
      condition: >
        {macro_cmd_events}

    - macro: file_path
      condition: fs.path.name contains "{path}" or fs.path.name contains "/mainctrfs{path}"

    - macro: in_mainctrfs
      condition: fs.path.name contains "/mainctrfs/"

    - macro: in_pod
      condition: k8s.pod.name startswith "{name_prefix}"

    - macro: link_path_artifacts
      condition: evt.arg.linkpath startswith "/argo/inputs/artifacts/"

    - macro: wrong_target
      condition: not (evt.arg.target contains "{path}") and not (evt.arg.target contains "/mainctrfs{path}")

    - rule: write_tmp_dir
      desc: File extraction outside {path}
      condition: ((cmd_events_flags and (not file_path) and in_mainctrfs) or (create_symlink and link_path_artifacts and wrong_target)) and k8s.ns.name = "argo" and in_pod and proc.cmdline startswith "argoexec init"
      output: "File extraction outside of the intended path, {path} | user=%user.name command=%proc.cmdline file=%fd.name file_source=%fs.path.source file_target=%fs.path.target linkpath=%evt.arg.linkpath target=%evt.arg.target evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
      priority: WARNING
    """)

    final_output = {
        "customRules": {
            f"{name_prefix}detect_path_extraction.yaml": LiteralStr(yaml_content)
        }
    }
    return final_output
    
def build_fields_rule(
    field: Dict[str, Any],
    name_prefix,
    namespace: str = "argo",
    spec_dir: str | Path = "field_specs",
) -> Dict[str, Any]:
    """
    Receives a template's field section of an Argo template, and creates a Falco rule based on that.
    """
    field_specs= load_field_specs(field, spec_dir)
    
    ### This part is assuming that it's something with path, will be altered in the future
    key = list(field[1].keys())[0]
    extraction_path = (field[1])[key][0]['path']

    cmd_evt_flags = matched_specs(field_specs, field)
                                # Possibly have several rules, if several combinations of cmd_evt_flags are possible for a configuration
    return extraction_rule_create(cmd_evt_flags[0], extraction_path, namespace, name_prefix)