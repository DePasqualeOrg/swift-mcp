// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Logging

import struct Foundation.Data

// MARK: - Message Context Types

/// Information about the incoming HTTP request.
///
/// This is the Swift equivalent of TypeScript's `RequestInfo` interface, which
/// provides access to HTTP request headers for request handlers.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     if let requestInfo = context.requestInfo {
///         // Access custom headers
///         if let customHeader = requestInfo.headers["X-Custom-Header"] {
///             print("Custom header: \(customHeader)")
///         }
///     }
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct RequestInfo: Hashable, Sendable {
    /// The HTTP headers from the request.
    ///
    /// Header names are preserved as provided by the HTTP framework.
    /// Use case-insensitive comparison when looking up headers.
    public let headers: [String: String]

    public init(headers: [String: String]) {
        self.headers = headers
    }

    /// Get a header value (case-insensitive lookup).
    ///
    /// - Parameter name: The header name to look up
    /// - Returns: The header value, or nil if not found
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

/// Context information associated with a received message.
///
/// This is the Swift equivalent of TypeScript's `MessageExtraInfo`, which is passed
/// via `onmessage(message, extra)`. It carries per-message context like authentication
/// info and SSE stream management callbacks.
///
/// For simple transports (stdio, in-memory), context is typically `nil`.
/// For HTTP transports, context includes authentication info and SSE controls.
public struct MessageMetadata: Sendable {
    /// Authentication information for this message's request.
    ///
    /// Contains validated access token information when using HTTP transports
    /// with OAuth or other token-based authentication. Request handlers can
    /// access this via `context.authInfo`.
    public let authInfo: AuthInfo?

    /// Information about the incoming HTTP request.
    ///
    /// Contains HTTP headers from the original request. Only available for
    /// HTTP transports. Request handlers can access this via `context.requestInfo`.
    ///
    /// This matches TypeScript SDK's `extra.requestInfo` and allows handlers
    /// to inspect custom headers for authentication, client identification, etc.
    public let requestInfo: RequestInfo?

    /// Closes the SSE stream for this request, triggering client reconnection.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    /// Use this to implement polling behavior during long-running operations.
    public let closeResponseStream: (@Sendable () async -> Void)?

    /// Closes the standalone GET SSE stream, triggering client reconnection.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    public let closeNotificationStream: (@Sendable () async -> Void)?

    public init(
        authInfo: AuthInfo? = nil,
        requestInfo: RequestInfo? = nil,
        closeResponseStream: (@Sendable () async -> Void)? = nil,
        closeNotificationStream: (@Sendable () async -> Void)? = nil
    ) {
        self.authInfo = authInfo
        self.requestInfo = requestInfo
        self.closeResponseStream = closeResponseStream
        self.closeNotificationStream = closeNotificationStream
    }
}

/// A message received from a transport with optional context.
///
/// This is the Swift equivalent of TypeScript's `onmessage(message, extra)` pattern,
/// adapted for Swift's `AsyncThrowingStream` approach. Each message carries its own
/// context, eliminating race conditions that would occur if context were stored
/// as mutable state on the transport.
///
/// ## Example
///
/// ```swift
/// for try await message in transport.receive() {
///     let data = message.data
///     if let authInfo = message.context?.authInfo {
///         // Handle authenticated request
///     }
/// }
/// ```
public struct TransportMessage: Sendable {
    /// The raw message data (JSON-RPC message).
    public let data: Data

    /// Context associated with this message.
    ///
    /// Includes authentication info, SSE stream controls, and other per-message
    /// context. For simple transports, this is `nil`.
    public let context: MessageMetadata?

    public init(data: Data, context: MessageMetadata? = nil) {
        self.data = data
        self.context = context
    }
}

// MARK: - Transport Send Options

/// Options for sending data through a transport.
///
/// This struct provides extensible options for the transport `send` method,
/// matching the TypeScript SDK's `TransportSendOptions` pattern. New options
/// can be added here without changing the `Transport` protocol signature.
///
/// For simple sends without special options, use the convenience
/// `send(_ data: Data)` extension instead.
public struct TransportSendOptions: Sendable {
    /// The ID of a related request, used for response routing in multiplexed transports.
    ///
    /// For transports that support multiplexing (like HTTP), this enables routing
    /// responses back to the correct client connection.
    ///
    /// For simple transports (stdio, single-connection), this is ignored.
    public var relatedRequestId: RequestId?

    /// Creates transport send options.
    ///
    /// - Parameter relatedRequestId: The ID of the request this message relates to (for response routing)
    public init(relatedRequestId: RequestId? = nil) {
        self.relatedRequestId = relatedRequestId
    }
}

// MARK: - Transport Protocol

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// The session identifier for this transport connection.
    ///
    /// For HTTP transports supporting multiple concurrent clients, each client
    /// session has a unique identifier. This enables per-session features like
    /// independent log levels for each client.
    ///
    /// For simple transports (stdio, single-connection), this returns `nil`.
    var sessionId: String? { get }

    /// Whether this transport supports server-to-client requests.
    ///
    /// Server-to-client requests (sampling, elicitation, roots) require a persistent
    /// bidirectional connection. Stateless HTTP transports do not support this because
    /// each request is independent with no way to send requests back to the client.
    ///
    /// Most transports (stdio, stateful HTTP) support this and return `true`.
    /// Stateless HTTP transports return `false`.
    var supportsServerToClientRequests: Bool { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data with the specified options.
    ///
    /// For transports that support multiplexing (like HTTP), the options may include
    /// a related request ID for routing responses back to the correct client connection.
    ///
    /// For simple transports (stdio, single-connection), options can be ignored.
    ///
    /// - Parameters:
    ///   - data: The data to send
    ///   - options: Options controlling how the data is sent
    func send(_ data: Data, options: TransportSendOptions) async throws

    /// Receives messages with optional context in an async sequence.
    ///
    /// Each message includes optional context (auth info, SSE closures, etc.)
    /// that was associated with it at receive time. This pattern matches
    /// TypeScript's `onmessage(message, extra)` callback approach.
    ///
    /// For simple transports, messages are yielded with `nil` context.
    /// For HTTP transports, context includes authentication info and SSE controls.
    func receive() -> AsyncThrowingStream<TransportMessage, Swift.Error>
}

// MARK: - Optional Transport Methods

public extension Transport {
    /// Default implementation returns `nil` for simple transports.
    ///
    /// HTTP transports override this to return their session identifier.
    var sessionId: String? { nil }

    /// Default implementation returns `true` since most transports support
    /// bidirectional communication. Stateless HTTP transports override this.
    var supportsServerToClientRequests: Bool { true }

    /// Convenience method for sending data without options.
    ///
    /// Calls `send(_:options:)` with default options.
    func send(_ data: Data) async throws {
        try await send(data, options: TransportSendOptions())
    }

    /// Sets the negotiated protocol version on the transport.
    ///
    /// HTTP transports override this to include the protocol version in request headers
    /// after initialization completes. For example, the `Mcp-Protocol-Version` header.
    ///
    /// This method is called by the Client after receiving the initialization response
    /// from the server. Simple transports (stdio, in-memory) use the default no-op
    /// implementation since they don't need version headers.
    ///
    /// - Parameter version: The negotiated protocol version string (e.g., "2025-03-26")
    func setProtocolVersion(_: String) async {
        // Default no-op implementation for transports that don't need version headers
    }

    /// Sets the supported protocol versions on the transport.
    ///
    /// HTTP server transports override this to validate the `MCP-Protocol-Version`
    /// header against the configured list. Called by the server during `start()`
    /// and by the client during `connect()`.
    ///
    /// - Parameter versions: Supported protocol versions, ordered by preference
    func setSupportedProtocolVersions(_: [String]) async {
        // Default no-op implementation for transports that don't need version validation
    }
}
