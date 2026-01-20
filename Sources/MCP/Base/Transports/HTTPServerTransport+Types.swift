import Foundation

// Types extracted from HTTPServerTransport.swift
// - AuthInfo
// - Options
// - SecuritySettings
// - EventStore protocol
// - HTTPRequest
// - HTTPResponse

// MARK: - Authentication

/// Information about a validated access token.
///
/// This struct contains authentication context that can be provided to request handlers
/// when using HTTP transports with OAuth or other token-based authentication.
///
/// Matches the TypeScript SDK's `AuthInfo` interface.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     if let authInfo = context.authInfo {
///         print("Authenticated as: \(authInfo.clientId)")
///         print("Scopes: \(authInfo.scopes)")
///     }
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct AuthInfo: Hashable, Codable, Sendable {
    /// The access token string.
    public let token: String

    /// The client ID associated with this token.
    public let clientId: String

    /// Scopes associated with this token.
    public let scopes: [String]

    /// When the token expires (in seconds since epoch).
    ///
    /// If `nil`, the token does not expire or expiration is unknown.
    public let expiresAt: Int?

    /// The RFC 8707 resource server identifier for which this token is valid.
    ///
    /// If set, this should match the MCP server's resource identifier (minus hash fragment).
    public let resource: String?

    /// Additional data associated with the token.
    ///
    /// Use this for any additional data that needs to be attached to the auth info.
    public let extra: [String: Value]?

    public init(
        token: String,
        clientId: String,
        scopes: [String],
        expiresAt: Int? = nil,
        resource: String? = nil,
        extra: [String: Value]? = nil
    ) {
        self.token = token
        self.clientId = clientId
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.resource = resource
        self.extra = extra
    }
}

extension AuthInfo: CustomStringConvertible {
    /// Redacts the token to prevent accidental exposure in logs.
    ///
    /// The token is still accessible via the `token` property for legitimate use,
    /// but this prevents it from appearing in string interpolation or print statements.
    public var description: String {
        "AuthInfo(clientId: \(clientId), scopes: \(scopes), token: [REDACTED])"
    }
}

// MARK: - Transport Options

/// Configuration options for HTTPServerTransport
public struct HTTPServerTransportOptions: Sendable {
    /// Function that generates a session ID for the transport.
    /// The session ID SHOULD be globally unique and cryptographically secure
    /// (e.g., a securely generated UUID, a JWT, or a cryptographic hash).
    ///
    /// If not provided, session management is disabled (stateless mode).
    public var sessionIdGenerator: (@Sendable () -> String)?

    /// Called when the server initializes a new session.
    /// This is called when the server receives an initialize request and generates a session ID.
    /// Useful for tracking multiple MCP sessions.
    public var onSessionInitialized: (@Sendable (String) async -> Void)?

    /// Called when the server closes a session (DELETE request).
    /// Useful for cleaning up resources associated with the session.
    public var onSessionClosed: (@Sendable (String) async -> Void)?

    /// If true, the server will return JSON responses instead of starting an SSE stream.
    /// This can be useful for simple request/response scenarios without streaming.
    /// Default is false (SSE streams are preferred).
    public var enableJsonResponse: Bool

    /// Event store for resumability support.
    /// If provided, resumability will be enabled, allowing clients to reconnect and resume messages.
    public var eventStore: EventStore?

    /// Retry interval in milliseconds to suggest to clients in SSE retry field.
    /// When set, the server will send a retry field in SSE priming events to control
    /// client reconnection timing for polling behavior.
    public var retryInterval: Int?

    /// DNS rebinding protection settings.
    ///
    /// Defaults to `.localhost()` which protects MCP servers running on user machines
    /// from browser-based DNS rebinding attacks.
    ///
    /// For cloud deployments (Docker, Kubernetes, etc.), use `.none` since DNS rebinding
    /// is not a threat in those environments.
    ///
    /// See ``DNSRebindingProtection`` for detailed documentation on when to use each setting.
    public var dnsRebindingProtection: DNSRebindingProtection

