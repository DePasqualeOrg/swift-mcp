# ``MCPPrompt``

Macros and property wrappers for defining MCP prompts.

## Overview

Import `MCPPrompt` alongside `MCP` when you need the `@Prompt` and `@Argument` macros to declare prompts as Swift types. The module is kept separate from `MCP` so the `@Prompt` name doesn't collide with other frameworks that define their own `@Prompt` attribute.

For the full SDK – clients, servers, and transports – see the [`MCP`](/documentation/mcp) module.
