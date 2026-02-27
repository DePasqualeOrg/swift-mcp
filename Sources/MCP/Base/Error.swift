// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

// MARK: - Error Codes

/// JSON-RPC and MCP error codes.
///
/// Error codes are organized by source:
/// - Standard JSON-RPC 2.0 error codes (-32700 to -32600)
/// - MCP specification error codes (-32002, -32042)
/// - SDK-specific error codes (-32000, -32001, -32003)
public enum ErrorCode {
    // MARK: Standard JSON-RPC 2.0 Errors

    /// Parse error: Invalid JSON was received by the server.
    public static let parseError: Int = -32700

    /// Invalid request: The JSON sent is not a valid Request object.
    public static let invalidRequest: Int = -32600

    /// Method not found: The method does not exist or is not available.
    public static let methodNotFound: Int = -32601

    /// Invalid params: Invalid method parameter(s).
    public static let invalidParams: Int = -32602

    /// Internal error: Internal JSON-RPC error.
    public static let internalError: Int = -32603

    // MARK: MCP Specification Errors

    /// Resource not found: The requested resource does not exist.
    ///
    /// Defined in MCP specification (resources.mdx).
    public static let resourceNotFound: Int = -32002

    /// URL elicitation required: The request requires URL-mode elicitation(s) to be completed.
    ///
    /// Defined in MCP specification (schema).
    public static let urlElicitationRequired: Int = -32042

    // MARK: SDK-Specific Errors

    /// Connection closed: The connection to the server was closed.
    ///
    /// Not defined in MCP spec. SDK-specific, matches TypeScript SDK.
    public static let connectionClosed: Int = -32000

    /// Request timeout: The server did not respond within the timeout period.
    ///
    /// Not defined in MCP spec. SDK-specific, matches TypeScript SDK.
    public static let requestTimeout: Int = -32001

    /// Session expired: The server session is no longer valid.
    ///
    /// Not defined in MCP spec. SDK-specific for Swift.
    public static let sessionExpired: Int = -32005

    /// Transport error: An error occurred in the transport layer.
    ///
    /// Not defined in MCP spec. SDK-specific for Swift.
    public static let transportError: Int = -32003

    /// Request cancelled: The request was cancelled before completion.
    ///
    /// Not defined in MCP spec. SDK-specific for Swift.
    public static let requestCancelled: Int = -32004
}

// MARK: - MCPError

