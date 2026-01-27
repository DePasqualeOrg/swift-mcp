# Transports

Choose and configure the right transport for your MCP client or server

## Overview

MCP's transport layer handles communication between clients and servers. The Swift SDK provides multiple built-in transports for different use cases.

## Available Transports

| Transport             | Description                     | Use Case                        |
| --------------------- | ------------------------------- | ------------------------------- |
| `StdioTransport`      | Standard input/output streams   | Local subprocesses, CLI tools   |
| `HTTPClientTransport` | HTTP client with SSE streaming  | Connect to remote servers       |
| `HTTPServerTransport` | HTTP server for hosting         | Host servers over HTTP          |
| `InMemoryTransport`   | Direct in-process communication | Testing, same-process scenarios |
| `NetworkTransport`    | Apple Network framework         | Custom TCP/UDP protocols        |

## StdioTransport

Implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio) using standard input/output streams. Best for local subprocess communication.

**Platforms:** Apple platforms, Linux with glibc

```swift
import MCP

// For clients
let clientTransport = StdioTransport()
try await client.connect(transport: clientTransport)

// For servers
let serverTransport = StdioTransport()
try await server.start(transport: serverTransport)
```

## HTTPClientTransport

Implements the [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http) for connecting to remote MCP servers.

**Platforms:** All platforms with Foundation

### Basic Usage

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!
)
try await client.connect(transport: transport)
```

### With Streaming

Enable Server-Sent Events for real-time notifications:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    streaming: true
)
```

### Session Management

The transport automatically handles session IDs and protocol version headers:

```swift
// Session ID is managed automatically after initialization
// Protocol version header (Mcp-Protocol-Version) is sent with requests
```

### Event Stream Status

When streaming is enabled, the transport monitors the SSE event stream independently of request/response communication. The ``EventStreamStatus`` enum reports the stream's health:

- ``EventStreamStatus/connected``: The event stream is connected and receiving events.
- ``EventStreamStatus/reconnecting``: The event stream has disconnected and the transport is retrying.
- ``EventStreamStatus/failed``: The transport has exhausted all reconnection attempts for the event stream.

Event stream disruptions don't prevent POST-based requests (like tool calls) from succeeding — the two channels are independent.

### Using MCPClient

``MCPClient`` wraps any transport with automatic reconnection, health monitoring, and transparent retry on recoverable errors. When used with ``HTTPClientTransport``, it additionally hooks into session expiration and event stream status callbacks. See <doc:client-setup> for details.

## HTTPServerTransport

Host MCP servers over HTTP. Integrates with any HTTP framework (Hummingbird, Vapor, etc.).

**Platforms:** All platforms with Foundation

### DNS Rebinding Protection

DNS rebinding is an attack where malicious websites bypass browser same-origin policy to access local servers. This is a threat for MCP servers running on user machines.

#### Local Development, Servers on User Machines

Protection is enabled by default. The default settings protect localhost-bound servers:

```swift
// Default: DNS rebinding protection enabled for localhost
let transport = HTTPServerTransport(
    options: .init(sessionIdGenerator: { UUID().uuidString })
)

// Or use forBindAddress for explicit configuration
let transport = HTTPServerTransport(
    options: .forBindAddress(
        host: "localhost",
        port: 8080,
        sessionIdGenerator: { UUID().uuidString }
    )
)
```

#### Cloud Deployments

For cloud deployments, DNS rebinding is not a threat, since there's no local browser to exploit. Use `.none`:

```swift
let transport = HTTPServerTransport(
    options: .init(
        sessionIdGenerator: { UUID().uuidString },
        dnsRebindingProtection: .none  // Cloud deployment
    )
)

// Or use forBindAddress with 0.0.0.0 (auto-detects cloud deployment)
let transport = HTTPServerTransport(
    options: .forBindAddress(
        host: "0.0.0.0",
        port: 8080,
        sessionIdGenerator: { UUID().uuidString }
    )
)
```

#### Custom Host Validation

For specific requirements like known proxy hosts:

```swift
let transport = HTTPServerTransport(
    options: .init(
        sessionIdGenerator: { UUID().uuidString },
        dnsRebindingProtection: .custom(
            allowedHosts: ["api.example.com:443"],
            allowedOrigins: ["https://app.example.com"]
        )
    )
)
```

See `DNSRebindingProtection` for full documentation.

### Stateful Mode

Track sessions with unique IDs:

```swift
let transport = HTTPServerTransport(
    options: .init(
        sessionIdGenerator: { UUID().uuidString },
        onSessionInitialized: { sessionId in
            print("Session started: \(sessionId)")
            await sessionManager.store(transport, forSessionId: sessionId)
        },
        onSessionClosed: { sessionId in
            print("Session ended: \(sessionId)")
            await sessionManager.remove(sessionId)
        }
    )
)
```

