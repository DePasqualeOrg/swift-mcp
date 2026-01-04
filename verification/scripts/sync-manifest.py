#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["ruamel.yaml"]
# ///
"""
Sync manifest with MCP spec schema.

Reads the spec schema and syncs all categories to the manifest:
- Types (public type definitions with Swift mappings)
- Methods and notifications (in modules section)
- Enums (enum definitions and their cases)
- Error codes (JSON-RPC and MCP-specific)
- Capabilities (client and server capability properties)
- Deprecated types (informational tracking)

Usage:
    uv run sync-manifest.py [--dry-run]

Options:
    --dry-run    Show what would be changed without modifying the file
"""

import json
import subprocess
import sys
from pathlib import Path

from lib import spec_extraction
from lib.yaml_utils import create_yaml


# =============================================================================
# Swift Type Discovery
# =============================================================================

def extract_swift_types(sources_dir: Path, script_dir: Path) -> dict[str, dict]:
    """Extract all Swift types from the codebase using AST-based extractor.

    Returns {type_name: {"kind": kind, "file": file, "line": line}}.
    """
    extractor = script_dir / "extractors" / "swift"

    try:
        result = subprocess.run(
            ["swift", "run", "extract-swift-types", str(sources_dir)],
            cwd=extractor,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"Warning: Could not run Swift type extractor: {e}")
        return {}

    types = {}
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if not line or ":" not in line:
            continue
        parts = line.split(":")
        if len(parts) >= 4:
            name, kind, file_path, _ = parts[0], parts[1], parts[2], parts[3]
            # Skip enum cases and internal types
            if kind == "case" or ".CodingKeys" in name:
                continue
            types[name] = {"kind": kind, "file": file_path}

    return types


def build_spec_to_swift_mapping(swift_types: dict[str, dict]) -> dict[str, str]:
    """Build a mapping from possible spec type names to Swift type names.

    For each Swift type, generate possible spec names it could match:
    - Exact: "Resource" → "Resource"
    - Flattened nested: "Prompt.Argument" → "PromptArgument"
    - With JSONRPC prefix: "Message" → "JSONRPCMessage"
    - With common prefixes: "MCPError" → "Error"

    Returns {possible_spec_name: swift_type_name}.
    """
    mapping = {}

    for swift_name in swift_types:
        # Exact match
        mapping[swift_name] = swift_name

        # Flattened nested type: Prompt.Argument → PromptArgument
        if "." in swift_name:
            flattened = swift_name.replace(".", "")
            mapping[flattened] = swift_name

        # Base name for nested types: Prompt.Argument → Argument (less priority)
        # Skip this as it causes ambiguity

        # Handle JSONRPC prefix: Message → JSONRPCMessage
        if not swift_name.startswith("JSONRPC") and "." not in swift_name:
            mapping[f"JSONRPC{swift_name}"] = swift_name

        # Handle MCP prefix: MCPError → Error, MCPTask → Task
        if swift_name.startswith("MCP") and len(swift_name) > 3:
            base = swift_name[3:]
            mapping[base] = swift_name

    return mapping


def find_swift_type(spec_name: str, spec_to_swift: dict[str, str], swift_types: dict[str, dict]) -> tuple[str | None, str | None]:
    """Find matching Swift type for a spec type name.

    Returns (swift_name, file_path) or (None, None) if not found.
    """
    # Direct lookup in our mapping
    if spec_name in spec_to_swift:
        swift_name = spec_to_swift[spec_name]
        info = swift_types.get(swift_name, {})
        return swift_name, info.get("file")

    # Try splitting CamelCase into nested type: PromptArgument → Prompt.Argument
    # Find the longest prefix that matches a Swift type
    for i in range(len(spec_name) - 1, 0, -1):
        if spec_name[i].isupper():
            prefix = spec_name[:i]
            suffix = spec_name[i:]
            nested_name = f"{prefix}.{suffix}"
            if nested_name in swift_types:
                return nested_name, swift_types[nested_name].get("file")

    return None, None