/// A model context protocol error.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors
    case parseError(String?)
    case invalidRequest(String?)
    case methodNotFound(String?)
    case invalidParams(String?)
    case internalError(String?)

    // MCP-specific errors
    /// The requested resource was not found.
    /// Defined in MCP specification (resources.mdx) with error code -32002.
    case resourceNotFound(uri: String?)

    /// URL elicitation is required before the request can proceed.
    /// Servers throw this from tool handlers when URL-mode elicitation(s) must be completed.
    case urlElicitationRequired(message: String, elicitations: [ElicitRequestURLParams])

    // Server errors (-32000 to -32099)
    case serverError(code: Int, message: String)
    /// Server error with additional data payload.
    case serverErrorWithData(code: Int, message: String, data: Value)

    // Transport and connection errors
    case connectionClosed
    case sessionExpired
    case transportError(Swift.Error)

    // Request timeout
    /// Request timed out waiting for a response.
    case requestTimeout(timeout: Duration, message: String?)

    // Request cancellation
    /// Request was cancelled before completion.
    case requestCancelled(reason: String?)

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
            case .parseError: ErrorCode.parseError
            case .invalidRequest: ErrorCode.invalidRequest
            case .methodNotFound: ErrorCode.methodNotFound
            case .invalidParams: ErrorCode.invalidParams
            case .internalError: ErrorCode.internalError
            case .resourceNotFound: ErrorCode.resourceNotFound
            case .urlElicitationRequired: ErrorCode.urlElicitationRequired
            case let .serverError(code, _): code
            case let .serverErrorWithData(code, _, _): code
            case .connectionClosed: ErrorCode.connectionClosed
            case .sessionExpired: ErrorCode.sessionExpired
            case .transportError: ErrorCode.transportError
            case .requestTimeout: ErrorCode.requestTimeout
            case .requestCancelled: ErrorCode.requestCancelled
        }
    }

    /// Creates a URL elicitation required error.
    ///
    /// Use this when a tool handler needs the client to complete URL-mode elicitation(s)
    /// before the request can proceed.
    ///
    /// Example:
    /// ```swift
    /// throw MCPError.urlElicitationRequired(
    ///     elicitations: [
    ///         ElicitRequestURLParams(
    ///             message: "Please authorize access",
    ///             elicitationId: "auth-123",
    ///             url: "https://example.com/oauth"
    ///         )
    ///     ]
    /// )
    /// ```
    public static func urlElicitationRequired(
        elicitations: [ElicitRequestURLParams],
        message: String? = nil
    ) -> MCPError {
        let msg = message ?? "URL elicitation\(elicitations.count > 1 ? "s" : "") required"
        return .urlElicitationRequired(message: msg, elicitations: elicitations)
    }

    /// Attempts to extract elicitations from an error if it's a URL elicitation required error.
    public var elicitations: [ElicitRequestURLParams]? {
        if case let .urlElicitationRequired(_, elicitations) = self {
            return elicitations
        }
        return nil
    }

    /// The raw error message for wire format serialization.
    ///
    /// This returns the message suitable for JSON-RPC 2.0 error format, without
    /// any additional prefixes or formatting that `errorDescription` might add.
    /// Use this for serialization; use `errorDescription` for human-readable display.
    public var message: String {
        switch self {
            case let .parseError(detail):
                detail ?? "Invalid JSON"
            case let .invalidRequest(detail):
                detail ?? "Invalid Request"
            case let .methodNotFound(detail):
                detail ?? "Method not found"
            case let .invalidParams(detail):
                detail ?? "Invalid params"
            case let .internalError(detail):
                detail ?? "Internal error"
            case let .resourceNotFound(uri):
                uri.map { "Resource not found: \($0)" } ?? "Resource not found"
            case let .urlElicitationRequired(message, _):
                message
            case let .serverError(_, message):
                message
            case let .serverErrorWithData(_, message, _):
                message
            case .connectionClosed:
                "Connection closed"
            case .sessionExpired:
                "Session expired"
            case let .transportError(error):
                error.localizedDescription
            case let .requestTimeout(timeout, message):
                message ?? "Request timed out after \(timeout)"
            case let .requestCancelled(reason):
                reason ?? "Request cancelled"
        }
    }

    /// The error data payload for wire format serialization.
    ///
    /// This returns the additional data to include in the JSON-RPC 2.0 error,
    /// following MCP specification requirements for specific error types.
    public var data: Value? {
        switch self {
            case .parseError, .invalidRequest, .methodNotFound, .invalidParams, .internalError:
                // Standard JSON-RPC errors don't require data
                return nil
            case let .resourceNotFound(uri):
                // Resource not found includes the URI in data per MCP spec
                if let uri {
                    return .object(["uri": .string(uri)])
                }
                return nil
            case let .urlElicitationRequired(_, elicitations):
                // URL elicitation required includes elicitations in data per MCP spec
                do {
                    let encoded = try JSONEncoder().encode(ElicitationRequiredErrorData(elicitations: elicitations))
                    return try JSONDecoder().decode(Value.self, from: encoded)
                } catch {
                    return nil
                }
            case .serverError:
                return nil
            case let .serverErrorWithData(_, _, data):
                return data
            case .connectionClosed:
                return nil
            case .sessionExpired:
                return nil
            case let .transportError(error):
                return .object(["error": .string(error.localizedDescription)])
            case let .requestTimeout(timeout, _):
                let timeoutMs = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
                return .object(["timeout": .int(timeoutMs)])
            case let .requestCancelled(reason):
                if let reason {
                    return .object(["reason": .string(reason)])
                }
                return nil
        }
    }

    /// Check if an error represents a "resource temporarily unavailable" condition
    public static func isResourceTemporarilyUnavailable(_ error: Swift.Error) -> Bool {
        #if canImport(System)
        if let errno = error as? System.Errno, errno == .resourceTemporarilyUnavailable {
            return true
        }
        #else
        if let errno = error as? SystemPackage.Errno, errno == .resourceTemporarilyUnavailable {
            return true
        }
        #endif
        return false
    }
}

// MARK: LocalizedError

