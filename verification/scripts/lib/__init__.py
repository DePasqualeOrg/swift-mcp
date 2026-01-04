"""
Shared modules for MCP verification scripts.
"""

from .spec_extraction import (
    load_schema,
    extract_types,
    extract_enums,
    extract_error_codes,
    extract_capabilities,
    extract_all_capabilities,
    extract_deprecated,
    get_requests_from_union,
    extract_method_name,
    extract_all_method_names,
)

from .output import (
    RED,
    GREEN,
    YELLOW,
    CYAN,
    DIM,
    NC,
    print_header,
    print_ok,
    print_error,
    print_warning,
    print_dim,
    print_add,
)

from .yaml_utils import create_yaml

__all__ = [
    # spec_extraction
    "load_schema",
    "extract_types",
    "extract_enums",
    "extract_error_codes",
    "extract_capabilities",
    "extract_all_capabilities",
    "extract_deprecated",
    "get_requests_from_union",
    "extract_method_name",
    "extract_all_method_names",
    # output
    "RED",
    "GREEN",
    "YELLOW",
    "CYAN",
    "DIM",
    "NC",
    "print_header",
    "print_ok",
    "print_error",
    "print_warning",
    "print_dim",
    "print_add",
    # yaml_utils
    "create_yaml",
]
