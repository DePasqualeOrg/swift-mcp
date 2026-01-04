#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["ruamel.yaml"]
# ///
"""
MCP Swift SDK Protocol Coverage Verification

Performs comprehensive 3-way verification: Spec ↔ Manifest ↔ Swift

Usage:
    uv run verify-protocol-coverage.py [--skip-clone]

Exit codes:
    0 - All verifications passed
    1 - One or more gaps or errors found
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from ruamel.yaml import YAML

from lib import spec_extraction
from lib.output import (
    RED, GREEN, YELLOW, CYAN, DIM, NC,
    print_header, print_ok, print_error, print_warning, print_dim,
)


@dataclass
class VerificationResults:
    """Holds all verification results."""
    # File validation
    file_errors: int = 0

    # Spec → Manifest (gaps only, since we're checking coverage)
    types_spec_manifest: int = 0
    methods_spec_manifest: int = 0
    notifs_spec_manifest: int = 0
    caps_spec_manifest: int = 0
    enums_spec_manifest: int = 0
    errors_spec_manifest: int = 0

    # Manifest → Swift (found + missing)
    types_swift_found: int = 0
    types_swift_missing: int = 0
    methods_swift_found: int = 0
    methods_swift_missing: int = 0
    notifs_swift_found: int = 0
    notifs_swift_missing: int = 0
    caps_swift_found: int = 0
    caps_swift_missing: int = 0
    enums_swift_found: int = 0
    enums_swift_missing: int = 0
    errors_swift_found: int = 0
    errors_swift_missing: int = 0

    # Other
    not_impl_count: int = 0
    builtin_count: int = 0

# Default protocol version (can be overridden by manifest)
DEFAULT_PROTOCOL_VERSION = "2025-11-25"


def method_exists(method_name: str, content: str) -> bool:
    """Check if a public/internal method exists in Swift source content.

    Excludes:
    - Private/fileprivate methods
    - Methods inside comments
    """
    # First, strip out comments to avoid false positives
    # Remove single-line comments
    content_no_comments = re.sub(r'//.*$', '', content, flags=re.MULTILINE)
    # Remove multi-line comments
    content_no_comments = re.sub(r'/\*.*?\*/', '', content_no_comments, flags=re.DOTALL)

    # Match func that is NOT preceded by private/fileprivate
    # Pattern: optional access modifier (not private/fileprivate), then func name
    pattern = rf'(?:^|(?<!\w))(?:public\s+|internal\s+|open\s+)?func\s+{re.escape(method_name)}\s*[<(]'
    return bool(re.search(pattern, content_no_comments, re.MULTILINE))


class Verifier:
    def __init__(self, script_dir: Path, skip_clone: bool = False):
        self.script_dir = script_dir
        self.manifest_path = script_dir.parent / "manifest.yaml"
        self.swift_sdk = script_dir.parent.parent
        self.skip_clone = skip_clone
        self.spec_cache = Path("/tmp/mcp-spec-cache")
        self.temp_dir = None

        self.yaml = YAML()
        self.manifest = None
        self.swift_types = set()
        self.protocol_version = DEFAULT_PROTOCOL_VERSION

        # Extracted from manifest
        self.not_impl_files = set()
        self.not_impl_types = set()
        self.builtin_types = set()

    def load_manifest(self):
        with open(self.manifest_path) as f:
            self.manifest = self.yaml.load(f)

        # Use manifest as source of truth for protocol version
        self.protocol_version = self.manifest.get(
            'target_protocol_version', DEFAULT_PROTOCOL_VERSION
        )

    def extract_not_implemented(self):
        """Extract not-implemented files and types from manifest."""
        # From modules
        for module in self.manifest.get('modules', []):
            if module.get('implementation') == 'todo':
                if 'swift_file' in module:
                    self.not_impl_files.add(module['swift_file'])

            for method in module.get('methods', []):
                if method.get('implementation') == 'todo':
                    if 'swift' in method:
                        self.not_impl_types.add(method['swift'])

            for notification in module.get('notifications', []):
                if notification.get('implementation') == 'todo':
                    if 'swift' in notification:
                        self.not_impl_types.add(notification['swift'])

        # From types
        for type_name, type_def in self.manifest.get('types', {}).items():
            if isinstance(type_def, dict):
                if type_def.get('implementation') == 'todo':
                    if 'swift' in type_def:
                        swift_val = type_def['swift']
                        if isinstance(swift_val, list):
                            self.not_impl_types.update(swift_val)
                        else:
                            self.not_impl_types.add(swift_val)

                if type_def.get('kind') == 'builtin':
                    if 'swift' in type_def:
                        swift_val = type_def['swift']
                        # Strip array notation
                        clean = str(swift_val).strip('[]"')
                        self.builtin_types.add(clean)

    def build_swift_type_index(self) -> int:
        """Build index of Swift types using AST extractor or regex fallback."""
        print_header("BUILDING SWIFT TYPE INDEX")

        extractor = self.script_dir / "extractors" / "swift"

        if extractor.is_dir():
            print("Using AST-based Swift type extractor...")
            result = subprocess.run(
                ["swift", "run", "extract-swift-types", str(self.swift_sdk / "Sources")],
                cwd=extractor,
                capture_output=True, text=True,
                timeout=60,
            )
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                if line and ':' in line:
                    type_name = line.split(':')[0]
                    self.swift_types.add(type_name)
        else:
            print("Using regex fallback for Swift type extraction...")
            pattern = re.compile(
                r'^(?:public |open |internal |private |fileprivate )?'
                r'(?:struct|class|enum|protocol|typealias|actor) ([A-Z][A-Za-z0-9_]*)'
            )
            for swift_file in (self.swift_sdk / "Sources").rglob("*.swift"):
                if ".build" in str(swift_file):
                    continue
                try:
                    content = swift_file.read_text()
                    for match in pattern.finditer(content):
                        self.swift_types.add(match.group(1))
                except Exception:
                    pass

        print(f"Found {len(self.swift_types)} Swift types")
        return len(self.swift_types)

    def validate_swift_files(self) -> int:
        """Validate that swift_file paths exist."""
        print_header("SWIFT FILE VALIDATION")

        errors = 0
        checked = set()

        # Check swift_file entries from modules
        for module in self.manifest.get('modules', []):
            swift_file = module.get('swift_file')
            if not swift_file or swift_file in checked:
                continue
            checked.add(swift_file)

            full_path = self.swift_sdk / swift_file
            is_not_impl = module.get('implementation') == 'todo'

            if full_path.exists():
                print_ok(swift_file)
            elif is_not_impl:
                pass  # Will show in not-implemented section
            else:
                print_error(swift_file)
                errors += 1

        # Check file entries from types
        for type_name, type_def in self.manifest.get('types', {}).items():
            if not isinstance(type_def, dict):
                continue

            files = type_def.get('file', [])
            if isinstance(files, str):
                files = [files]

            is_not_impl = type_def.get('implementation') == 'todo'

            for swift_file in files:
                if not swift_file or swift_file in checked:
                    continue
                if not swift_file.endswith('.swift'):
                    continue
                checked.add(swift_file)

                full_path = self.swift_sdk / swift_file
                if full_path.exists():
                    print_ok(swift_file)
                elif is_not_impl:
                    pass
                else:
                    print_error(swift_file)
                    errors += 1

        return errors

    def clone_spec(self) -> Path:
        """Clone or use cached MCP specification."""
        if self.skip_clone and self.spec_cache.exists():
            print("Using cached spec (--skip-clone)...")
            return self.spec_cache

        print("Cloning MCP specification (fresh copy)...")
        self.temp_dir = Path(tempfile.mkdtemp())

        try:
            spec_dir = self.temp_dir / "spec"

            result = subprocess.run(
                ["git", "clone", "--depth", "1", "--quiet",
                 "https://github.com/modelcontextprotocol/modelcontextprotocol.git",
                 str(spec_dir)],
                capture_output=True
            )

            if result.returncode != 0:
                raise RuntimeError(
                    f"Failed to clone specification repository: {result.stderr.decode()}"
                )

            # Cache for future use
            if self.spec_cache.exists():
                shutil.rmtree(self.spec_cache)
            shutil.copytree(spec_dir, self.spec_cache)

            return spec_dir
        except Exception:
            # Clean up temp directory on any error
            if self.temp_dir and self.temp_dir.exists():
                shutil.rmtree(self.temp_dir)
            self.temp_dir = None
            raise

    def extract_spec_types(self, spec_dir: Path) -> set:
        """Extract type names from spec schema.json."""
        print_header("EXTRACTING SPEC TYPES")

        schema = spec_extraction.load_schema(spec_dir, self.protocol_version)
        spec_types = spec_extraction.extract_types(schema)

        print(f"Found {len(spec_types)} types in spec schema")
        return spec_types

    def check_spec_to_manifest(self, spec_types: set) -> int:
        """Check that all spec types are documented in manifest."""
        print_header("SPEC → MANIFEST")
        print_dim("(Types in spec but not documented in manifest)")
        print()

        # Get manifest type names including spec_name overrides
        manifest_types = set()
        for type_name, type_def in self.manifest.get('types', {}).items():
            manifest_types.add(type_name)
            if isinstance(type_def, dict) and 'spec_name' in type_def:
                manifest_types.add(type_def['spec_name'])

        errors = 0
        for spec_type in sorted(spec_types):
            if spec_type not in manifest_types:
                print_error(spec_type)
                errors += 1

        if errors == 0:
            print_ok("All spec types are documented in manifest")

        return errors

    def check_manifest_to_swift(self) -> tuple[int, int, int, int]:
        """Check that all manifest types exist in Swift."""
        print_header("MANIFEST → SWIFT (types section)")

        errors = 0
        found = 0
        not_impl_count = 0
        builtin_count = 0

        for type_name, type_def in self.manifest.get('types', {}).items():
            if not isinstance(type_def, dict):
                continue

            # Check if not implemented
            if type_def.get('implementation') == 'todo':
                not_impl_count += 1
                continue

            # Check if builtin
            if type_def.get('kind') == 'builtin':
                builtin_count += 1
                continue

            # Default swift name to type name if not specified
            swift_val = type_def.get('swift', type_name)
            if not swift_val or swift_val == "null":
                continue

            # Handle array notation [Type1, Type2]
            swift_names = swift_val if isinstance(swift_val, list) else [swift_val]

            for swift_name in swift_names:
                # Clean up the name
                swift_name = str(swift_name).strip('[]"\'')
                if not swift_name:
                    continue

                if swift_name in self.swift_types:
                    print_ok(f"{type_name} → {swift_name}")
                    found += 1
                else:
                    print_error(f"{type_name} (expected: {swift_name})")
                    errors += 1

        print()
        if errors == 0:
            print_ok("All manifest types exist in Swift")
        if not_impl_count > 0 or builtin_count > 0:
            print_dim(f"({not_impl_count} not_implemented, {builtin_count} builtin - skipped)")

        return errors, found, not_impl_count, builtin_count

    def check_methods(self, spec_dir: Path) -> tuple[int, int]:
        """Check that all protocol methods and notifications are covered.

        Returns: (method_gaps, notification_gaps)
        """
        print_header("METHOD & NOTIFICATION COVERAGE")

        schema = spec_extraction.load_schema(spec_dir, self.protocol_version)
        spec_methods, spec_notifs = spec_extraction.extract_methods_and_notifications(schema)

        # Get manifest methods and notifications
        manifest_methods = set()
        manifest_notifs = set()
        for module in self.manifest.get('modules', []):
            for method in module.get('methods', []):
                if 'name' in method:
                    manifest_methods.add(method['name'])
            for notification in module.get('notifications', []):
                if 'name' in notification:
                    manifest_notifs.add(notification['name'])

        method_errors = 0
        notif_errors = 0

        print(f"{CYAN}Methods:{NC}")
        for method in sorted(spec_methods):
            if method in manifest_methods:
                print_ok(method)
            else:
                print_error(method)
                method_errors += 1

        print()
        print(f"{CYAN}Notifications:{NC}")
        for notif in sorted(spec_notifs):
            if notif in manifest_notifs:
                print_ok(notif)
            else:
                print_error(notif)
                notif_errors += 1

        print()
        total_errors = method_errors + notif_errors
        if total_errors == 0:
            print_ok("All protocol methods and notifications are covered")

        return method_errors, notif_errors

    def check_method_implementations(self) -> tuple[int, int]:
        """Check that client_method, server_method, and client_handler implementations exist in Swift."""
        print_header("METHOD IMPLEMENTATIONS")

        errors = 0
        found = 0

        # Read Swift source files once
        client_content = ""
        server_content = ""
        client_path = self.swift_sdk / "Sources/MCP/Client/Client.swift"
        server_path = self.swift_sdk / "Sources/MCP/Server/Server.swift"

        if client_path.exists():
            client_content = client_path.read_text()
        if server_path.exists():
            server_content = server_path.read_text()

        for module in self.manifest.get('modules', []):
            for method in module.get('methods', []):
                method_name = method.get('name', '')

                # Check client_method
                if client_method := method.get('client_method'):
                    if method_exists(client_method, client_content):
                        print_ok(f"{method_name}: client_method '{client_method}'")
                        found += 1
                    else:
                        print_error(f"{method_name}: client_method '{client_method}' not found")
                        errors += 1

                # Check server_method
                if server_method := method.get('server_method'):
                    if method_exists(server_method, server_content):
                        print_ok(f"{method_name}: server_method '{server_method}'")
                        found += 1
                    else:
                        print_error(f"{method_name}: server_method '{server_method}' not found")
                        errors += 1

                # Check client_handler (for server→client methods)
                if client_handler := method.get('client_handler'):
                    if method_exists(client_handler, client_content):
                        print_ok(f"{method_name}: client_handler '{client_handler}'")
                        found += 1
                    else:
                        print_error(f"{method_name}: client_handler '{client_handler}' not found")
                        errors += 1

                # Check handler_registration (for methods registered via enableTaskSupport, etc.)
                if handler_reg := method.get('handler_registration'):
                    reg_file = self.swift_sdk / handler_reg['file']
                    pattern = handler_reg['pattern']
                    if reg_file.exists():
                        reg_content = reg_file.read_text()
                        if pattern in reg_content:
                            print_ok(f"{method_name}: handler_registration '{pattern}'")
                            found += 1
                        else:
                            print_error(f"{method_name}: handler_registration pattern '{pattern}' not found in {handler_reg['file']}")
                            errors += 1
                    else:
                        print_error(f"{method_name}: handler_registration file '{handler_reg['file']}' not found")
                        errors += 1

        print()
        if errors == 0:
            print_ok(f"All {found} method implementations found")

        return errors, found

    def extract_spec_enums(self, spec_dir: Path) -> dict[str, list[str]]:
        """Extract enum definitions from spec schema."""
        try:
            schema = spec_extraction.load_schema(spec_dir, self.protocol_version)
            return spec_extraction.extract_enums(schema)
        except FileNotFoundError:
            return {}

    def extract_swift_enum_cases(self, enum_name: str) -> list[str] | None:
        """Extract cases from a Swift enum definition."""
        # Search all Swift files for the enum definition
        for swift_file in (self.swift_sdk / "Sources").rglob("*.swift"):
            if ".build" in str(swift_file):
                continue
            try:
                content = swift_file.read_text()
            except Exception:
                continue

            # Look for enum definition
            enum_pattern = rf'enum\s+{re.escape(enum_name)}\s*[^{{]*\{{'
            enum_match = re.search(enum_pattern, content)
            if not enum_match:
                continue

            # Find the enum body (handle nested braces)
            start = enum_match.end() - 1  # Start at the opening brace
            brace_count = 1
            pos = start + 1
            while pos < len(content) and brace_count > 0:
                if content[pos] == '{':
                    brace_count += 1
                elif content[pos] == '}':
                    brace_count -= 1
                pos += 1

            enum_body = content[start:pos]

            # Extract case names, handling raw values like: case inputRequired = "input_required"
            cases = []
            case_pattern = r'case\s+(\w+)(?:\s*=\s*["\']([^"\']+)["\'])?'
            for match in re.finditer(case_pattern, enum_body):
                case_name = match.group(1)
                raw_value = match.group(2)
                # Use raw value if present (for JSON serialization), otherwise convert camelCase to snake_case
                if raw_value:
                    cases.append(raw_value)
                else:
                    cases.append(case_name)

            return sorted(cases) if cases else None

        return None

    def extract_spec_error_codes(self, spec_dir: Path) -> dict[str, int]:
        """Extract error code constants from spec schema.ts."""
        return spec_extraction.extract_error_codes(spec_dir, self.protocol_version)

    def extract_capability_properties(self, schema: dict, cap_type: str) -> dict:
        """Extract capability properties from schema, returning {prop_name: {nested_props}}."""
        return spec_extraction.extract_capabilities(schema, cap_type)

    def check_capabilities(self, spec_dir: Path) -> tuple[int, int, int, int]:
        """Check capabilities: Spec → Manifest → Swift.

        Returns: (spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing)
        """
        print_header("CAPABILITY STRUCTURE VERIFICATION")

        spec_manifest_found = 0
        spec_manifest_gaps = 0
        swift_found = 0
        swift_missing = 0

        # Load spec capabilities
        schema_path = spec_dir / "schema" / self.protocol_version / "schema.json"
        if not schema_path.exists():
            print_error(f"Schema not found at {schema_path}")
            return 0, 0, 0, 1

        with open(schema_path) as f:
            schema = json.load(f)

        spec_client_caps = self.extract_capability_properties(schema, "ClientCapabilities")
        spec_server_caps = self.extract_capability_properties(schema, "ServerCapabilities")

        manifest_caps = self.manifest.get("capabilities", {})
        manifest_client = {c["property"]: c for c in manifest_caps.get("client", [])}
        manifest_server = {c["property"]: c for c in manifest_caps.get("server", [])}

        # Step 1: Spec → Manifest
        print(f"{CYAN}Spec → Manifest:{NC}")

        print(f"  ClientCapabilities:")
        for prop_name in sorted(spec_client_caps.keys()):
            if prop_name in manifest_client:
                print_ok(f"    {prop_name}")
                spec_manifest_found += 1
            else:
                print_error(f"    {prop_name}: not in manifest")
                spec_manifest_gaps += 1

        print(f"  ServerCapabilities:")
        for prop_name in sorted(spec_server_caps.keys()):
            if prop_name in manifest_server:
                print_ok(f"    {prop_name}")
                spec_manifest_found += 1
            else:
                print_error(f"    {prop_name}: not in manifest")
                spec_manifest_gaps += 1
        print()

        # Step 2: Manifest → Swift
        print(f"{CYAN}Manifest → Swift:{NC}")

        # Read Swift capability files
        client_path = self.swift_sdk / "Sources/MCP/Client/Client.swift"
        server_path = self.swift_sdk / "Sources/MCP/Server/Server.swift"

        client_content = client_path.read_text() if client_path.exists() else ""
        server_content = server_path.read_text() if server_path.exists() else ""

        def check_cap_list(cap_list: list, content: str, cap_type: str):
            nonlocal swift_missing, swift_found
            print(f"  {cap_type}:")

            for cap_entry in cap_list:
                prop_name = cap_entry["property"]
                # Default swift name to property name if not specified
                swift_name = cap_entry.get("swift", prop_name)
                nested = cap_entry.get("nested", [])
                status = cap_entry.get("verification", {}).get("status", "pending")

                if status == "missing" or swift_name == "null" or swift_name is None:
                    print_error(f"    {prop_name}: missing in Swift")
                    swift_missing += 1
                    continue

                # Check property exists
                if not re.search(rf'var\s+{swift_name}\s*:', content):
                    print_error(f"    {prop_name}: property '{swift_name}' not found")
                    swift_missing += 1
                    continue

                # Check nested properties
                nested_errors = []
                for nested_prop in nested:
                    nested_name = nested_prop.get("swift", nested_prop.get("name"))
                    if nested_name and not re.search(rf'var\s+{nested_name}\s*:', content):
                        nested_errors.append(nested_name)

                if nested_errors:
                    print_error(f"    {prop_name}: missing nested: {nested_errors}")
                    swift_missing += 1
                else:
                    nested_info = f" ({len(nested)} nested)" if nested else ""
                    print_ok(f"    {prop_name}{nested_info}")
                    swift_found += 1

        # Check client capabilities
        check_cap_list(manifest_caps.get("client", []), client_content, "ClientCapabilities")

        # Check server capabilities
        check_cap_list(manifest_caps.get("server", []), server_content, "ServerCapabilities")

        print()
        total_errors = spec_manifest_gaps + swift_missing
        if total_errors == 0:
            print_ok(f"All {swift_found} capability properties verified")

        return spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing

    def check_error_codes(self, spec_dir: Path) -> tuple[int, int, int, int]:
        """Check error codes: Spec → Manifest → Swift.

        Returns: (spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing)
        """
        print_header("ERROR CODE VERIFICATION")

        spec_manifest_found = 0
        spec_manifest_gaps = 0
        swift_found = 0
        swift_missing = 0

        manifest_codes = self.manifest.get("error_codes", [])
        manifest_code_names = {c["name"] for c in manifest_codes}
        spec_codes = self.extract_spec_error_codes(spec_dir)

        # Step 1: Spec → Manifest
        print(f"{CYAN}Spec → Manifest:{NC}")
        for code_name in sorted(spec_codes.keys()):
            if code_name in manifest_code_names:
                print_ok(f"{code_name} ({spec_codes[code_name]})")
                spec_manifest_found += 1
            else:
                print_error(f"{code_name} ({spec_codes[code_name]}): not in manifest")
                spec_manifest_gaps += 1
        print()

        # Step 2: Manifest → Swift
        print(f"{CYAN}Manifest → Swift:{NC}")

        # Read Swift error file
        error_path = self.swift_sdk / "Sources/MCP/Base/Error.swift"
        if not error_path.exists():
            print_error("Error.swift not found")
            return 0, 0, 0, 1

        swift_content = error_path.read_text()

        # Extract code mappings from Swift
        # Pattern: case .errorName: return -32XXX
        swift_codes = {}
        code_pattern = r'case\s+\.(\w+).*?:\s*return\s*(-\d+)'
        for match in re.finditer(code_pattern, swift_content, re.DOTALL):
            case_name = match.group(1)
            code = int(match.group(2))
            swift_codes[case_name] = code

        for code_entry in manifest_codes:
            spec_name = code_entry["name"]
            expected_code = code_entry["code"]
            swift_name = code_entry.get("swift")

            if swift_name:
                # Has a dedicated Swift case
                if swift_name in swift_codes:
                    actual_code = swift_codes[swift_name]
                    if actual_code == expected_code:
                        print_ok(f"{spec_name} ({expected_code}): {swift_name}")
                        swift_found += 1
                    else:
                        print_error(f"{spec_name}: expected {expected_code}, got {actual_code}")
                        swift_missing += 1
                else:
                    print_error(f"{spec_name} ({expected_code}): case '{swift_name}' not found")
                    swift_missing += 1
            else:
                # No dedicated case - handled via generic serverError
                handling = code_entry.get("swift_handling", "serverError(code:message:)")
                print_dim(f"{spec_name} ({expected_code}): {handling}")
                swift_found += 1

        print()
        total_errors = spec_manifest_gaps + swift_missing
        if total_errors == 0:
            print_ok(f"All {swift_found} error codes verified")

        return spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing

    def check_enums(self, spec_dir: Path) -> tuple[int, int, int, int]:
        """Check enums: Spec → Manifest → Swift.

        Returns: (spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing)
        """
        print_header("ENUM VERIFICATION")

        spec_manifest_found = 0
        spec_manifest_gaps = 0
        swift_found = 0
        swift_missing = 0

        manifest_enums = self.manifest.get("enums", [])
        manifest_enum_names = {e["name"] for e in manifest_enums}
        spec_enums = self.extract_spec_enums(spec_dir)

        # Step 1: Spec → Manifest
        print(f"{CYAN}Spec → Manifest:{NC}")
        for enum_name in sorted(spec_enums.keys()):
            if enum_name in manifest_enum_names:
                print_ok(f"{enum_name}")
                spec_manifest_found += 1
            else:
                print_error(f"{enum_name}: not in manifest")
                spec_manifest_gaps += 1
        print()

        # Step 2: Manifest → Swift
        print(f"{CYAN}Manifest → Swift:{NC}")
        for enum_entry in manifest_enums:
            enum_name = enum_entry["name"]
            # Default swift name to enum name if not specified
            swift_name = enum_entry.get("swift", enum_name)

            if not swift_name or swift_name == "null":
                print_error(f"{enum_name}: no Swift mapping in manifest")
                swift_missing += 1
                continue

            # Get expected values from spec
            spec_values = spec_enums.get(enum_name, [])
            if not spec_values:
                print(f"{YELLOW}WARNING:{NC} {enum_name}: not found in spec schema")
                continue

            # Get actual Swift cases
            swift_cases = self.extract_swift_enum_cases(swift_name)

            if swift_cases is None:
                print_error(f"{enum_name}: Swift enum '{swift_name}' not found")
                swift_missing += 1
                continue

            # Compare values
            spec_set = set(spec_values)
            swift_set = set(swift_cases)

            if spec_set == swift_set:
                print_ok(f"{enum_name}: {len(spec_values)} cases match")
                swift_found += 1
            else:
                missing = spec_set - swift_set
                extra = swift_set - spec_set
                if missing:
                    print_error(f"{enum_name}: missing cases: {sorted(missing)}")
                    swift_missing += 1
                if extra:
                    print(f"{YELLOW}WARNING:{NC} {enum_name}: extra cases: {sorted(extra)}")
                if not missing:
                    swift_found += 1

        print()
        total_errors = spec_manifest_gaps + swift_missing
        if total_errors == 0:
            print_ok(f"All {swift_found} enums verified")

        return spec_manifest_gaps, spec_manifest_found, swift_found, swift_missing

    def check_notification_implementations(self) -> tuple[int, int]:
        """Check that notification send methods exist in Swift."""
        print_header("NOTIFICATION IMPLEMENTATIONS")

        errors = 0
        found = 0

        # Read Swift source files
        server_context_content = ""
        client_content = ""

        # Server.Context contains send methods
        server_path = self.swift_sdk / "Sources/MCP/Server/Server.swift"
        client_path = self.swift_sdk / "Sources/MCP/Client/Client.swift"

        if server_path.exists():
            server_context_content = server_path.read_text()
        if client_path.exists():
            client_content = client_path.read_text()

        for module in self.manifest.get('modules', []):
            for notification in module.get('notifications', []):
                notif_name = notification.get('name', '')

                # Check server_send method
                if server_send := notification.get('server_send'):
                    if method_exists(server_send, server_context_content):
                        print_ok(f"{notif_name}: server_send '{server_send}'")
                        found += 1
                    else:
                        print_error(f"{notif_name}: server_send '{server_send}' not found")
                        errors += 1

                # Check client_send method (skip 'notify' as it's generic)
                if client_send := notification.get('client_send'):
                    if client_send == "notify":
                        # Generic notify() always exists
                        print_ok(f"{notif_name}: client_send 'notify' (generic)")
                        found += 1
                    elif method_exists(client_send, client_content):
                        print_ok(f"{notif_name}: client_send '{client_send}'")
                        found += 1
                    else:
                        print_error(f"{notif_name}: client_send '{client_send}' not found")
                        errors += 1

        print()
        if errors == 0:
            print_ok(f"All {found} notification implementations found")

        return errors, found

    def show_deprecated_types(self):
        """Display deprecated types from the manifest."""
        manifest_deprecated = self.manifest.get("deprecated", [])

        if not manifest_deprecated:
            return

        print_header("DEPRECATED IN SPEC")
        print_dim("These types are marked deprecated and filtered from verification:")
        print()
        for entry in manifest_deprecated:
            name = entry.get("name", "Unknown")
            replacement = entry.get("replacement", "")
            notes = entry.get("notes", "")
            print(f"  {DIM}○{NC} {name}")
            if replacement:
                print(f"    {DIM}Replacement: {replacement}{NC}")
            if notes:
                print(f"    {DIM}{notes}{NC}")
        print()

    def show_not_implemented(self):
        """Display not-yet-implemented items."""
        print_header("NOT YET IMPLEMENTED")

        if self.not_impl_files:
            print_dim("Files (planned for future implementation):")
            for f in sorted(self.not_impl_files):
                print(f"  {DIM}○{NC} {f}")
            print()

        if self.not_impl_types:
            print_dim("Types (planned for future implementation):")
            for t in sorted(self.not_impl_types):
                print(f"  {DIM}○{NC} {t}")
            print()

        if not self.not_impl_files and not self.not_impl_types:
            print_ok("All features are implemented!")
            print()

    def print_summary(self, results: VerificationResults) -> int:
        """Print final summary."""
        print()
        print("=" * 50)
        print("SUMMARY")
        print("=" * 50)

        # Spec → Manifest (is everything documented?)
        print()
        print(f"{'Spec → Manifest':<36} {'Gaps':>6}")
        print(f"  {'Types':<34} {results.types_spec_manifest:>6}")
        print(f"  {'Methods':<34} {results.methods_spec_manifest:>6}")
        print(f"  {'Notifications':<34} {results.notifs_spec_manifest:>6}")
        print(f"  {'Enums':<34} {results.enums_spec_manifest:>6}")
        print(f"  {'Error codes':<34} {results.errors_spec_manifest:>6}")
        print(f"  {'Capabilities':<34} {results.caps_spec_manifest:>6}")

        # Manifest → Swift (does Swift code exist?)
        print()
        print(f"{'Manifest → Swift':<28} {'Found':>8} {'Missing':>6}")
        print(f"  {'Types':<26} {results.types_swift_found:>8} {results.types_swift_missing:>6}")
        print(f"  {'Methods':<26} {results.methods_swift_found:>8} {results.methods_swift_missing:>6}")
        print(f"  {'Notifications':<26} {results.notifs_swift_found:>8} {results.notifs_swift_missing:>6}")
        print(f"  {'Enums':<26} {results.enums_swift_found:>8} {results.enums_swift_missing:>6}")
        print(f"  {'Error codes':<26} {results.errors_swift_found:>8} {results.errors_swift_missing:>6}")
        print(f"  {'Capabilities':<26} {results.caps_swift_found:>8} {results.caps_swift_missing:>6}")

        # Other
        print()
        print(f"{'Other':<28}")
        if results.file_errors == 0:
            print(f"  {'Swift files':<26} all exist")
        else:
            print(f"  {'Swift files':<26} {results.file_errors} missing")
        print(f"  {'Not yet implemented':<26} {len(self.not_impl_files)} files, {len(self.not_impl_types)} types")
        print(f"  {'Builtin types':<26} {results.builtin_count} (skipped)")

        # Total
        spec_manifest_total = (results.types_spec_manifest + results.methods_spec_manifest +
                               results.notifs_spec_manifest + results.enums_spec_manifest +
                               results.errors_spec_manifest + results.caps_spec_manifest)
        manifest_swift_total = (results.types_swift_missing + results.methods_swift_missing +
                                results.notifs_swift_missing + results.enums_swift_missing +
                                results.errors_swift_missing + results.caps_swift_missing)
        total = results.file_errors + spec_manifest_total + manifest_swift_total

        print()
        print("-" * 50)
        if total == 0:
            print(f"{GREEN}✓ All verifications passed{NC}")
            return 0
        else:
            gaps_word = "gap" if total == 1 else "gaps"
            print(f"{RED}✗ {total} {gaps_word} requiring attention{NC}")
            return 1

    def run(self) -> int:
        self.load_manifest()

        print()
        print("=" * 46)
        print("MCP Swift SDK Verification")
        print(f"Protocol Version: {self.protocol_version}")
        print("=" * 46)

        self.extract_not_implemented()
        self.build_swift_type_index()

        results = VerificationResults()

        results.file_errors = self.validate_swift_files()

        spec_dir = self.clone_spec()
        spec_types = self.extract_spec_types(spec_dir)

        # Spec → Manifest: types
        results.types_spec_manifest = self.check_spec_to_manifest(spec_types)

        # Manifest → Swift: types
        types_missing, types_found, results.not_impl_count, results.builtin_count = \
            self.check_manifest_to_swift()
        results.types_swift_found = types_found
        results.types_swift_missing = types_missing

        # Spec → Manifest: methods and notifications
        results.methods_spec_manifest, results.notifs_spec_manifest = self.check_methods(spec_dir)

        # Manifest → Swift: methods
        methods_missing, methods_found = self.check_method_implementations()
        results.methods_swift_found = methods_found
        results.methods_swift_missing = methods_missing

        # Manifest → Swift: notifications
        notifs_missing, notifs_found = self.check_notification_implementations()
        results.notifs_swift_found = notifs_found
        results.notifs_swift_missing = notifs_missing

        # Enums: Spec → Manifest → Swift
        enum_spec_gaps, _, enum_swift_found, enum_swift_missing = self.check_enums(spec_dir)
        results.enums_spec_manifest = enum_spec_gaps
        results.enums_swift_found = enum_swift_found
        results.enums_swift_missing = enum_swift_missing

        # Error codes: Spec → Manifest → Swift
        error_spec_gaps, _, error_swift_found, error_swift_missing = self.check_error_codes(spec_dir)
        results.errors_spec_manifest = error_spec_gaps
        results.errors_swift_found = error_swift_found
        results.errors_swift_missing = error_swift_missing

        # Capabilities: Spec → Manifest → Swift
        cap_spec_gaps, _, cap_swift_found, cap_swift_missing = self.check_capabilities(spec_dir)
        results.caps_spec_manifest = cap_spec_gaps
        results.caps_swift_found = cap_swift_found
        results.caps_swift_missing = cap_swift_missing

        self.show_deprecated_types()
        self.show_not_implemented()

        return self.print_summary(results)


def main():
    parser = argparse.ArgumentParser(description="Verify MCP Swift SDK protocol coverage")
    parser.add_argument("--skip-clone", action="store_true",
                        help="Use cached spec instead of cloning fresh")
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    verifier = Verifier(script_dir, skip_clone=args.skip_clone)

    try:
        sys.exit(verifier.run())
    finally:
        if verifier.temp_dir and verifier.temp_dir.exists():
            shutil.rmtree(verifier.temp_dir)


if __name__ == "__main__":
    main()