# IMPORTANT FOR FUTURE MAINTAINERS:
# This script must work automatically with new versions of the MCP spec.
# Avoid adding hardcoded mappings whenever possible. Instead, derive names
# programmatically from the spec schema using consistent patterns.
#
# If a mapping IS required (e.g., Swift uses a different naming convention),
# document WHY the mapping is necessary and consider whether the Swift code
# should be renamed to match the derived pattern instead.

# Swift method name mappings for non-obvious cases
# These exist because Swift SDK uses different naming conventions than the spec
# TODO: Consider renaming Swift methods to match derived patterns and removing these
SWIFT_METHOD_MAPPINGS = {
    "sampling/createMessage": "requestSampling",
    "elicitation/create": "requestElicitation",
    "roots/list": "listRoots",
    "logging/setLevel": "setLoggingLevel",
    "completion/complete": "complete",
    "resources/templates/list": "listResourceTemplates",
    "tasks/get": "getTask",
    "tasks/list": "listTasks",
    "tasks/cancel": "cancelTask",
    "tasks/result": "getTaskResult",
}



def to_swift_method_name(method: str) -> str:
    """Convert MCP method name to expected Swift method name."""
    if method in SWIFT_METHOD_MAPPINGS:
        return SWIFT_METHOD_MAPPINGS[method]

    parts = method.split("/")
    if len(parts) != 2:
        return method

    category, action = parts
    singular = category.rstrip("s") if category.endswith("s") else category

    if action == "list":
        return f"list{category.title()}"
    elif action in ("get", "read", "call"):
        return f"{action}{singular.title()}"
    elif action == "subscribe":
        return f"subscribeTo{singular.title()}"
    elif action == "unsubscribe":
        return f"unsubscribeFrom{singular.title()}"
    else:
        return f"{action}{singular.title()}"


def get_method_direction(method_name: str, client_requests: set, server_requests: set, all_request_types: dict) -> str:
    """Determine the direction of a method."""
    req_type = all_request_types.get(method_name)
    if not req_type:
        return "unknown"

    is_client = req_type in client_requests
    is_server = req_type in server_requests

    if is_client and is_server:
        return "bidirectional"
    elif is_client:
        return "client_to_server"
    elif is_server:
        return "server_to_client"
    return "unknown"


def to_client_handler_name(method: str) -> str:
    """Derive client handler name from method name.

    Pattern: method category → with{Category}Handler
    Examples:
        sampling/createMessage → withSamplingHandler
        elicitation/create → withElicitationHandler
        roots/list → withRootsHandler
    """
    parts = method.split("/")
    if len(parts) < 1:
        return f"with{method.title()}Handler"

    category = parts[0]
    # Capitalize first letter, keep rest as-is
    return f"with{category[0].upper()}{category[1:]}Handler"


def to_send_method_name(notification_type: str) -> str:
    """Derive send method name from notification type name.

    Pattern: {Type}Notification → send{Type}
    Examples:
        ProgressNotification → sendProgress
        CancelledNotification → sendCancelled
        ResourceListChangedNotification → sendResourceListChanged
        LoggingMessageNotification → sendLoggingMessage
    """
    # Remove "Notification" suffix
    base = notification_type.replace("Notification", "")
    # First letter lowercase for method name
    if base:
        base = base[0].lower() + base[1:]
    return f"send{base[0].upper() + base[1:]}" if base else "send"


def get_notification_direction(
    notif_type: str, client_notifications: set, server_notifications: set
) -> str:
    """Determine the direction of a notification.

    Note: ClientNotification = sent BY client, ServerNotification = sent BY server.
    """
    is_client = notif_type in client_notifications
    is_server = notif_type in server_notifications

    if is_client and is_server:
        return "bidirectional"
    elif is_client:
        return "client_to_server"  # Client sends, server receives
    elif is_server:
        return "server_to_client"  # Server sends, client receives
    return "unknown"