### Stateless Mode

For simpler deployments without session tracking:

```swift
let transport = HTTPServerTransport()  // No session management
```

### Handling HTTP Requests

Route incoming requests to the transport:

```swift
// In your HTTP framework's handler
func handleMCPRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
    return try await transport.handleRequest(request)
}
```

#### Host Header Handling

DNS rebinding protection validates the `Host` header. When converting requests from your HTTP framework to `MCP.HTTPRequest`, ensure the Host header is included.

**Vapor (NIOHTTP1):** Headers include Host automatically when iterating:

```swift
func extractHeaders(from req: Vapor.Request) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in req.headers {
        headers[name] = value  // Host is included
    }
    return headers
}
```

**Hummingbird (HTTPTypes):** Host is stored separately in `authority`:

```swift
func extractHeaders(from request: Hummingbird.Request) -> [String: String] {
    var headers: [String: String] = [:]
    for field in request.headers {
        headers[field.name.rawName] = field.value
    }
    // HTTPTypes stores Host in authority (HTTP/2 :authority pseudo-header)
    if let authority = request.head.authority {
        headers["Host"] = authority
    }
    return headers
}
```

See the [integration examples](https://github.com/DePasqualeOrg/swift-mcp/tree/main/Examples) for complete examples.

## BasicHTTPSessionManager

For simple demos and testing, `BasicHTTPSessionManager` handles session lifecycle automatically:

```swift
let mcpServer = MCPServer(name: "my-server", version: "1.0.0")
try await mcpServer.register { Echo.self }

let sessionManager = BasicHTTPSessionManager(server: mcpServer, port: 8080)

// In your HTTP route:
let response = await sessionManager.handleRequest(httpRequest)
```

See `BasicHTTPSessionManager` for limitations and when to implement custom session management.

## SessionManager

Lower-level thread-safe session storage for custom HTTP server implementations:

```swift
let sessionManager = SessionManager(maxSessions: 100)

// Store a transport
await sessionManager.store(transport, forSessionId: sessionId)

// Retrieve a transport
if let transport = await sessionManager.transport(forSessionId: sessionId) {
    // Handle request
}

// Clean up stale sessions
await sessionManager.cleanUpStaleSessions(olderThan: .seconds(3600))

// Remove a session
await sessionManager.remove(sessionId)
```

## InMemoryTransport

Direct communication within the same process. Useful for testing and embedded scenarios.

**Platforms:** All platforms

```swift
// Create a connected pair of transports
let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

// Use them for client and server
try await server.start(transport: serverTransport)
try await client.connect(transport: clientTransport)
```

## NetworkTransport

Low-level transport using Apple's Network framework for TCP/UDP connections.

**Platforms:** Apple platforms only

```swift
import Network

// Create a TCP connection to a server
let connection = NWConnection(
    host: NWEndpoint.Host("localhost"),
    port: NWEndpoint.Port(8080)!,
    using: .tcp
)

// Initialize the transport with the connection
let transport = NetworkTransport(connection: connection)
```

## Custom Transport Implementation

Implement the `Transport` protocol for custom transports:

```swift
public actor MyCustomTransport: Transport {
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<TransportMessage, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<TransportMessage, Swift.Error>.Continuation

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "my.transport")

        let (stream, continuation) = AsyncThrowingStream<TransportMessage, Swift.Error>.makeStream()
        self.messageStream = stream
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        // Establish connection
        isConnected = true
    }

    public func disconnect() async {
        // Clean up
        isConnected = false
        messageContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        // Send data to the remote endpoint
    }

    public func receive() -> AsyncThrowingStream<TransportMessage, Swift.Error> {
        return messageStream
    }

    // To yield incoming messages:
    // messageContinuation.yield(TransportMessage(data: incomingData))
}
```

## Platform Availability

| Transport           | macOS | iOS   | watchOS | tvOS  | visionOS | Linux      |
| ------------------- | ----- | ----- | ------- | ----- | -------- | ---------- |
| StdioTransport      | 13.0+ | 16.0+ | 9.0+    | 16.0+ | 1.0+     | glibc/musl |
| HTTPClientTransport | 13.0+ | 16.0+ | 9.0+    | 16.0+ | 1.0+     | ✓          |
| HTTPServerTransport | 13.0+ | 16.0+ | 9.0+    | 16.0+ | 1.0+     | ✓          |
| InMemoryTransport   | 13.0+ | 16.0+ | 9.0+    | 16.0+ | 1.0+     | ✓          |
| NetworkTransport    | 13.0+ | 16.0+ | 9.0+    | 16.0+ | 1.0+     | ✗          |

## See Also

- <doc:client-setup>
- <doc:server-setup>
