# MCP Swift SDK Verification System

Automated verification of protocol coverage between the MCP specification and Swift SDK implementation.

## Overview

The verification system ensures the Swift SDK correctly implements all aspects of the MCP protocol specification. It uses a two-stage pipeline:

```
┌─────────────┐                          ┌──────────────┐                          ┌─────────────┐
│  MCP Spec   │  ──── sync-manifest ───► │   Manifest   │  ──── verify-protocol ─► │   Swift     │
│  (schema)   │       (completeness)     │   (YAML)     │       (implementation)   │   (code)    │
└─────────────┘                          └──────────────┘                          └─────────────┘
```

1. **Sync**: Ensures all spec items are documented in the manifest
2. **Verify**: Ensures all manifest items have Swift implementations

## Scripts

### `sync-manifest.py`

Syncs the manifest with the MCP specification schema. Detects new items in the spec and adds them to the manifest with placeholder values.

```bash
# Show what would be added (dry run)
uv run scripts/sync-manifest.py --dry-run

# Apply changes to manifest
uv run scripts/sync-manifest.py
```

### `verify-protocol-coverage.py`

Verifies that all manifest items have corresponding Swift implementations.

```bash
# Run verification (clones fresh spec)
uv run scripts/verify-protocol-coverage.py

# Use cached spec (faster iteration)
uv run scripts/verify-protocol-coverage.py --skip-clone
```

## Categories Tracked

| Category | Description | Sync | Verify |
|----------|-------------|------|--------|
| **Types** | Public type definitions (structs, enums, protocols) | ✓ | Spec→Manifest→Swift |
| **Methods** | RPC methods (initialize, ping, resources/list, etc.) | ✓ | Spec→Manifest→Swift |
| **Notifications** | Event notifications (progress, cancelled, etc.) | ✓ | Spec→Manifest→Swift |
| **Enums** | Enumeration types with case values | ✓ | Spec→Manifest→Swift |
| **Error Codes** | JSON-RPC and MCP-specific error codes | ✓ | Spec→Manifest→Swift |
| **Capabilities** | Client and server capability properties | ✓ | Spec→Manifest→Swift |
| **Deprecated** | Types marked deprecated in spec | ✓ | Informational |

## Manifest Structure

The manifest (`manifest.yaml`) is the central source of truth for tracking:

```yaml
# Protocol version being implemented
target_protocol_version: "2025-11-25"

# Modules group related methods and notifications
modules:
  - id: resources
    methods:
      - name: resources/list
        client_method: listResources    # Swift method on Client
        server_method: listResources    # Swift method on Server
    notifications:
      - name: notifications/resources/list_changed
        server_send: sendResourceListChanged

# Type mappings from spec to Swift
types:
  Resource:
    swift: Resource
    file: Sources/MCP/Server/Resources.swift

# Enum definitions with case mappings
enums:
  - name: LoggingLevel
    swift: LoggingLevel
    cases:
      - spec: debug
        swift: debug

# Error code definitions
error_codes:
  - name: PARSE_ERROR
    code: -32700
    swift: parseError

# Capability property mappings
capabilities:
  client:
    - property: sampling
      swift: sampling
  server:
    - property: tools
      swift: tools
      nested:
        - name: listChanged
          swift: listChanged
```

## Verification Flow

### 1. Type Verification

```
Spec $defs → Manifest types → Swift types exist
```

- Extracts public types from spec (filters out Request/Response/etc.)
- Checks each is documented in manifest
- Verifies Swift type exists in codebase

### 2. Method Verification

```
Spec methods → Manifest modules.methods → Swift func exists
```

- Extracts methods from ClientRequest/ServerRequest unions
- Checks each has manifest entry with implementation details
- Verifies Swift methods exist (client_method, server_method, client_handler)

### 3. Notification Verification

```
Spec notifications → Manifest modules.notifications → Swift send methods
```

- Extracts from ClientNotification/ServerNotification unions
- Checks server_send and client_send methods exist

### 4. Enum Verification

