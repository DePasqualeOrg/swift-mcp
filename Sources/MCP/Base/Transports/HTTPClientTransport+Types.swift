import Foundation

// Types extracted from HTTPClientTransport.swift
// - HTTPReconnectionOptions
// - URLSessionConfiguration extension for MCP

// MARK: - MCP Default Timeout Configuration

/// Default timeout for general HTTP operations (connect, write).
/// Matches the Python SDK's MCP_DEFAULT_TIMEOUT.
public let mcpDefaultTimeout: TimeInterval = 30.0

/// Default timeout for SSE read operations.
/// SSE connections need longer timeouts since they wait for server-pushed events.
/// Matches the Python SDK's MCP_DEFAULT_SSE_READ_TIMEOUT.
public let mcpDefaultSSEReadTimeout: TimeInterval = 300.0

public extension URLSessionConfiguration {
    /// Creates a URLSessionConfiguration optimized for MCP HTTP transport.
    ///
    /// This configuration sets appropriate timeouts for long-lived SSE connections:
    /// - `timeoutIntervalForRequest`: 300 seconds (5 minutes) to handle slow responses
    ///   and SSE connections that wait for server events
    /// - `timeoutIntervalForResource`: 3600 seconds (1 hour) for the total connection lifetime
    ///
    /// These defaults match the Python MCP SDK's timeout configuration.
    static var mcp: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        // Use SSE read timeout for request interval since SSE connections
        // may wait extended periods for server events
        configuration.timeoutIntervalForRequest = mcpDefaultSSEReadTimeout
        // Allow connections to stay open for up to 1 hour
        configuration.timeoutIntervalForResource = 3600
        return configuration
    }
}

// MARK: - Reconnection Options

/// Configuration options for reconnection behavior of the HTTPClientTransport.
///
/// These options control how the transport handles SSE stream disconnections
/// and reconnection attempts.
public struct HTTPReconnectionOptions: Sendable {
    /// Initial delay between reconnection attempts in seconds.
    /// Default is 1.0 second.
    public var initialReconnectionDelay: TimeInterval

    /// Maximum delay between reconnection attempts in seconds.
    /// Default is 30.0 seconds.
    public var maxReconnectionDelay: TimeInterval

    /// Factor by which the reconnection delay increases after each attempt.
    /// Default is 1.5.
    public var reconnectionDelayGrowFactor: Double

    /// Maximum number of reconnection attempts before giving up.
    /// Default is 2.
    public var maxRetries: Int

    /// Creates reconnection options with default values.
    public init(
        initialReconnectionDelay: TimeInterval = 1.0,
        maxReconnectionDelay: TimeInterval = 30.0,
        reconnectionDelayGrowFactor: Double = 1.5,
        maxRetries: Int = 2
    ) {
        self.initialReconnectionDelay = initialReconnectionDelay
        self.maxReconnectionDelay = maxReconnectionDelay
        self.reconnectionDelayGrowFactor = reconnectionDelayGrowFactor
        self.maxRetries = maxRetries
    }

    /// Default reconnection options.
    public static let `default` = HTTPReconnectionOptions()
}
