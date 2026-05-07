from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Any, Dict, Set
from dataclasses import dataclass, field
from textwrap import dedent
import yaml


@dataclass
class ConditionGroup:
    op: str = "and"  # "and" or "or"
    items: Set[str] = field(default_factory=set)

@dataclass
class BinaryInfo:
    flags: ConditionGroup = field(default_factory=ConditionGroup)
    events: ConditionGroup = field(default_factory=ConditionGroup)

binaries: Dict[str, BinaryInfo] = {}


class LiteralStr(str):
    pass


def _literal_str_representer(dumper: yaml.Dumper, data: LiteralStr):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.add_representer(LiteralStr, _literal_str_representer, Dumper=yaml.SafeDumper)


def _build_group(prefix: str, group: ConditionGroup) -> str:
    if not group.items:
        return ""

    exprs = [f"{prefix}{item}" for item in sorted(group.items)]
    joined = f" {group.op} ".join(exprs)
    return joined if len(exprs) == 1 else f"({joined})"


def build_binary_condition(binary: str, info: BinaryInfo) -> str:
    parts = [f"proc.name = {binary}"]

    event_part = _build_group("evt.type=", info.events)
    if event_part:
        parts.append(event_part)

    flag_part = _build_group("evt.arg.flags contains ", info.flags)
    if flag_part:
        parts.append(flag_part)

    return " and ".join(parts)

def load_binary_specs(spec_dir: str | Path) -> Dict[str, BinaryInfo]:
    spec_dir = Path(spec_dir)
    loaded: Dict[str, BinaryInfo] = {}

    for spec_file in sorted(spec_dir.iterdir()):
        if not spec_file.is_file():
            continue

        data = yaml.safe_load(spec_file.read_text()) or {}
        if not isinstance(data, dict):
            raise ValueError(f"{spec_file} must contain a YAML mapping")

        info = BinaryInfo()

        for section_name, group in (("events", info.events), ("flags", info.flags)):
            section = data.get(section_name, {})
            if section is None:
                continue

            if isinstance(section, dict):
                group.op = section.get("op", "and")
                items = section.get("items", [])
            else:
                items = section

            if group.op not in {"and", "or"}:
                raise ValueError(f"{spec_file}: {section_name}.op must be 'and' or 'or'")

            if not isinstance(items, list):
                raise ValueError(f"{spec_file}: {section_name}.items must be a list")

            group.items.update(str(item) for item in items)

        loaded[spec_file.name] = info

    return loaded

def format_condition(expr: str) -> str:
    lines = expr.split(" and ")
    if not lines:
        return ""

    # Every line starts 8 spaces under the "condition: >" line
    return " and\n        ".join(lines)

def build_inputs_rule(
    inputs: Dict[str, Any],
    namespace: str = "argo",
    rule_filename: str = "detect_write_to_etc.yaml",
    spec_dir: str | Path = "binary_specs",
) -> Dict[str, Any]:
    """
    Receives the inputs section of an Argo template, maps the file type being extracted
    to the events, commands, and flags that Argo uses to handle them, and creates a rule.
    """
    artifacts = inputs.get("artifacts", [])
    if not isinstance(artifacts, list):
        raise ValueError("inputs.artifacts must be a list")

    extract_paths: Set[str] = set()
    used_binaries: Set[str] = set()

    archive_to_binary = {
        "tar": {"argoexec"},
    }

    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue

        path = artifact.get("path")
        archive = artifact.get("archive", {})

        if path and isinstance(path, str):
            extract_paths.add(path)

        if isinstance(archive, dict):
            for archive_type, binaries_for_type in archive_to_binary.items():
                if archive_type in archive:
                    used_binaries.update(binaries_for_type)

    if not extract_paths:
        raise ValueError("No artifact paths found in inputs.artifacts")

    if not used_binaries:
        raise ValueError("No supported archive extraction binaries detected")

    all_binaries = load_binary_specs(spec_dir)
    binaries.clear()
    binaries.update(
        {name: info for name, info in all_binaries.items() if name in used_binaries}
    )

    if not binaries:
        raise ValueError("No binary specs found for the detected archive types")

    binary_condition = " or ".join(
        f"({build_binary_condition(binary, info)})"
        for binary, info in sorted(binaries.items())
    )

    path_conditions = " or ".join(
        f'fs.path.name contains "{p}" or fs.path.name contains "/mainctrfs{p}"'
        for p in sorted(extract_paths)
    )

    first_path = sorted(extract_paths)[0]
    rule_name = f"write_{PurePosixPath(first_path).name or 'extraction'}_dir"

    formatted_binary_condition = format_condition(binary_condition)
    inner_yaml = dedent(f"""
    - macro: cmd_events_flags
      condition: >
        {formatted_binary_condition}

    - macro: work_tmp_file
      condition: {path_conditions}

    - macro: in_mainctrfs
      condition: fs.path.name contains "/mainctrfs/"

    - rule: {rule_name}
      desc: tar has activity outside {first_path}
      condition: cmd_events_flags and (not work_tmp_file) and in_mainctrfs and k8s.ns.name = "{namespace}"
      output: "Tar extraction outside of the intended path, {first_path} | user=%user.name command=%proc.cmdline file=%fd.name evt_type=%evt.type evt_arg_flags=%evt.arg.flags"
      priority: WARNING
""").strip() + "\n"
    return {
        "customRules": {
            rule_filename: LiteralStr(inner_yaml)
        }
    }
