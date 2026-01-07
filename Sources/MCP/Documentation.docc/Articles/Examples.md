# Examples

Integration examples for building HTTP-based MCP servers.

## Overview

The SDK includes complete examples showing how to build HTTP-based MCP servers with popular Swift web frameworks. Both examples follow the same architecture pattern from the TypeScript SDK.

## Architecture Pattern

```
                    ┌─────────────────────────────┐
                    │     MCP Server (shared)     │
                    │   - Tool handlers           │
                    │   - Resource handlers       │
                    └─────────────┬───────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│  Transport A  │       │  Transport B  │       │  Transport C  │
│  (session-1)  │       │  (session-2)  │       │  (session-3)  │
└───────┬───────┘       └───────┬───────┘       └───────┬───────┘
        │                       │                       │
        ▼                       ▼                       ▼
    Client A                Client B                Client C
```

Key principles:
- **One Server instance** is shared across all HTTP clients
- **Each client session** gets its own ``HTTPServerTransport``
- **SessionManager** tracks active transports by session ID

## HTTP Endpoints

Both examples implement these standard MCP HTTP endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp` | POST | JSON-RPC requests (initialize, tools/call, etc.) |
| `/mcp` | GET | Server-Sent Events stream for notifications |
| `/mcp` | DELETE | Terminate a session |
| `/health` | GET | Health check |

## Hummingbird Integration

Integration with [Hummingbird](https://github.com/hummingbird-project/hummingbird), a lightweight Swift web framework.

```bash
cd Examples/HummingbirdIntegration
swift run
# Server starts on http://localhost:3000/mcp
```

### Key Code

```swift
import Hummingbird
import MCP

// Create shared MCP server
let mcpServer = Server(
    name: "HummingbirdMCPServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

// Register handlers
await mcpServer.withRequestHandler(ListTools.self) { _ in
    .init(tools: [Tool(name: "echo", description: "Echo a message", inputSchema: [...])])
}

// Create session manager
let sessionManager = SessionManager(maxSessions: 100)

// Configure Hummingbird routes
let router = Router()
router.post("/mcp") { request, context in
    // Get or create transport for session
    let transport = try await getOrCreateTransport(request, sessionManager, mcpServer)
    return try await transport.handleRequest(request.asHTTPRequest())
}

// Run the server
let app = Application(router: router)
try await app.runService()
```

## Vapor Integration

Integration with [Vapor](https://vapor.codes/), a popular full-featured Swift web framework.

```bash
cd Examples/VaporIntegration
swift run
# Server starts on http://localhost:8080/mcp
```

### Key Code

```swift
import Vapor
import MCP

// Create shared MCP server
let mcpServer = Server(
    name: "VaporMCPServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

// Create session manager
let sessionManager = SessionManager(maxSessions: 100)

// Configure Vapor routes
app.post("mcp") { req async throws -> Response in
    let transport = try await getOrCreateTransport(req, sessionManager, mcpServer)
    let response = try await transport.handleRequest(req.asHTTPRequest())
    return response.asVaporResponse()
}
```

## Creating a New Transport

For each session, create a transport with session callbacks:

```swift
func createTransport(sessionManager: SessionManager, server: Server) async -> HTTPServerTransport {
    let transport = HTTPServerTransport(
        options: .init(
            sessionIdGenerator: { UUID().uuidString },
            onSessionInitialized: { sessionId in
                await sessionManager.store(transport, forSessionId: sessionId)
            },
            onSessionClosed: { sessionId in
                await sessionManager.remove(sessionId)
            }
        )
    )

    // Start the server with this transport
    try await server.start(transport: transport)

    return transport
}
```

## Testing with curl

### Initialize a Session

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "id": "1",
    "params": {
      "protocolVersion": "2025-11-25",
      "capabilities": {},
      "clientInfo": {"name": "curl-test", "version": "1.0"}
    }
  }'
```

Save the `Mcp-Session-Id` header from the response.

### List Tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": "2"}'
```

### Call a Tool

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": "3",
    "params": {"name": "echo", "arguments": {"message": "Hello!"}}
  }'
```

### Terminate Session

```bash
curl -X DELETE http://localhost:3000/mcp \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -H "Mcp-Protocol-Version: 2025-11-25"
```

## Stateless Mode

For simpler deployments without session persistence:

```swift
let transport = HTTPServerTransport()  // No session tracking
```

In stateless mode:
- No `Mcp-Session-Id` header is returned or required
- Each request is independent
- Server-initiated notifications are not supported

## Production Considerations

1. **Session cleanup**: Implement periodic cleanup of stale sessions
   ```swift
   await sessionManager.cleanupStaleSessions(olderThan: .seconds(3600))
   ```

2. **Connection limits**: Set `maxSessions` to prevent resource exhaustion
   ```swift
   let sessionManager = SessionManager(maxSessions: 1000)
   ```

3. **Load balancing**: Use sticky sessions or shared session storage

4. **TLS**: Always use HTTPS in production

5. **Authentication**: Add authentication middleware as needed

## See Also

- <doc:Transports>
- <doc:ServerGuide>
- ``HTTPServerTransport``
- ``SessionManager``