extension MCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case let .parseError(detail):
                "Parse error: Invalid JSON" + (detail.map { ": \($0)" } ?? "")
            case let .invalidRequest(detail):
                "Invalid Request" + (detail.map { ": \($0)" } ?? "")
            case let .methodNotFound(detail):
                "Method not found" + (detail.map { ": \($0)" } ?? "")
            case let .invalidParams(detail):
                "Invalid params" + (detail.map { ": \($0)" } ?? "")
            case let .internalError(detail):
                "Internal error" + (detail.map { ": \($0)" } ?? "")
            case let .resourceNotFound(uri):
                "Resource not found" + (uri.map { ": \($0)" } ?? "")
            case let .urlElicitationRequired(message, _):
                message
            case let .serverError(_, message):
                "Server error: \(message)"
            case let .serverErrorWithData(_, message, _):
                "Server error: \(message)"
            case .connectionClosed:
                "Connection closed"
            case .sessionExpired:
                "Session expired"
            case let .transportError(error):
                "Transport error: \(error.localizedDescription)"
            case let .requestTimeout(timeout, message):
                if let message {
                    "Request timeout: \(message)"
                } else {
                    "Request timed out after \(timeout)"
                }
            case let .requestCancelled(reason):
                "Request cancelled" + (reason.map { ": \($0)" } ?? "")
        }
    }

    public var failureReason: String? {
        switch self {
            case .parseError:
                "The server received invalid JSON that could not be parsed"
            case .invalidRequest:
                "The JSON sent is not a valid Request object"
            case .methodNotFound:
                "The method does not exist or is not available"
            case .invalidParams:
                "Invalid method parameter(s)"
            case .internalError:
                "Internal JSON-RPC error"
            case .resourceNotFound:
                "The requested resource does not exist"
            case .urlElicitationRequired:
                "The request requires URL-mode elicitation(s) to be completed first"
            case .serverError, .serverErrorWithData:
                "Server-defined error occurred"
            case .connectionClosed:
                "The connection to the server was closed"
            case .sessionExpired:
                "The server session is no longer valid"
            case let .transportError(error):
                (error as? LocalizedError)?.failureReason ?? error.localizedDescription
            case .requestTimeout:
                "The server did not respond within the timeout period"
            case .requestCancelled:
                "The request was cancelled before it could complete"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
            case .parseError:
                "Verify that the JSON being sent is valid and well-formed"
            case .invalidRequest:
                "Ensure the request follows the JSON-RPC 2.0 specification format"
            case .methodNotFound:
                "Check the method name and ensure it is supported by the server"
            case .invalidParams:
                "Verify the parameters match the method's expected parameters"
            case .resourceNotFound:
                "Verify the resource URI is correct and the resource exists"
            case .urlElicitationRequired:
                "Complete the required URL elicitation(s) and retry the request"
            case .connectionClosed:
                "Try reconnecting to the server"
            case .sessionExpired:
                "Try reconnecting to the server"
            case .requestTimeout:
                "Try increasing the timeout or check if the server is responding"
            case .requestCancelled:
                "Retry the request if needed"
            default:
                nil
        }
    }
}

// MARK: CustomDebugStringConvertible

extension MCPError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
            case let .transportError(error):
                "[\(code)] \(errorDescription ?? "") (Underlying error: \(String(reflecting: error)))"
            default:
                "[\(code)] \(errorDescription ?? "")"
        }
    }
}

// MARK: Codable

