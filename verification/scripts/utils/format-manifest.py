#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["ruamel.yaml"]
# ///
"""
Format manifest.yaml with consistent indentation and spacing.

Usage: uv run format-manifest.py

This only reformats - it does not modify any data.
"""

import sys
from pathlib import Path

# Add parent directory to path for lib imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.yaml_utils import create_yaml


def main():
    script_dir = Path(__file__).parent
    default_manifest = script_dir.parent.parent / 'manifest.yaml'

    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    input_file = Path(args[0]) if args else default_manifest
    output_file = Path(args[1]) if len(args) > 1 else input_file

    yaml = create_yaml()

    with open(input_file, 'r') as f:
        data = yaml.load(f)

    with open(output_file, 'w') as f:
        yaml.dump(data, f)

    print(f"Formatted {input_file}")


if __name__ == '__main__':
    main()