def load_spec_notifications(schema: dict) -> dict:
    """Load notifications from spec schema with their directions."""
    client_notifications = set(spec_extraction.get_requests_from_union(schema, "ClientNotification"))
    server_notifications = set(spec_extraction.get_requests_from_union(schema, "ServerNotification"))

    all_notifications = client_notifications | server_notifications
    notifications = {}

    for notif_type in all_notifications:
        # Extract the method name (e.g., "notifications/progress")
        method_name = spec_extraction.extract_method_name(schema, notif_type)
        if not method_name:
            continue

        direction = get_notification_direction(
            notif_type, client_notifications, server_notifications
        )
        send_method = to_send_method_name(notif_type)

        notifications[method_name] = {
            "notification_type": notif_type,
            "direction": direction,
            "send_method": send_method,
        }

    return notifications


def load_spec_methods(schema: dict) -> dict:
    """Load methods from spec schema with their directions."""
    client_requests = set(spec_extraction.get_requests_from_union(schema, "ClientRequest"))
    server_requests = set(spec_extraction.get_requests_from_union(schema, "ServerRequest"))

    # Build mapping from method name to request type
    all_request_types = {}
    for req_type in client_requests | server_requests:
        method_name = spec_extraction.extract_method_name(schema, req_type)
        if method_name:
            all_request_types[method_name] = req_type

    methods = {}
    for method_name, req_type in all_request_types.items():
        direction = get_method_direction(method_name, client_requests, server_requests, all_request_types)
        methods[method_name] = {
            "request_type": req_type,
            "direction": direction,
            "swift_method": to_swift_method_name(method_name),
            "client_handler": to_client_handler_name(method_name),
        }

    return methods


def get_module_id_from_method(method_name: str) -> str:
    """Derive module ID from method name.

    Examples:
        resources/list → resources
        prompts/get → prompts
        completion/complete → completions
        logging/setLevel → logging
    """
    parts = method_name.split("/")
    if len(parts) >= 1:
        category = parts[0]
        # Normalize to plural for consistency
        if category == "completion":
            return "completions"
        return category
    return "unknown"


def get_module_id_from_notification(notif_name: str) -> str:
    """Derive module ID from notification name.

    Examples:
        notifications/initialized → lifecycle
        notifications/progress → progress
        notifications/resources/list_changed → resources
        notifications/tools/list_changed → tools
    """
    parts = notif_name.split("/")
    if len(parts) >= 2:
        # notifications/X or notifications/X/Y
        category = parts[1]
        if category == "initialized":
            return "lifecycle"
        if category in ("resources", "prompts", "tools", "roots", "tasks"):
            return category
        if category == "message":
            return "logging"
        if category == "elicitation":
            return "elicitation"
        return category
    return "unknown"


def find_or_create_module(manifest: dict, module_id: str, dry_run: bool = False) -> dict:
    """Find existing module or create a new one."""
    for module in manifest.get("modules", []):
        if module.get("id") == module_id:
            return module

    # Create new module
    new_module = {
        "id": module_id,
        "category": "feature",
        "description": f"Auto-generated module for {module_id}",
        "swift_file": f"Sources/MCP/TODO/{module_id.title()}.swift",
        "methods": [],
        "notifications": [],
        "verification": {"status": "pending", "notes": "Auto-added by sync"},
    }

    if not dry_run:
        manifest.setdefault("modules", []).append(new_module)

    return new_module


def find_method_in_manifest(manifest: dict, method_name: str) -> tuple[dict | None, dict | None]:
    """Find a method entry in the manifest. Returns (module, method_entry)."""
    for module in manifest.get("modules", []):
        for method in module.get("methods", []):
            if method.get("name") == method_name:
                return module, method
    return None, None