    /// Creates transport options.
    ///
    /// DNS rebinding protection defaults to `.localhost()`, appropriate for MCP servers
    /// running on user machines. For cloud deployments, set `dnsRebindingProtection: .none`.
    ///
    /// - Note: For explicit bind address configuration, use ``forBindAddress(host:port:sessionIdGenerator:onSessionInitialized:onSessionClosed:enableJsonResponse:eventStore:retryInterval:dnsRebindingProtection:)``
    ///   which auto-configures protection based on the address.
    public init(
        sessionIdGenerator: (@Sendable () -> String)? = nil,
        onSessionInitialized: (@Sendable (String) async -> Void)? = nil,
        onSessionClosed: (@Sendable (String) async -> Void)? = nil,
        enableJsonResponse: Bool = false,
        eventStore: EventStore? = nil,
        retryInterval: Int? = nil,
        dnsRebindingProtection: DNSRebindingProtection = .localhost()
    ) {
        self.sessionIdGenerator = sessionIdGenerator
        self.onSessionInitialized = onSessionInitialized
        self.onSessionClosed = onSessionClosed
        self.enableJsonResponse = enableJsonResponse
        self.eventStore = eventStore
        self.retryInterval = retryInterval
        self.dnsRebindingProtection = dnsRebindingProtection
    }

    /// Creates options with DNS rebinding protection configured for the bind address.
    ///
    /// This factory method auto-configures protection based on where the server binds:
    /// - **Localhost** (`127.0.0.1`, `localhost`, `::1`): Enables DNS rebinding protection
    /// - **Other addresses** (e.g., `0.0.0.0`): No protection (cloud deployment assumed)
    ///
    /// ## Examples
    ///
    /// ```swift
    /// // Local development - auto-enables DNS rebinding protection
    /// let options = HTTPServerTransportOptions.forBindAddress(
    ///     host: "localhost",
    ///     port: 8080,
    ///     sessionIdGenerator: { UUID().uuidString }
    /// )
    ///
    /// // Cloud deployment - no protection needed
    /// let options = HTTPServerTransportOptions.forBindAddress(
    ///     host: "0.0.0.0",
    ///     port: 8080,
    ///     sessionIdGenerator: { UUID().uuidString }
    /// )
    ///
    /// // Override with custom host validation
    /// let options = HTTPServerTransportOptions.forBindAddress(
    ///     host: "0.0.0.0",
    ///     port: 8080,
    ///     dnsRebindingProtection: .custom(
    ///         allowedHosts: ["api.example.com:443"],
    ///         allowedOrigins: ["https://app.example.com"]
    ///     )
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - host: The host address the server will bind to
    ///   - port: The port number
    ///   - sessionIdGenerator: Function that generates session IDs (nil for stateless mode)
    ///   - onSessionInitialized: Called when a new session is initialized
    ///   - onSessionClosed: Called when a session is closed
    ///   - enableJsonResponse: If true, return JSON responses instead of SSE streams
    ///   - eventStore: Event store for resumability support
    ///   - retryInterval: Retry interval in milliseconds for SSE
    ///   - dnsRebindingProtection: Override the auto-configured protection settings
    /// - Returns: Configured transport options
    public static func forBindAddress(
        host: String,
        port: Int,
        sessionIdGenerator: (@Sendable () -> String)? = nil,
        onSessionInitialized: (@Sendable (String) async -> Void)? = nil,
        onSessionClosed: (@Sendable (String) async -> Void)? = nil,
        enableJsonResponse: Bool = false,
        eventStore: EventStore? = nil,
        retryInterval: Int? = nil,
        dnsRebindingProtection: DNSRebindingProtection? = nil
    ) -> HTTPServerTransportOptions {
        // Auto-configure protection based on bind address if not explicitly provided
        let effectiveProtection = dnsRebindingProtection ?? DNSRebindingProtection.forBindAddress(host: host, port: port)

        return HTTPServerTransportOptions(
            sessionIdGenerator: sessionIdGenerator,
            onSessionInitialized: onSessionInitialized,
            onSessionClosed: onSessionClosed,
            enableJsonResponse: enableJsonResponse,
            eventStore: eventStore,
            retryInterval: retryInterval,
            dnsRebindingProtection: effectiveProtection
        )
    }
}