```
Spec enum values → Manifest enum cases → Swift enum cases match
```

- Extracts enums with their case values
- Compares spec cases against Swift enum cases
- Reports missing or extra cases

### 5. Error Code Verification

```
Spec error constants → Manifest error_codes → Swift MCPError codes
```

- Extracts from schema.ts (PARSE_ERROR, INVALID_REQUEST, etc.)
- Verifies Swift error enum returns correct codes

### 6. Capability Verification

```
Spec capability properties → Manifest capabilities → Swift struct properties
```

- Extracts ClientCapabilities and ServerCapabilities properties
- Verifies nested properties (e.g., roots.listChanged)

## Workflow

### When the spec updates

1. Run sync to detect new items:
   ```bash
   uv run scripts/sync-manifest.py --dry-run
   ```

2. Review changes and apply:
   ```bash
   uv run scripts/sync-manifest.py
   ```

   The sync script automatically discovers matching Swift types using AST analysis.
   Types that can't be matched get `TODO_` placeholders.

3. For any `TODO_` placeholders, manually add Swift mappings

4. Implement missing Swift code

5. Run verification to confirm:
   ```bash
   uv run scripts/verify-protocol-coverage.py
   ```

### When implementing features

1. Check current gaps:
   ```bash
   uv run scripts/verify-protocol-coverage.py --skip-clone
   ```

2. Implement Swift code for missing items

3. Update manifest verification status and notes

4. Re-run verification to confirm

## Output Interpretation

The verification script outputs a summary:

```
SUMMARY
==================================================

Schema Coverage                Gaps
  Files                           0    # All referenced Swift files exist
  Spec → Manifest                 0    # All spec items in manifest
  Manifest → Swift                0    # All manifest types in Swift
  Methods                         0    # All spec methods documented

Implementations         Found    Missing
  Methods                  10         18    # Swift method implementations
  Notifications            12          2    # Swift send methods

Value Checks           Verified     Gaps
  Enums                       3        0    # Enum cases match
  Error codes                 6        0    # Error codes correct
  Capabilities               10        2    # Capability properties exist
```

- **Gaps = 0**: Fully implemented
- **Gaps > 0**: Items need implementation or manifest updates

## Files

```
verification/
├── README.md                           # This document
├── manifest.yaml                       # Central tracking manifest
└── scripts/
    ├── sync-manifest.py                # Entry point: Spec → Manifest sync
    ├── verify-protocol-coverage.py     # Entry point: Manifest → Swift verification
    ├── lib/                            # Shared modules
    │   ├── spec_extraction.py          # Extract data from MCP spec
    │   └── output.py                   # Terminal output formatting
    ├── utils/                          # Utility scripts
    │   ├── format-manifest.py          # Reformat manifest.yaml
    │   ├── reset-verification.py       # Reset all verification statuses
    │   └── show-issues.py              # Display verification issues
    └── extractors/                     # Type extraction tools
        ├── swift/                      # AST-based Swift type extractor (Swift package)
        ├── python.py                   # Extract Python SDK types
        └── typescript.js               # Extract TypeScript SDK types
```

## Architecture

The scripts share common code through the `lib/` module:

- **`lib/spec_extraction.py`**: Functions to extract data from the MCP specification schema (types, enums, error codes, capabilities, deprecated items)
- **`lib/output.py`**: Terminal output formatting (colors, headers, status messages)

This eliminates code duplication and ensures both scripts use identical extraction logic.

### Swift Type Discovery

The sync script uses programmatic type discovery to automatically match spec types to Swift types:

1. **Extract Swift types** from the codebase using `extract-swift-types` (AST-based)
2. **Build reverse mapping** from possible spec names to Swift names:
   - Exact match: `Resource` → `Resource`
   - Flattened nested: `Resource.Template` → `ResourceTemplate`
   - JSONRPC prefix: `Message` → `JSONRPCMessage`
   - MCP prefix: `MCPError` → `Error`
3. **Match spec types** to discovered Swift types

This approach avoids hardcoded mappings and automatically discovers new types when Swift code is added.