def sync_methods(manifest: dict, spec_methods: dict, dry_run: bool = False) -> int:
    """Sync manifest methods with spec. Returns count of changes."""
    changes = 0

    for method_name, spec_info in sorted(spec_methods.items()):
        module, method_entry = find_method_in_manifest(manifest, method_name)

        if method_entry is None:
            # Auto-add the method to the appropriate module
            module_id = get_module_id_from_method(method_name)
            module = find_or_create_module(manifest, module_id, dry_run)

            direction = spec_info["direction"]
            swift_method = spec_info["swift_method"]
            client_handler = spec_info.get("client_handler")

            new_method = {
                "name": method_name,
                "swift": spec_info["request_type"].replace("Request", ""),
                "verification": {"status": "pending", "notes": "Auto-added by sync"},
            }

            # Add implementation fields based on direction
            if direction in ("client_to_server", "bidirectional"):
                new_method["client_method"] = swift_method
            if direction in ("server_to_client", "bidirectional"):
                new_method["server_method"] = swift_method
            if direction == "server_to_client" and client_handler:
                new_method["client_handler"] = client_handler

            if dry_run:
                print(f"  + {method_name} → module '{module_id}'")
            else:
                module.setdefault("methods", []).append(new_method)
            changes += 1
            continue

        # Update existing method entry with any missing fields
        direction = spec_info["direction"]
        swift_method = spec_info["swift_method"]
        client_handler = spec_info.get("client_handler")

        if direction == "client_to_server":
            if "client_method" not in method_entry:
                if dry_run:
                    print(f"  + {method_name}: client_method: {swift_method}")
                else:
                    method_entry["client_method"] = swift_method
                changes += 1
        elif direction == "server_to_client":
            if "server_method" not in method_entry:
                if dry_run:
                    print(f"  + {method_name}: server_method: {swift_method}")
                else:
                    method_entry["server_method"] = swift_method
                changes += 1
            if client_handler and "client_handler" not in method_entry:
                if dry_run:
                    print(f"  + {method_name}: client_handler: {client_handler}")
                else:
                    method_entry["client_handler"] = client_handler
                changes += 1
        elif direction == "bidirectional":
            if "client_method" not in method_entry:
                if dry_run:
                    print(f"  + {method_name}: client_method: {swift_method}")
                else:
                    method_entry["client_method"] = swift_method
                changes += 1
            if "server_method" not in method_entry:
                if dry_run:
                    print(f"  + {method_name}: server_method: {swift_method}")
                else:
                    method_entry["server_method"] = swift_method
                changes += 1

    return changes


def find_notification_in_manifest(manifest: dict, notif_name: str) -> tuple[dict | None, dict | None]:
    """Find a notification entry in the manifest. Returns (module, notification_entry)."""
    for module in manifest.get("modules", []):
        for notification in module.get("notifications", []):
            if notification.get("name") == notif_name:
                return module, notification
    return None, None


def sync_notifications(manifest: dict, spec_notifications: dict, dry_run: bool = False) -> int:
    """Sync manifest notifications with spec. Returns count of changes."""
    changes = 0

    for notif_name, spec_info in sorted(spec_notifications.items()):
        module, notif_entry = find_notification_in_manifest(manifest, notif_name)

        if notif_entry is None:
            # Auto-add the notification to the appropriate module
            module_id = get_module_id_from_notification(notif_name)
            module = find_or_create_module(manifest, module_id, dry_run)

            direction = spec_info["direction"]
            send_method = spec_info["send_method"]

            # Determine sender
            if direction == "client_to_server":
                sender = "client"
            elif direction == "server_to_client":
                sender = "server"
            else:
                sender = "both"

            new_notification = {
                "name": notif_name,
                "swift": spec_info["notification_type"],
                "sender": sender,
                "verification": {"status": "pending", "notes": "Auto-added by sync"},
            }

            # Add send methods based on direction
            if direction in ("server_to_client", "bidirectional"):
                new_notification["server_send"] = send_method
            if direction in ("client_to_server", "bidirectional"):
                new_notification["client_send"] = "notify"

            if dry_run:
                print(f"  + {notif_name} → module '{module_id}'")
            else:
                module.setdefault("notifications", []).append(new_notification)
            changes += 1
            continue

        # Update existing notification entry with any missing fields
        direction = spec_info["direction"]
        send_method = spec_info["send_method"]

        if "sender" not in notif_entry:
            if direction == "client_to_server":
                sender = "client"
            elif direction == "server_to_client":
                sender = "server"
            else:
                sender = "both"
            if dry_run:
                print(f"  + {notif_name}: sender: {sender}")
            else:
                notif_entry["sender"] = sender
            changes += 1

        if direction in ("server_to_client", "bidirectional"):
            if "server_send" not in notif_entry:
                if dry_run:
                    print(f"  + {notif_name}: server_send: {send_method}")
                else:
                    notif_entry["server_send"] = send_method
                changes += 1

        if direction in ("client_to_server", "bidirectional"):
            if "client_send" not in notif_entry:
                if dry_run:
                    print(f"  + {notif_name}: client_send: notify")
                else:
                    notif_entry["client_send"] = "notify"
                changes += 1

    return changes


