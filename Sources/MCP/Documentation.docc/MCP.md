# ``MCP``

Swift SDK for the Model Context Protocol (MCP).

## Overview

The Model Context Protocol defines a standardized way for applications to communicate with AI and ML models. This Swift SDK implements both client and server components according to the [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/) version of the MCP specification.

Use the SDK to:
- **Build MCP clients** that connect to servers and access tools, resources, and prompts
- **Build MCP servers** that expose capabilities to AI applications
- **Choose from multiple transports** including stdio, HTTP, and custom implementations

## Requirements

- Swift 6.0+ (Xcode 16+)
- See <doc:GettingStarted> for platform-specific requirements

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ClientGuide>
- <doc:ServerGuide>

### Client

- ``Client``

### Server

- ``Server``

### Transports

- <doc:Transports>
- ``Transport``
- ``StdioTransport``
- ``HTTPClientTransport``
- ``HTTPServerTransport``
- ``InMemoryTransport``
- ``NetworkTransport``

### Tools

- ``Tool``
- ``ListTools``
- ``CallTool``

### Resources

- ``Resource``
- ``ListResources``
- ``ReadResource``
- ``ResourceSubscribe``
- ``ResourceUnsubscribe``

### Prompts

- ``Prompt``
- ``ListPrompts``
- ``GetPrompt``

### Sampling

- ``CreateSamplingMessage``
- ``SamplingMessage``

### Elicitation

- ``Elicit``
- ``ElicitationSchema``
- ``ElicitResult``

### Completions

- ``Complete``
- ``CompletionReference``

### Progress and Notifications

- ``ProgressNotification``
- ``ProgressToken``
- ``RequestMeta``

### Protocol

- ``Version``
- ``MCPError``
- ``ErrorCode``

### Additional Guides

- <doc:Examples>
- <doc:Experimental>
- <doc:Debugging>
