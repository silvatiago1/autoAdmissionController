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

def build_fields_rule(
    field: Dict[str, Any],
    namespace: str = "argo",
    spec_dir: str | Path = "field_specs",
) -> Dict[str, Any]:
    """
    Receives a template's field section of an Argo template, and creates a Falco rule based on that.
    """
    field_type = field[0]
    print(field_type)