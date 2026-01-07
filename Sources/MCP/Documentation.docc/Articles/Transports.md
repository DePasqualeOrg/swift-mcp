# Transports

Choose and configure the right transport for your MCP client or server.

## Overview

MCP's transport layer handles communication between clients and servers. The Swift SDK provides multiple built-in transports for different use cases.

## Available Transports

| Transport | Description | Use Case |
|-----------|-------------|----------|
| ``StdioTransport`` | Standard input/output streams | Local subprocesses, CLI tools |
| ``HTTPClientTransport`` | HTTP client with SSE streaming | Connect to remote servers |
| ``HTTPServerTransport`` | HTTP server for hosting | Host servers over HTTP |
| ``InMemoryTransport`` | Direct in-process communication | Testing, same-process scenarios |
| ``NetworkTransport`` | Apple Network framework | Custom TCP/UDP protocols |

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

## HTTPServerTransport

Host MCP servers over HTTP. Integrates with any HTTP framework (Hummingbird, Vapor, etc.).

**Platforms:** All platforms with Foundation

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

See <doc:Examples> for complete integration examples.

## SessionManager

Thread-safe session storage for HTTP servers:

```swift
let sessionManager = SessionManager(maxSessions: 100)

// Store a transport
await sessionManager.store(transport, forSessionId: sessionId)

// Retrieve a transport
if let transport = await sessionManager.transport(forSessionId: sessionId) {
    // Handle request
}

// Clean up stale sessions
await sessionManager.cleanupStaleSessions(olderThan: .seconds(3600))

// Remove a session
await sessionManager.remove(sessionId)
```

## InMemoryTransport

Direct communication within the same process. Useful for testing and embedded scenarios.

**Platforms:** All platforms

```swift
// Create a linked pair of transports
let (clientTransport, serverTransport) = InMemoryTransport.createLinkedPair()

// Use them for client and server
try await server.start(transport: serverTransport)
try await client.connect(transport: clientTransport)
```

## NetworkTransport

Low-level transport using Apple's Network framework for TCP/UDP connections.

**Platforms:** Apple platforms only

```swift
import Network

let transport = NetworkTransport(
    host: "localhost",
    port: 8080,
    using: .tcp
)
```

## Custom Transport Implementation

Implement the ``Transport`` protocol for custom transports:

```swift
public actor MyCustomTransport: Transport {
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "my.transport")

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
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

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return messageStream
    }
}
```

## OAuth Support

The SDK includes foundational types for OAuth 2.0 authentication:

### OAuthTokens

```swift
let tokens = OAuthTokens(
    accessToken: "access_token_here",
    tokenType: "Bearer",
    expiresIn: 3600,
    refreshToken: "refresh_token_here"
)
```

### UnauthorizedContext

Handle 401 responses:

```swift
let context = UnauthorizedContext(
    resourceMetadataURL: URL(string: "https://api.example.com/.well-known/oauth"),
    scope: "read write",
    wwwAuthenticate: headerValue
)
```

> Note: Full OAuth flow implementation (discovery, PKCE, token exchange) is planned for a future release.

## Platform Availability

| Transport | macOS | iOS | watchOS | tvOS | visionOS | Linux |
|-----------|-------|-----|---------|------|----------|-------|
| StdioTransport | 13.0+ | 16.0+ | 9.0+ | 16.0+ | 1.0+ | glibc/musl |
| HTTPClientTransport | 13.0+ | 16.0+ | 9.0+ | 16.0+ | 1.0+ | ✓ |
| HTTPServerTransport | 13.0+ | 16.0+ | 9.0+ | 16.0+ | 1.0+ | ✓ |
| InMemoryTransport | 13.0+ | 16.0+ | 9.0+ | 16.0+ | 1.0+ | ✓ |
| NetworkTransport | 13.0+ | 16.0+ | 9.0+ | 16.0+ | 1.0+ | ✗ |

## See Also

- <doc:Examples>
- <doc:ClientGuide>
- <doc:ServerGuide>