/// DNS rebinding protection settings for HTTP server transports.
///
/// DNS rebinding is an attack where a malicious website can bypass browser same-origin policy
/// by manipulating DNS responses, potentially allowing browser-based attackers to interact
/// with local MCP servers. This is particularly dangerous for servers running on a user's
/// machine (localhost).
///
/// ## When to Use Each Setting
///
/// ### Local Development / Servers on User Machines
///
/// Use `.localhost()` (the default) when the MCP server runs on end-user machines:
///
/// ```swift
/// // Default - protects against DNS rebinding attacks via browsers
/// let options = HTTPServerTransportOptions()
///
/// // Or explicitly with port
/// let options = HTTPServerTransportOptions(
///     dnsRebindingProtection: .localhost(port: 8080)
/// )
/// ```
///
/// ### Cloud / Container Deployments
///
/// Use `.none` when deploying to cloud environments (Docker, Kubernetes, etc.):
///
/// ```swift
/// let options = HTTPServerTransportOptions(
///     dnsRebindingProtection: .none  // No browser-based DNS rebinding threat
/// )
/// ```
///
/// DNS rebinding is not a threat in cloud deployments because:
/// - There's no local browser to exploit
/// - The server is already exposed to the network
/// - Authentication is the protection layer
/// - Load balancers/proxies typically handle host validation
///
/// ### Custom Host Validation
///
/// Use `.custom(allowedHosts:allowedOrigins:)` for specific host requirements:
///
/// ```swift
/// let options = HTTPServerTransportOptions(
///     dnsRebindingProtection: .custom(
///         allowedHosts: ["api.example.com:443"],
///         allowedOrigins: ["https://app.example.com"]
///     )
/// )
/// ```
///
/// ## How Protection Works
///
/// When enabled, the transport validates incoming requests:
/// 1. **Host header**: Must match an allowed host pattern (prevents DNS rebinding)
/// 2. **Origin header**: If present (browser requests), must match an allowed origin
///
/// Requests failing validation receive a 421 Misdirected Request response.
public enum DNSRebindingProtection: Sendable, Equatable {
    /// No DNS rebinding protection.
    ///
    /// Use this for cloud deployments (Docker, Kubernetes, cloud platforms) where:
    /// - There's no local browser to exploit
    /// - The server is network-exposed by design
    /// - Authentication handles access control
    /// - Load balancers/proxies handle host validation
    case none

    /// Protection configured for localhost-bound servers.
    ///
    /// Allows requests from `localhost`, `127.0.0.1`, and `[::1]` with the specified port.
    /// This is the appropriate setting for MCP servers running on end-user machines.
    ///
    /// - Parameter port: The port number. If nil, allows any port (wildcard).
    case localhost(port: Int? = nil)

    /// Custom host and origin validation.
    ///
    /// Use for specific requirements like validating requests through a known proxy
    /// or restricting to specific domains.
    ///
    /// - Parameters:
    ///   - allowedHosts: Host header patterns to accept (e.g., "api.example.com:443")
    ///   - allowedOrigins: Origin header patterns to accept (e.g., "https://app.example.com")
    case custom(allowedHosts: [String], allowedOrigins: [String])

    /// Whether protection is enabled for this setting.
    public var isEnabled: Bool {
        switch self {
            case .none:
                false
            case .localhost, .custom:
                true
        }
    }

    /// The allowed Host header values for this setting.
    public var allowedHosts: [String] {
        switch self {
            case .none:
                return []
            case let .localhost(port):
                let portPattern = port.map { String($0) } ?? "*"
                return [
                    "127.0.0.1:\(portPattern)",
                    "localhost:\(portPattern)",
                    "[::1]:\(portPattern)",
                ]
            case let .custom(hosts, _):
                return hosts
        }
    }

    /// The allowed Origin header values for this setting.
    public var allowedOrigins: [String] {
        switch self {
            case .none:
                return []
            case let .localhost(port):
                let portPattern = port.map { String($0) } ?? "*"
                return [
                    "http://127.0.0.1:\(portPattern)",
                    "http://localhost:\(portPattern)",
                    "http://[::1]:\(portPattern)",
                ]
            case let .custom(_, origins):
                return origins
        }
    }

    /// Creates protection settings appropriate for the given bind address.
    ///
    /// - For localhost addresses (`127.0.0.1`, `localhost`, `::1`): Returns `.localhost(port:)`
    /// - For other addresses (e.g., `0.0.0.0`): Returns `.none`
    ///
    /// - Parameters:
    ///   - host: The host address the server is binding to
    ///   - port: The port number
    /// - Returns: Appropriate protection setting for the bind address
    public static func forBindAddress(host: String, port: Int) -> DNSRebindingProtection {
        let localhostAddresses = ["127.0.0.1", "localhost", "::1"]
        if localhostAddresses.contains(host) {
            return .localhost(port: port)
        }
        return .none
    }
}

// MARK: - Legacy Type Alias

@available(*, deprecated, renamed: "DNSRebindingProtection")
public typealias TransportSecuritySettings = DNSRebindingProtection