# =============================================================================
# Type Sync
# =============================================================================

def sync_types(
    manifest: dict,
    spec_types: set[str],
    swift_types: dict[str, dict],
    spec_to_swift: dict[str, str],
    dry_run: bool = False,
) -> int:
    """Sync manifest types with spec. Returns count of changes.

    Uses programmatic Swift type discovery to find matching types.
    Falls back to TODO_ placeholder only if no match is found.
    """
    changes = 0

    # Ensure types section exists
    if "types" not in manifest:
        manifest["types"] = {}

    # Get manifest type names including spec_name overrides
    manifest_type_names = set()
    for type_name, type_def in manifest.get("types", {}).items():
        manifest_type_names.add(type_name)
        if isinstance(type_def, dict) and "spec_name" in type_def:
            manifest_type_names.add(type_def["spec_name"])

    for spec_type in sorted(spec_types):
        if spec_type not in manifest_type_names:
            # Try to find matching Swift type programmatically
            swift_name, swift_file = find_swift_type(spec_type, spec_to_swift, swift_types)

            if swift_name:
                # Found a match - use discovered values
                new_type = {
                    "swift": swift_name,
                    "file": swift_file or "",
                    "verification": {"status": "pending", "notes": "Auto-discovered from Swift codebase"},
                }
                if dry_run:
                    print(f"  + {spec_type} → {swift_name}")
            else:
                # No match found - use placeholder
                new_type = {
                    "swift": f"TODO_{spec_type}",
                    "file": "",
                    "verification": {"status": "pending", "notes": "No matching Swift type found"},
                }
                if dry_run:
                    print(f"  + {spec_type} → TODO (no Swift match)")

            if not dry_run:
                manifest["types"][spec_type] = new_type
            changes += 1

    return changes


# =============================================================================
# Enum Sync
# =============================================================================

def sync_enums(manifest: dict, spec_enums: dict[str, list[str]], dry_run: bool = False) -> int:
    """Sync manifest enums with spec. Returns count of changes."""
    changes = 0

    # Ensure enums section exists
    if "enums" not in manifest:
        manifest["enums"] = []

    manifest_enums = {e["name"]: e for e in manifest.get("enums", [])}

    for enum_name, spec_cases in sorted(spec_enums.items()):
        if enum_name not in manifest_enums:
            # Add new enum
            new_enum = {
                "name": enum_name,
                "swift": enum_name,  # Default to same name
                "file": "",  # To be filled in manually
                "cases": [{"spec": case, "swift": case} for case in spec_cases],
                "verification": {"status": "pending", "notes": ""},
            }
            if dry_run:
                print(f"  + {enum_name}: new enum with {len(spec_cases)} cases")
            else:
                manifest["enums"].append(new_enum)
            changes += 1
        else:
            # Check for missing cases
            existing = manifest_enums[enum_name]
            existing_spec_cases = {c.get("spec", c.get("name", "")) for c in existing.get("cases", [])}

            for spec_case in spec_cases:
                if spec_case not in existing_spec_cases:
                    if dry_run:
                        print(f"  + {enum_name}: missing case '{spec_case}'")
                    else:
                        existing.setdefault("cases", []).append({"spec": spec_case, "swift": spec_case})
                    changes += 1

    return changes


