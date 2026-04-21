# ``MCPCore``

Shared contract types for the MCP protocol – the base message types, schema validation, and the `@StructuredOutput` macro.

## Overview

`MCPCore` is the types-only layer that `MCP` re-exports. Consumers that only need the contract types (for example, defining tool result structs with `@Schemable @StructuredOutput`) can depend on `MCPCore` directly and skip the client, server, and transport runtime.

For the full SDK – clients, servers, and transports – see the [`MCP`](/documentation/mcp) module.
