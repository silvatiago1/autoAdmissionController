from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Any, Dict, Set
from dataclasses import dataclass, field
from textwrap import dedent
import yaml



def build_fields_rule(
    field: Dict[str, Any],
    namespace: str = "argo",
    spec_dir: str | Path = "field_specs",
) -> Dict[str, Any]:
    """
    Receives a template's field section of an Argo template, and creates a Falco rule based on that.
    """
    field_type = field[0]
    
    match field_type:
        case "inputs":
            input_type = list(field[1].keys())[0]
            input_name = (field[1])[input_type][0]['name']
            input_path = (field[1])[input_type][0]['path']
    