extension MCPError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)

        // Encode data if available
        if let data {
            try container.encode(data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)

        // Try to decode data as a generic Value first
        let dataValue = try container.decodeIfPresent(Value.self, forKey: .data)

        // Helper to check if message is the default for a given error type.
        // If it's the default, we use nil as the detail; otherwise we use the custom message.
        func customDetailOrNil(ifNotDefault defaultMessage: String) -> String? {
            message == defaultMessage ? nil : message
        }

        switch code {
            case ErrorCode.parseError:
                self = .parseError(customDetailOrNil(ifNotDefault: "Invalid JSON"))
            case ErrorCode.invalidRequest:
                self = .invalidRequest(customDetailOrNil(ifNotDefault: "Invalid Request"))
            case ErrorCode.methodNotFound:
                self = .methodNotFound(customDetailOrNil(ifNotDefault: "Method not found"))
            case ErrorCode.invalidParams:
                self = .invalidParams(customDetailOrNil(ifNotDefault: "Invalid params"))
            case ErrorCode.internalError:
                self = .internalError(customDetailOrNil(ifNotDefault: "Internal error"))
            case ErrorCode.resourceNotFound:
                // Extract URI from data if present
                var uri: String? = nil
                if case let .object(dict) = dataValue,
                   case let .string(u) = dict["uri"]
                {
                    uri = u
                }
                self = .resourceNotFound(uri: uri)
            case ErrorCode.urlElicitationRequired:
                // Try to decode elicitations from data
                if let errorData = try? container.decode(ElicitationRequiredErrorData.self, forKey: .data) {
                    self = .urlElicitationRequired(message: message, elicitations: errorData.elicitations)
                } else {
                    // Fall back to server error if data doesn't match expected format
                    self = .serverError(code: code, message: message)
                }
            case ErrorCode.connectionClosed:
                self = .connectionClosed
            case ErrorCode.sessionExpired:
                self = .sessionExpired
            case ErrorCode.requestTimeout:
                // Extract timeout from data if present
                var timeoutMs = 60000 // Default 60 seconds
                if case let .object(dict) = dataValue,
                   let timeoutValue = dict["timeout"],
                   case let .int(t) = timeoutValue
                {
                    timeoutMs = t
                }
                self = .requestTimeout(timeout: .milliseconds(timeoutMs), message: message)
            case ErrorCode.transportError:
                // Extract underlying error string if present
                var underlyingErrorString = message
                if case let .object(dict) = dataValue,
                   case let .string(str) = dict["error"]
                {
                    underlyingErrorString = str
                }
                self = .transportError(
                    NSError(
                        domain: "org.jsonrpc.error",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                    )
                )
            case ErrorCode.requestCancelled:
                // Extract reason from data if present
                var reason: String? = nil
                if case let .object(dict) = dataValue,
                   case let .string(r) = dict["reason"]
                {
                    reason = r
                } else if message != "Request cancelled" {
                    reason = message
                }
                self = .requestCancelled(reason: reason)
            default:
                // Preserve data if present
                if let dataValue {
                    self = .serverErrorWithData(code: code, message: message, data: dataValue)
                } else {
                    self = .serverError(code: code, message: message)
                }
        }
    }

    /// Reconstructs an MCPError from error code, message, and optional data.
    ///
    /// This is useful for clients receiving error responses and wanting to
    /// work with typed error values.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code
    ///   - message: The error message
    ///   - data: Optional additional error data
    /// - Returns: The appropriate MCPError type
    public static func fromError(code: Int, message: String, data: Value? = nil) -> MCPError {
        // Helper to check if message is the default for a given error type.
        // If it's the default, we use nil as the detail; otherwise we use the custom message.
        func customDetailOrNil(ifNotDefault defaultMessage: String) -> String? {
            message == defaultMessage ? nil : message
        }

        switch code {
            case ErrorCode.parseError:
                return .parseError(customDetailOrNil(ifNotDefault: "Invalid JSON"))
            case ErrorCode.invalidRequest:
                return .invalidRequest(customDetailOrNil(ifNotDefault: "Invalid Request"))
            case ErrorCode.methodNotFound:
                return .methodNotFound(customDetailOrNil(ifNotDefault: "Method not found"))
            case ErrorCode.invalidParams:
                return .invalidParams(customDetailOrNil(ifNotDefault: "Invalid params"))
            case ErrorCode.internalError:
                return .internalError(customDetailOrNil(ifNotDefault: "Internal error"))
            case ErrorCode.resourceNotFound:
                // Extract URI from data if present
                var uri: String? = nil
                if case let .object(dict) = data,
                   case let .string(u) = dict["uri"]
                {
                    uri = u
                }
                return .resourceNotFound(uri: uri)
            case ErrorCode.urlElicitationRequired:
                // Try to extract elicitations from data
                if case let .object(dict) = data,
                   case let .array(elicitationsArray) = dict["elicitations"]
                {
                    // Decode each elicitation
                    var elicitations: [ElicitRequestURLParams] = []
                    for item in elicitationsArray {
                        if case .object = item {
                            // Re-encode and decode to get proper type
                            if let jsonData = try? JSONEncoder().encode(item),
                               let params = try? JSONDecoder().decode(ElicitRequestURLParams.self, from: jsonData)
                            {
                                elicitations.append(params)
                            }
                        }
                    }
                    if !elicitations.isEmpty {
                        return .urlElicitationRequired(message: message, elicitations: elicitations)
                    }
                }
                // Fall back to server error if we can't parse elicitations
                return .serverError(code: code, message: message)
            case ErrorCode.connectionClosed:
                return .connectionClosed
            case ErrorCode.sessionExpired:
                return .sessionExpired
            case ErrorCode.requestTimeout:
                // Extract timeout from data if present
                var timeoutMs = 60000 // Default 60 seconds
                if case let .object(dict) = data,
                   let timeoutValue = dict["timeout"],
                   case let .int(t) = timeoutValue
                {
                    timeoutMs = t
                }
                return .requestTimeout(timeout: .milliseconds(timeoutMs), message: message)
            case ErrorCode.transportError:
                // Extract underlying error string if present
                var underlyingErrorString = message
                if case let .object(dict) = data,
                   case let .string(str) = dict["error"]
                {
                    underlyingErrorString = str
                }
                return .transportError(
                    NSError(
                        domain: "org.jsonrpc.error",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                    )
                )
            case ErrorCode.requestCancelled:
                // Extract reason from data if present
                var reason: String? = nil
                if case let .object(dict) = data,
                   case let .string(r) = dict["reason"]
                {
                    reason = r
                } else if message != "Request cancelled" {
                    reason = message
                }
                return .requestCancelled(reason: reason)
            default:
                if let data {
                    return .serverErrorWithData(code: code, message: message, data: data)
                }
                return .serverError(code: code, message: message)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        switch (lhs, rhs) {
            case let (.parseError(l), .parseError(r)):
                l == r
            case let (.invalidRequest(l), .invalidRequest(r)):
                l == r
            case let (.methodNotFound(l), .methodNotFound(r)):
                l == r
            case let (.invalidParams(l), .invalidParams(r)):
                l == r
            case let (.internalError(l), .internalError(r)):
                l == r
            case let (.resourceNotFound(l), .resourceNotFound(r)):
                l == r
            case let (.urlElicitationRequired(lMsg, lElicit), .urlElicitationRequired(rMsg, rElicit)):
                lMsg == rMsg && lElicit == rElicit
            case let (.serverError(lCode, lMsg), .serverError(rCode, rMsg)):
                lCode == rCode && lMsg == rMsg
            case let (.serverErrorWithData(lCode, lMsg, lData), .serverErrorWithData(rCode, rMsg, rData)):
                lCode == rCode && lMsg == rMsg && lData == rData
            case (.connectionClosed, .connectionClosed):
                true
            case (.sessionExpired, .sessionExpired):
                true
            case let (.transportError(l), .transportError(r)):
                l.localizedDescription == r.localizedDescription
            case let (.requestTimeout(lTimeout, lMsg), .requestTimeout(rTimeout, rMsg)):
                lTimeout == rTimeout && lMsg == rMsg
            case let (.requestCancelled(lReason), .requestCancelled(rReason)):
                lReason == rReason
            default:
                false
        }
    }
}

