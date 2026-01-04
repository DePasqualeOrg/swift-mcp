"""
Shared spec extraction functions for MCP verification tools.

This module provides functions to extract data from the MCP specification schema.
Used by both sync-manifest.py and verify-protocol-coverage.py.
"""

import json
import re
from pathlib import Path


def load_schema(spec_dir: Path, protocol_version: str) -> dict:
    """Load the JSON schema from spec directory."""
    schema_path = spec_dir / "schema" / protocol_version / "schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(f"Schema not found at {schema_path}")

    with open(schema_path) as f:
        return json.load(f)


def extract_types(schema: dict) -> set[str]:
    """Extract public type names from spec schema.

    Filters out:
    - Method-specific types (*Request, *Response, *Result, *Notification, etc.)
    - Internal parameter variants (*RequestParams)
    - Deprecated types
    """
    defs = schema.get("$defs", {})
    spec_types = set()

    method_suffixes = ("Request", "RequestParams", "Response", "Result",
                       "Notification", "NotificationParams")

    for name, defn in defs.items():
        # Skip method-specific types
        if any(name.endswith(suffix) for suffix in method_suffixes):
            continue

        # Skip internal request parameter variants (e.g., ElicitRequestFormParams)
        if "Request" in name and name.endswith("Params"):
            continue

        # Skip deprecated types
        desc = defn.get("description", "") if isinstance(defn, dict) else ""
        if "will be removed" in desc.lower() or "deprecated" in desc.lower():
            continue

        spec_types.add(name)

    return spec_types


def extract_enums(schema: dict) -> dict[str, list[str]]:
    """Extract enum definitions from spec schema.

    Returns {enum_name: [case_values]}.
    """
    enums = {}
    for name, defn in schema.get("$defs", {}).items():
        if isinstance(defn, dict) and "enum" in defn:
            enums[name] = sorted(defn["enum"])
    return enums


def extract_error_codes(spec_dir: Path, protocol_version: str) -> dict[str, int]:
    """Extract error code constants from spec schema.ts.

    Returns {ERROR_NAME: code_value}.
    """
    schema_ts = spec_dir / "schema" / protocol_version / "schema.ts"
    if not schema_ts.exists():
        return {}

    content = schema_ts.read_text()
    codes = {}

    # Pattern: export const ERROR_NAME = -32XXX;
    pattern = r'export\s+const\s+([A-Z_]+)\s*=\s*(-\d+);'
    for match in re.finditer(pattern, content):
        name = match.group(1)
        code = int(match.group(2))
        codes[name] = code

    return codes


def extract_capabilities(schema: dict, cap_type: str) -> dict[str, dict[str, str]]:
    """Extract capability properties from schema.

    Args:
        schema: The loaded JSON schema
        cap_type: "ClientCapabilities" or "ServerCapabilities"

    Returns {prop_name: {nested_name: type}}.
    """
    cap_def = schema.get("$defs", {}).get(cap_type, {})
    props = cap_def.get("properties", {})

    result = {}
    for prop_name, prop_def in props.items():
        nested = {}
        if "properties" in prop_def:
            for nested_name, nested_def in prop_def["properties"].items():
                if nested_def.get("type") in ("boolean", "string", "integer"):
                    nested[nested_name] = nested_def.get("type")
        result[prop_name] = nested

    return result


def extract_all_capabilities(schema: dict) -> tuple[dict, dict]:
    """Extract both client and server capabilities.

    Returns (client_caps, server_caps).
    """
    return (
        extract_capabilities(schema, "ClientCapabilities"),
        extract_capabilities(schema, "ServerCapabilities"),
    )


def extract_deprecated(schema: dict) -> dict[str, str]:
    """Extract deprecated types from spec schema.

    Returns {type_name: description}.
    """
    deprecated = {}
    for name, defn in schema.get("$defs", {}).items():
        if not isinstance(defn, dict):
            continue
        desc = defn.get("description", "")
        if "deprecated" in desc.lower() or "will be removed" in desc.lower():
            deprecated[name] = desc
    return deprecated


def get_requests_from_union(schema: dict, union_type: str) -> list[str]:
    """Get all request/notification type names from a union type.

    Args:
        schema: The loaded JSON schema
        union_type: "ClientRequest", "ServerRequest", "ClientNotification", or "ServerNotification"
    """
    defn = schema.get("$defs", {}).get(union_type, {})
    refs = defn.get("anyOf", [])
    return [ref["$ref"].split("/")[-1] for ref in refs if "$ref" in ref]


def extract_method_name(schema: dict, request_type: str) -> str | None:
    """Extract the method name from a request type definition."""
    defn = schema.get("$defs", {}).get(request_type, {})
    props = defn.get("properties", {})
    method_prop = props.get("method", {})
    return method_prop.get("const")


def extract_all_method_names(schema: dict) -> set[str]:
    """Extract all method names from spec schema.

    This includes both request methods and notification methods.
    """
    methods = set()
    defs = schema.get("$defs", {})

    for defn in defs.values():
        if not isinstance(defn, dict):
            continue
        props = defn.get("properties", {})
        method_prop = props.get("method", {})
        if "const" in method_prop:
            methods.add(method_prop["const"])

    return methods


def extract_methods_and_notifications(schema: dict) -> tuple[set[str], set[str]]:
    """Extract method names separately for requests vs notifications.

    Uses the schema's union types to distinguish:
    - ClientRequest, ServerRequest -> methods
    - ClientNotification, ServerNotification -> notifications

    Returns (methods, notifications).
    """
    methods = set()
    notifications = set()

    # Get request types from unions
    for union_type in ("ClientRequest", "ServerRequest"):
        for request_type in get_requests_from_union(schema, union_type):
            method_name = extract_method_name(schema, request_type)
            if method_name:
                methods.add(method_name)

    # Get notification types from unions
    for union_type in ("ClientNotification", "ServerNotification"):
        for notif_type in get_requests_from_union(schema, union_type):
            method_name = extract_method_name(schema, notif_type)
            if method_name:
                notifications.add(method_name)

    return methods, notifications
