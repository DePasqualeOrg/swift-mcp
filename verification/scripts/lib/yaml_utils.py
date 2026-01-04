"""
Shared YAML utilities for MCP verification scripts.
"""

from ruamel.yaml import YAML


def create_yaml() -> YAML:
    """Create a YAML instance with consistent project formatting."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False
    yaml.map_indent = 2
    yaml.sequence_indent = 4
    yaml.sequence_dash_offset = 2
    yaml.width = 120
    return yaml
