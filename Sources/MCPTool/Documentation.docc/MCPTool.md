# ``MCPTool``

Macros and property wrappers for defining MCP tools.

## Overview

Import `MCPTool` alongside `MCP` when you need the `@Tool` and `@Parameter` macros to declare tools as Swift types. The module is kept separate from `MCP` so the `@Tool` name doesn't collide with other frameworks – AI agent libraries, for instance – that define their own `@Tool` attribute.

For the full SDK – clients, servers, and transports – see the [`MCP`](/documentation/mcp) module.
