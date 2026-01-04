#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
Extract type definitions from Python files using the ast module.

Usage: uv run extract-py-types.py <file-or-directory> [--json]

Outputs one type per line, or JSON if --json flag is provided.

Example:
    uv run extract-py-types.py ./src/mcp/types.py
    uv run extract-py-types.py ./src --json
"""

import ast
import json
import sys
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Iterator


@dataclass
class TypeInfo:
    name: str
    kind: str  # 'class', 'type_alias', 'typed_dict', 'enum', 'protocol'
    file: str
    line: int


def extract_types_from_file(file_path: Path) -> list[TypeInfo]:
    """Extract all type definitions from a Python file."""
    types = []

    try:
        content = file_path.read_text()
        tree = ast.parse(content, filename=str(file_path))
    except (SyntaxError, FileNotFoundError) as e:
        print(f"Error parsing {file_path}: {e}", file=sys.stderr)
        return types

    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            # Determine the kind based on base classes
            kind = "class"
            base_names = []
            for base in node.bases:
                if isinstance(base, ast.Name):
                    base_names.append(base.id)
                elif isinstance(base, ast.Attribute):
                    base_names.append(base.attr)
                elif isinstance(base, ast.Subscript):
                    if isinstance(base.value, ast.Name):
                        base_names.append(base.value.id)
                    elif isinstance(base.value, ast.Attribute):
                        base_names.append(base.value.attr)

            if "TypedDict" in base_names:
                kind = "typed_dict"
            elif "Protocol" in base_names:
                kind = "protocol"
            elif "Enum" in base_names or "IntEnum" in base_names or "StrEnum" in base_names:
                kind = "enum"
            elif any(b in base_names for b in ["BaseModel", "RootModel"]):
                kind = "pydantic_model"

            types.append(TypeInfo(
                name=node.name,
                kind=kind,
                file=str(file_path),
                line=node.lineno
            ))

        # Type aliases (Python 3.12+ style: type X = ...)
        elif isinstance(node, ast.TypeAlias):
            types.append(TypeInfo(
                name=node.name.id if isinstance(node.name, ast.Name) else str(node.name),
                kind="type_alias",
                file=str(file_path),
                line=node.lineno
            ))

        # Older style type aliases: X = TypeVar(...) or X: TypeAlias = ...
        elif isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name):
                if isinstance(node.annotation, ast.Name) and node.annotation.id == "TypeAlias":
                    types.append(TypeInfo(
                        name=node.target.id,
                        kind="type_alias",
                        file=str(file_path),
                        line=node.lineno
                    ))
                elif isinstance(node.annotation, ast.Subscript):
                    if isinstance(node.annotation.value, ast.Name):
                        if node.annotation.value.id in ("TypeAlias", "Final"):
                            types.append(TypeInfo(
                                name=node.target.id,
                                kind="type_alias",
                                file=str(file_path),
                                line=node.lineno
                            ))

        # Simple assignments that might be type aliases (X = Union[...], X = Literal[...])
        elif isinstance(node, ast.Assign):
            if len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                name = node.targets[0].id
                # Skip private/dunder names
                if name.startswith("_"):
                    continue
                # Check if it's a type-like assignment
                if isinstance(node.value, ast.Subscript):
                    if isinstance(node.value.value, ast.Name):
                        type_constructors = {"Union", "Optional", "Literal", "List", "Dict", "Tuple", "Set"}
                        if node.value.value.id in type_constructors:
                            types.append(TypeInfo(
                                name=name,
                                kind="type_alias",
                                file=str(file_path),
                                line=node.lineno
                            ))
                elif isinstance(node.value, ast.Call):
                    if isinstance(node.value.func, ast.Name):
                        if node.value.func.id in ("TypeVar", "NewType"):
                            types.append(TypeInfo(
                                name=name,
                                kind="type_var" if node.value.func.id == "TypeVar" else "new_type",
                                file=str(file_path),
                                line=node.lineno
                            ))

    return types


def extract_types_from_directory(dir_path: Path) -> list[TypeInfo]:
    """Extract all type definitions from Python files in a directory."""
    types = []

    for py_file in dir_path.rglob("*.py"):
        # Skip test files, __pycache__, and hidden directories
        parts = py_file.parts
        if any(p.startswith(".") or p == "__pycache__" or p.startswith("test") for p in parts):
            continue
        types.extend(extract_types_from_file(py_file))

    return types


def check_type_exists(file_path: Path, type_name: str) -> dict:
    """Check if a specific type exists in a file."""
    types = extract_types_from_file(file_path)
    found = next((t for t in types if t.name == type_name), None)
    if found:
        return {"exists": True, **asdict(found)}
    return {"exists": False, "name": type_name}


def main():
    args = sys.argv[1:]
    json_output = "--json" in args
    check_mode = "--check" in args

    # Filter out flags to get the target path
    target_path = next((a for a in args if not a.startswith("--")), None)

    if not target_path:
        print("Usage: extract-py-types.py <file-or-directory> [--json] [--check <type-name>]", file=sys.stderr)
        sys.exit(1)

    path = Path(target_path)

    if check_mode:
        try:
            type_name = args[args.index("--check") + 1]
        except (IndexError, ValueError):
            print("--check requires a type name", file=sys.stderr)
            sys.exit(1)

        result = check_type_exists(path, type_name)
        if json_output:
            print(json.dumps(result))
        else:
            if result["exists"]:
                print(f"Found: {result['name']} ({result['kind']})")
            else:
                print(f"Not found: {type_name}")
        sys.exit(0 if result["exists"] else 1)

    if path.is_dir():
        types = extract_types_from_directory(path)
    else:
        types = extract_types_from_file(path)

    if json_output:
        print(json.dumps([asdict(t) for t in types], indent=2))
    else:
        # Output one type per line: name:kind:file:line
        for t in types:
            print(f"{t.name}:{t.kind}:{t.file}:{t.line}")


if __name__ == "__main__":
    main()