# =============================================================================
# Error Code Sync
# =============================================================================

# Standard JSON-RPC error code to Swift case mappings
JSONRPC_ERROR_SWIFT_CASES = {
    "PARSE_ERROR": "parseError",
    "INVALID_REQUEST": "invalidRequest",
    "METHOD_NOT_FOUND": "methodNotFound",
    "INVALID_PARAMS": "invalidParams",
    "INTERNAL_ERROR": "internalError",
}


def sync_error_codes(manifest: dict, spec_codes: dict[str, int], dry_run: bool = False) -> int:
    """Sync manifest error codes with spec. Returns count of changes."""
    changes = 0

    # Ensure error_codes section exists
    if "error_codes" not in manifest:
        manifest["error_codes"] = []

    manifest_codes = {c["name"]: c for c in manifest.get("error_codes", [])}

    for code_name, code_value in sorted(spec_codes.items()):
        if code_name not in manifest_codes:
            # Determine Swift mapping
            swift_case = JSONRPC_ERROR_SWIFT_CASES.get(code_name)
            category = "jsonrpc" if code_name in JSONRPC_ERROR_SWIFT_CASES else "mcp"

            new_code = {
                "name": code_name,
                "code": code_value,
                "category": category,
                "verification": {"status": "pending", "notes": ""},
            }

            if swift_case:
                new_code["swift"] = swift_case
            else:
                new_code["swift_handling"] = "serverError(code:message:)"

            if dry_run:
                print(f"  + {code_name} ({code_value}): new error code")
            else:
                manifest["error_codes"].append(new_code)
            changes += 1

    return changes


# =============================================================================
# Capability Sync
# =============================================================================

def sync_capabilities(manifest: dict, client_caps: dict, server_caps: dict, dry_run: bool = False) -> int:
    """Sync manifest capabilities with spec. Returns count of changes."""
    changes = 0

    # Ensure capabilities section exists
    if "capabilities" not in manifest:
        manifest["capabilities"] = {"client": [], "server": []}

    def sync_cap_list(cap_type: str, spec_caps: dict) -> int:
        nonlocal changes
        cap_list = manifest["capabilities"].setdefault(cap_type, [])
        existing = {c["property"]: c for c in cap_list}

        for prop_name, nested in sorted(spec_caps.items()):
            if prop_name not in existing:
                new_cap = {
                    "property": prop_name,
                    "swift": prop_name,  # Default to same name
                    "nested": [{"name": n, "swift": n} for n in sorted(nested.keys())],
                    "verification": {"status": "pending", "notes": ""},
                }
                if dry_run:
                    print(f"  + {cap_type}.{prop_name}: new capability")
                else:
                    cap_list.append(new_cap)
                changes += 1
            else:
                # Check for missing nested properties
                cap_entry = existing[prop_name]
                existing_nested = {n.get("name", n.get("swift", "")) for n in cap_entry.get("nested", [])}

                for nested_name in nested.keys():
                    if nested_name not in existing_nested:
                        if dry_run:
                            print(f"  + {cap_type}.{prop_name}: missing nested '{nested_name}'")
                        else:
                            cap_entry.setdefault("nested", []).append({"name": nested_name, "swift": nested_name})
                        changes += 1

        return changes

    print("  ClientCapabilities:")
    sync_cap_list("client", client_caps)

    print("  ServerCapabilities:")
    sync_cap_list("server", server_caps)

    return changes


# =============================================================================
# Deprecated Types Sync
# =============================================================================

def sync_deprecated(manifest: dict, spec_deprecated: dict[str, str], dry_run: bool = False) -> int:
    """Sync manifest deprecated types with spec. Returns count of changes."""
    changes = 0

    # Ensure deprecated section exists
    if "deprecated" not in manifest:
        manifest["deprecated"] = []

    manifest_deprecated = {d["name"]: d for d in manifest.get("deprecated", [])}

    for type_name, description in sorted(spec_deprecated.items()):
        if type_name not in manifest_deprecated:
            new_deprecated = {
                "name": type_name,
                "replacement": "",  # To be filled in manually
                "notes": description[:100] if description else "",
            }
            if dry_run:
                print(f"  + {type_name}: newly deprecated")
            else:
                manifest["deprecated"].append(new_deprecated)
            changes += 1

    return changes


