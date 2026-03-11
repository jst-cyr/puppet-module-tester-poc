#!/usr/bin/env python3
"""Validate config/modules.json against config/modules.schema.json."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"ERROR: File not found: {path}")
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"ERROR: Invalid JSON in {path}: line {exc.lineno}, column {exc.colno}: {exc.msg}")
        sys.exit(1)


def format_path(parts: list[object]) -> str:
    if not parts:
        return "$"

    out = "$"
    for part in parts:
        if isinstance(part, int):
            out += f"[{part}]"
        else:
            out += f".{part}"
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate modules.json against JSON Schema")
    parser.add_argument("--config", required=True, help="Path to modules.json")
    parser.add_argument("--schema", required=True, help="Path to modules.schema.json")
    args = parser.parse_args()

    config_path = Path(args.config)
    schema_path = Path(args.schema)

    config = load_json(config_path)
    schema = load_json(schema_path)

    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(config), key=lambda err: list(err.path))

    if errors:
        print(f"ERROR: {config_path} failed schema validation against {schema_path}.")
        for err in errors:
            path = format_path(list(err.path))
            print(f"  - {path}: {err.message}")
        return 1

    print(f"OK: {config_path} is valid against {schema_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