// MARK: - JSONRPCErrorResponse

/// A JSON-RPC 2.0 error response for transport-level errors.
///
/// Transport-level errors (e.g., invalid headers, missing session ID) occur before a valid
/// request is parsed, so the response must have `"id": null` per JSON-RPC 2.0. This struct
/// encodes the error envelope with a null `id` using `Codable`, replacing the previous
/// pattern of `JSONSerialization` + `NSNull`.
public struct JSONRPCErrorResponse: Encodable {
    private let jsonrpc = "2.0"
    private let error: MCPError

    public init(code: Int, message: String) {
        error = .serverError(code: code, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, error, id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(error, forKey: .error)
        try container.encodeNil(forKey: .id)
    }

    /// Encodes this error response to JSON `Data`.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: Hashable

extension MCPError: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        switch self {
            case let .parseError(detail):
                hasher.combine(detail)
            case let .invalidRequest(detail):
                hasher.combine(detail)
            case let .methodNotFound(detail):
                hasher.combine(detail)
            case let .invalidParams(detail):
                hasher.combine(detail)
            case let .internalError(detail):
                hasher.combine(detail)
            case let .resourceNotFound(uri):
                hasher.combine(uri)
            case let .urlElicitationRequired(message, elicitations):
                hasher.combine(message)
                hasher.combine(elicitations)
            case let .serverError(_, message):
                hasher.combine(message)
            case let .serverErrorWithData(_, message, data):
                hasher.combine(message)
                hasher.combine(data)
            case .connectionClosed:
                break
            case .sessionExpired:
                break
            case let .transportError(error):
                hasher.combine(error.localizedDescription)
            case let .requestTimeout(timeout, message):
                hasher.combine(timeout)
                hasher.combine(message)
            case let .requestCancelled(reason):
                hasher.combine(reason)
        }
    }
}