def main():
    dry_run = "--dry-run" in sys.argv

    script_dir = Path(__file__).parent
    manifest_path = script_dir.parent / "manifest.yaml"
    spec_dir = script_dir.parent.parent.parent / "modelcontextprotocol/schema"
    sources_dir = script_dir.parent.parent / "Sources" / "MCP"
    protocol_version = "2025-11-25"

    try:
        schema = spec_extraction.load_schema(spec_dir.parent, protocol_version)
    except FileNotFoundError as e:
        print(str(e))
        print("Make sure the modelcontextprotocol repo is cloned alongside swift-mcp")
        sys.exit(1)

    yaml = create_yaml()

    with open(manifest_path) as f:
        manifest = yaml.load(f)

    # Extract Swift types from codebase for programmatic matching
    print("Extracting Swift types from codebase...")
    swift_types = extract_swift_types(sources_dir, script_dir)
    spec_to_swift = build_spec_to_swift_mapping(swift_types)
    print(f"  Found {len(swift_types)} Swift types")
    print()

    # Load all spec data using shared extraction module
    spec_types = spec_extraction.extract_types(schema)
    spec_methods = load_spec_methods(schema)
    spec_notifications = load_spec_notifications(schema)
    spec_enums = spec_extraction.extract_enums(schema)
    spec_error_codes = spec_extraction.extract_error_codes(spec_dir.parent, protocol_version)
    client_caps, server_caps = spec_extraction.extract_all_capabilities(schema)
    spec_deprecated = spec_extraction.extract_deprecated(schema)

    print("Spec contents:")
    print(f"  {len(spec_types)} types")
    print(f"  {len(spec_methods)} methods")
    print(f"  {len(spec_notifications)} notifications")
    print(f"  {len(spec_enums)} enums")
    print(f"  {len(spec_error_codes)} error codes")
    print(f"  {len(client_caps)} client capabilities, {len(server_caps)} server capabilities")
    print(f"  {len(spec_deprecated)} deprecated types")
    print()

    if dry_run:
        print("Dry run - showing changes:\n")

    # Sync all categories
    print("Types:")
    type_changes = sync_types(manifest, spec_types, swift_types, spec_to_swift, dry_run)

    print("\nMethods:")
    method_changes = sync_methods(manifest, spec_methods, dry_run)

    print("\nNotifications:")
    notif_changes = sync_notifications(manifest, spec_notifications, dry_run)

    print("\nEnums:")
    enum_changes = sync_enums(manifest, spec_enums, dry_run)

    print("\nError Codes:")
    error_code_changes = sync_error_codes(manifest, spec_error_codes, dry_run)

    print("\nCapabilities:")
    cap_changes = sync_capabilities(manifest, client_caps, server_caps, dry_run)

    print("\nDeprecated:")
    deprecated_changes = sync_deprecated(manifest, spec_deprecated, dry_run)

    total_changes = (type_changes + method_changes + notif_changes + enum_changes +
                     error_code_changes + cap_changes + deprecated_changes)

    print()
    if total_changes == 0:
        print("✓ Manifest is in sync with spec")
    elif dry_run:
        print(f"Would make {total_changes} total changes:")
        print(f"  {type_changes} types, {method_changes} methods, {notif_changes} notifications")
        print(f"  {enum_changes} enums, {error_code_changes} error codes")
        print(f"  {cap_changes} capabilities, {deprecated_changes} deprecated")
    else:
        with open(manifest_path, "w") as f:
            yaml.dump(manifest, f)
        print(f"✓ Made {total_changes} changes to manifest")


if __name__ == "__main__":
    main()
