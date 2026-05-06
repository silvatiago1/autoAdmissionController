from __future__ import annotations

from pathlib import PurePosixPath
from typing import Any, Dict, List, Set
from dataclasses import dataclass, field
from textwrap import dedent
import yaml


@dataclass
class BinaryInfo:
    flags: Set[str] = field(default_factory=set)
    events: Set[str] = field(default_factory=set)


binaries: Dict[str, BinaryInfo] = {}


class LiteralStr(str):
    pass


def _literal_str_representer(dumper: yaml.Dumper, data: LiteralStr):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.add_representer(LiteralStr, _literal_str_representer, Dumper=yaml.SafeDumper)


def build_binary_condition(binary: str, info: BinaryInfo) -> str:
    parts = [f"proc.name = {binary}"]

    if info.events:
        event_part = " or ".join(f"evt.type={event}" for event in sorted(info.events))
        parts.append(event_part if len(info.events) == 1 else f"({event_part})")

    if info.flags:
        flag_part = " and ".join(
            f"evt.arg.flags contains {flag}" for flag in sorted(info.flags)
        )
        parts.append(flag_part if len(info.flags) == 1 else f"({flag_part})")

    return " and ".join(parts)


def build_inputs_rule(
    inputs: Dict[str, Any],
    namespace: str = "argo",
    rule_filename: str = "detect_write_to_etc.yaml",
) -> Dict[str, Any]:
    """
    Receives the inputs section of an Argo template, maps the file type being extracted
    to the events, commands, and Flags that Argo uses to handle them, and creates a rule
    stating that if those are used to in a path not equal to the one defined for extraction,
    then a warning must be raised. #TODO:I am creating a customRule for now, for test porpuses, but in certain cases the same bins may be used for other things, so it will have to be a map used to then create a rule (in another function)

    Returns:
    - A Falco customRule
    """
    artifacts = inputs.get("artifacts", [])  # TODO: Assuming, for now, that artifacts is present
    if not isinstance(artifacts, list):
        raise ValueError("inputs.artifacts must be a list")

    extract_paths: Set[str] = set()
    binaries.clear()
    binaries["argoexec"] = BinaryInfo()

    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue

        path = artifact.get("path")
        archive = artifact.get("archive", {})

        if path and isinstance(path, str):
            extract_paths.add(path)

        # Detect archive type(s). Extend this map as needed.
        if isinstance(archive, dict):
            if "tar" in archive:
                # In Argo Workflows, tar extraction is commonly handled by argoexec
                binaries["argoexec"].events.add("openat")

                binaries["argoexec"].flags.update([
                    "O_CREAT",
                    "O_CLOEXEC",
                    "O_RDWR",
                    "O_F_CREATED",
                ])  # TODO: Put these in a file with this info, instead of it all being here
            # TODO: Add more types of files

    if not extract_paths:
        raise ValueError("No artifact paths found in inputs.artifacts")

    if not binaries:
        raise ValueError("No supported archive extraction binaries detected")

    # Build OR conditions safely.
    binary_condition = next(
        build_binary_condition(binary, info)
        for binary, info in sorted(binaries.items())
    )

    path_conditions = " or ".join(
        f'fs.path.name contains "{p}" or fs.path.name contains "/mainctrfs{p}"'
        for p in sorted(extract_paths)
    )

    # Use the first path in messages for readability.
    first_path = sorted(extract_paths)[0]
    rule_name = f"write_{PurePosixPath(first_path).name or 'extraction'}_dir"

    inner_yaml = dedent(f"""
         macro: cmd_events_flags
          condition: >
            {binary_condition.replace(" and ", " and\n            ")}

        - macro: work_tmp_file
          condition: {path_conditions}

        - macro: in_mainctrfs
          condition: fs.path.name contains "/mainctrfs/"

        - rule: {rule_name}
          desc: tar has activity outside {first_path}
          condition: cmd_events_flags and (not work_tmp_file) and in_mainctrfs and k8s.ns.name = "{namespace}"
          output: "Tar extraction outside of the intended path, {first_path} | user=%user.name command=%proc.cmdline file=%fd.name evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
          priority: WARNING
    """).strip()

    falco_rules = {
        "customRules": {
            rule_filename: LiteralStr(inner_yaml)
        }
    }

    return falco_rules