/// Protocol for storing and replaying SSE events for resumability support.
///
/// Implementations should store events durably and support replaying them
/// when clients reconnect with a Last-Event-ID header.
///
/// ## Priming Events
///
/// Priming events are stored with empty `Data()` as the message. These events
/// establish the initial event ID for a stream but should **not** be replayed
/// as regular messages. During replay, implementations should skip events with
/// empty message data and only replay actual JSON-RPC messages.
public protocol EventStore: Sendable {
    /// Stores an event and returns its unique ID.
    ///
    /// - Parameters:
    ///   - streamId: The stream this event belongs to
    ///   - message: The JSON-RPC message data. Empty `Data()` indicates a priming event
    ///              which should be skipped during replay.
    /// - Returns: A unique event ID for this event
    func storeEvent(streamId: String, message: Data) async throws -> String

    /// Gets the stream ID associated with an event ID.
    /// - Parameter eventId: The event ID to look up
    /// - Returns: The stream ID, or nil if not found
    func streamIdForEventId(_ eventId: String) async -> String?

    /// Replays events after the given event ID.
    ///
    /// Implementations should skip priming events (empty message data) during replay.
    /// Only actual JSON-RPC messages should be sent to the callback.
    ///
    /// - Parameters:
    ///   - lastEventId: The last event ID the client received
    ///   - send: Callback to send each replayed event (eventId, message)
    /// - Returns: The stream ID for continued event delivery
    func replayEventsAfter(
        _ lastEventId: String,
        send: @escaping @Sendable (String, Data) async throws -> Void
    ) async throws -> String
}

/// HTTP response returned by `HTTPServerTransport.handleRequest(_:)`.
///
/// This struct represents the result of processing an MCP request. It can contain either:
/// - A simple JSON response with `body` data (for non-streaming responses)
/// - An SSE stream for streaming responses (for long-running operations or server-initiated messages)
///
/// ## Usage with HTTP Frameworks
///
/// When integrating with an HTTP framework like Vapor or Hummingbird, convert this response
/// to the framework's native response type:
///
/// ```swift
/// // Vapor example
/// func handleMCP(req: Request) async throws -> Response {
///     let httpRequest = HTTPRequest(
///         method: req.method.rawValue,
///         headers: Dictionary(req.headers.map { ($0.name, $0.value) }) { _, last in last },
///         body: req.body.data
///     )
///     let response = await transport.handleRequest(httpRequest)
///
///     if let stream = response.stream {
///         // Return SSE response
///         return Response(status: .init(statusCode: response.statusCode), body: .init(asyncSequence: stream))
///     } else {
///         // Return JSON response
///         return Response(status: .init(statusCode: response.statusCode), body: .init(data: response.body ?? Data()))
///     }
/// }
/// ```
public struct HTTPResponse: Sendable {
    /// The HTTP status code for the response (e.g., 200, 400, 404).
    public let statusCode: Int
    /// HTTP headers to include in the response (e.g., Content-Type, Mcp-Session-Id).
    public let headers: [String: String]
    /// Response body data for non-streaming responses. Nil for SSE streaming responses.
    public let body: Data?
    /// SSE stream for streaming responses. Nil for simple JSON responses.
    /// When present, the caller should stream this data to the client as Server-Sent Events.
    public let stream: AsyncThrowingStream<Data, Swift.Error>?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil,
        stream: AsyncThrowingStream<Data, Swift.Error>? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.stream = stream
    }
}

/// HTTP request abstraction for framework-agnostic handling.
///
/// This struct provides a common interface for HTTP requests that can be populated from
/// any HTTP server framework (Vapor, Hummingbird, SwiftNIO, etc.). The
/// `HTTPServerTransport` uses this abstraction to process MCP requests
/// without being coupled to a specific framework.
///
/// ## Usage
///
/// Convert your framework's request type to `HTTPRequest` before passing to the transport:
///
/// ```swift
/// // Vapor example
/// let httpRequest = HTTPRequest(
///     method: req.method.rawValue,
///     headers: Dictionary(req.headers.map { ($0.name, $0.value) }) { _, last in last },
///     body: req.body.data
/// )
///
/// // Hummingbird example
/// let httpRequest = HTTPRequest(
///     method: String(describing: request.method),
///     headers: Dictionary(request.headers.map { ($0.name.rawName, $0.value) }) { _, last in last },
///     body: request.body.buffer?.getData(at: 0, length: request.body.buffer?.readableBytes ?? 0)
/// )
/// ```
public struct HTTPRequest: Sendable {
    /// The HTTP method (e.g., "GET", "POST", "DELETE").
    public let method: String
    /// Request headers as a case-sensitive dictionary.
    /// Use the `header(_:)` method for case-insensitive header lookup.
    public let headers: [String: String]
    /// The request body data, if present.
    public let body: Data?

    public init(method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// Get a header value (case-insensitive)
    public func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lowercased {
                return value
            }
        }
        return nil
    }
}
