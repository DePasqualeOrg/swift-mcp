# Cross-Reference Verification Agent Instructions

This document describes how coding agents should verify and correct the Swift MCP SDK against the authoritative MCP specification and reference implementations.

## Overview

Verification has **two dimensions**:

1. **Spec Adherence**: Does the Swift SDK correctly implement the MCP protocol?
2. **Code Quality**: Is the implementation well-designed, secure, and idiomatic?

Both must be checked. An implementation can match the spec perfectly but still have architectural issues, security vulnerabilities, or Swift anti-patterns.

The `manifest.yaml` manifest uses a **module-centric** structure where:
- **Modules** group related methods, notifications, and types
- **Types** are defined once in a dedicated section (single source of truth)
- Each item has a `verification` block with `status` and `notes` fields
- Unimplemented items have `implementation: todo` or `implementation: skip` instead of a verification block

Agents systematically verify each module, auto-fix obvious issues, and flag ambiguous cases for human review.

## Repository Locations

The validation scripts clone fresh copies from GitHub automatically:

```
Spec:       https://github.com/modelcontextprotocol/modelcontextprotocol
TypeScript: https://github.com/modelcontextprotocol/typescript-sdk
Python:     https://github.com/modelcontextprotocol/python-sdk
Swift:      . (this repository)
```

## Cross-Referencing Other SDKs

When verifying Swift implementations, compare with TypeScript and Python SDKs:

### Types

Type names match the spec. Look in:
- **TypeScript**: `packages/core/src/types/types.ts`
- **Python**: `src/mcp/types.py`

### Method Implementations

Search for the request type name:
- **TypeScript**: `packages/server/src/server/mcp.ts` (all methods in one file)
- **Python**:
  - Low-level: `src/mcp/server/lowlevel/server.py`
  - High-level: `src/mcp/server/fastmcp/server.py`

## Manifest Structure

Two main sections: `modules` (methods, notifications, type references) and `types` (type definitions with Swift mappings).

Each item has `verification: {status, notes}` or `implementation: todo|skip` if not yet implemented.

## Verification Workflow

### 1. Select a Module

Pick the next module with `status: pending` from the manifest.

### 2. Gather Sources

- Swift: `{swift_file}` from manifest
- Spec docs: `docs/specification/2025-11-25/{category}/{id}.mdx`
- Spec schema: `schema/2025-11-25/schema.ts`
- TypeScript/Python: see "Cross-Referencing Other SDKs" above

### Understanding Swift ↔ Spec Name Mappings

Swift uses nested types (e.g., `Resource.Contents`) where the spec uses flat names (e.g., `ResourceContents`).

#### Default Convention (Implicit)

Flatten Swift names by removing dots:
- `Resource.Template` → `ResourceTemplate` ✓
- `Prompt.Argument` → `PromptArgument` ✓
- `Initialize.Result` → `InitializeResult` ✓

#### Exceptions (Explicit via `spec_name`)

When a type name doesn't follow the convention, the entry includes a `spec_name` field:

```yaml
types:
  Task:
    swift: MCPTask
    file: Sources/MCP/Server/Tasks.swift
    spec_name: Task
    status: pending
    notes: "Swift prefix avoids collision with Swift.Task"
```

Common exception patterns:
- **Prefix for collision avoidance**: `MCPError` → `Error`, `MCPTask` → `Task`
- **Different name entirely**: `Client.Info` → `Implementation`

### 3. Verify Methods and Notifications

For each method/notification in the module:

1. Check the `swift` field matches an actual type in the Swift file
2. Verify the type conforms to the `Method` or `Notification` protocol
3. Check `Parameters` and `Result` nested types (for methods)
4. Compare against spec schema

### 4. Verify Types

For each type referenced by the module:

1. Look up the type in the `types` section
2. Verify the Swift type exists at the specified file location
3. Compare properties against spec schema
4. Check Codable conformance (JSON keys match spec)

### 5. Compare and Verify

Check spec adherence: properties match spec (names, types, optionality, defaults), JSON keys match exactly, method parameters and responses match, error handling follows spec.

## Status Values

Use these status values for modules, methods, notifications, and types:

| Status | Description |
|--------|-------------|
| `pending` | Not yet verified |
| `in_progress` | Agent currently checking |
| `correct` | Verified correct, no changes needed |
| `fixed` | Verified after making corrections |
| `info` | Verified, notable observation (use sparingly) |
| `warning` | Potential issue, should review |
| `critical` | Definite problem, must fix |

### 6. Take Action

Based on findings, update the item's status and notes:

#### If Everything Matches

Leave notes empty for anything that's already correct. Notes should only be used for important information that the user needs to be made aware of.

```yaml
status: correct
notes: "" 
```

#### If Obvious Fix Needed
Apply the fix, then:
```yaml
status: fixed
notes: "Added missing `title` property"
```

#### If Notable Observation (Only If Important)
```yaml
status: info
notes: "Swift uses AnyHashable for meta field; spec allows any JSON object"
```

#### If Potential Issue
```yaml
status: warning
notes: |
  Property `timeout` uses Int but spec uses number (float).

  Options:
  1. Change to Double - matches spec exactly
  2. Keep Int - timeouts are typically whole seconds

  Recommendation: Option 2 - practical for this use case
```

#### If Definite Problem
```yaml
status: critical
notes: |
  Missing required `name` property on Tool type.

  Options:
  1. Add `name: String` property
  2. Rename existing `id` property to `name`

  Recommendation: Option 1 - `id` may be used elsewhere
```

## Auto-Fix Guidelines

**Do auto-fix:**
- Missing properties (add them)
- Wrong CodingKeys (fix the key)
- Missing Codable conformance
- Obvious type mismatches (e.g., `Int` should be `String`)
- Missing enum cases

**Don't auto-fix (flag for review):**
- Behavior changes that might break existing code
- Ambiguous nullability semantics
- Changes to public API signatures
- Anything affecting tests
- Structural refactoring
