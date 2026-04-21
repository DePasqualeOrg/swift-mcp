// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let jsonrpc = "2.0"

public protocol NotRequired {
    init()
}

public struct Empty: NotRequired, Hashable, Codable, Sendable {
    public init() {}
}

/// Base notification parameters with optional metadata.
///
/// Used by notifications that have no additional parameters beyond `_meta`.
public struct NotificationParams: NotRequired, Hashable, Codable, Sendable {
    /// Reserved for additional metadata.
    public var _meta: [String: Value]?

    public init() {
        _meta = nil
    }

    public init(_meta: [String: Value]?) {
        self._meta = _meta
    }
}

extension Value: NotRequired {
    public init() {
        self = .null
    }
}

// MARK: -

/// A method that can be used to send requests and receive responses.
public protocol Method: Sendable {
    /// The parameters of the method.
    associatedtype Parameters: Codable, Hashable, Sendable = Empty
    /// The result of the method.
    associatedtype Result: Codable, Hashable, Sendable = Empty
    /// The name of the method.
    static var name: String { get }
}

/// Type-erased method for request/response handling.
public struct AnyMethod: Method, Sendable {
    public static var name: String {
        ""
    }

    public typealias Parameters = Value
    public typealias Result = Value
}

public extension Method where Parameters == Empty {
    static func request(id: RequestId = .random) -> Request<Self> {
        Request(id: id, method: name, params: Empty())
    }
}

public extension Method where Parameters: NotRequired {
    /// Create a request with default parameters.
    static func request(id: RequestId = .random) -> Request<Self> {
        Request(id: id, method: name, params: Parameters())
    }
}

public extension Method where Result == Empty {
    static func response(id: RequestId) -> Response<Self> {
        Response(id: id, result: Empty())
    }
}

public extension Method {
    /// Create a request with the given parameters.
    static func request(id: RequestId = .random, _ parameters: Self.Parameters) -> Request<Self> {
        Request(id: id, method: name, params: parameters)
    }

    /// Create a response with the given result.
    static func response(id: RequestId, result: Self.Result) -> Response<Self> {
        Response(id: id, result: result)
    }

    /// Create a response with the given error.
    static func response(id: RequestId, error: MCPError) -> Response<Self> {
        Response(id: id, error: error)
    }
}

// MARK: -

/// A request message.
public struct Request<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The request ID.
    public let id: RequestId
    /// The method name.
    public let method: String
    /// The request parameters.
    public let params: M.Parameters

    public init(id: RequestId = .random, method: String, params: M.Parameters) {
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }
}

public extension Request {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version",
            )
        }
        id = try container.decode(ID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)

        if M.Parameters.self is NotRequired.Type {
            // For NotRequired parameters, use decodeIfPresent or init()
            if let decoded = try container.decodeIfPresent(M.Parameters.self, forKey: .params) {
                params = decoded
            } else if let notRequiredType = M.Parameters.self as? NotRequired.Type,
                      let defaultValue = notRequiredType.init() as? M.Parameters
            {
                params = defaultValue
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Failed to create default NotRequired parameters",
                    ),
                )
            }
        } else if let value = try? container.decode(M.Parameters.self, forKey: .params) {
            // If params exists and can be decoded, use it
            params = value
        } else if !container.contains(.params)
            || (try? container.decodeNil(forKey: .params)) == true
        {
            // If params is missing or explicitly null, use Empty for Empty parameters
            // or throw for non-Empty parameters
            if let emptyValue = Empty() as? M.Parameters {
                params = emptyValue
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Missing required params field",
                    ),
                )
            }
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid params field",
                ),
            )
        }
    }
}

/// A type-erased request for request/response handling.
public typealias AnyRequest = Request<AnyMethod>

// The `AnyRequest(Request<some Method>)` convenience initializer lives in the
// MCP runtime target alongside other type-erasure helpers. See
// `Sources/MCP/Base/RequestHandlers.swift`.

// Request handler type-erasure infrastructure (RequestHandlerBox,
// TypedRequestHandler, AnyRequestHandler) is defined in the MCP runtime target
// because it references `RequestHandlerContext` (which carries I/O-specific
// types like `AuthInfo`). See `Sources/MCP/Base/RequestHandlers.swift`.

// MARK: -

/// A response message.
///
/// The `id` is optional to support JSON-RPC error responses with null or missing `id`,
/// as allowed by the MCP schema (where `id` is not a required field on `JSONRPCErrorResponse`).
public struct Response<M: Method>: Hashable, Identifiable, Codable, Sendable {
    /// The response ID, or `nil` for error responses with null/missing `id`.
    public let id: RequestId?
    /// The response result.
    public let result: Swift.Result<M.Result, MCPError>

    public init(id: RequestId?, result: M.Result) {
        self.id = id
        self.result = .success(result)
    }

    public init(id: RequestId?, error: MCPError) {
        self.id = id
        result = .failure(error)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        switch result {
            case let .success(result):
                try container.encode(result, forKey: .result)
            case let .failure(error):
                try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version",
            )
        }
        id = try container.decodeIfPresent(RequestId.self, forKey: .id)
        if let result = try? container.decode(M.Result.self, forKey: .result) {
            self.result = .success(result)
        } else if let error = try? container.decode(MCPError.self, forKey: .error) {
            result = .failure(error)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid response",
                ),
            )
        }
    }
}

/// A type-erased response for response handling.
public typealias AnyResponse = Response<AnyMethod>

public extension AnyResponse {
    init(_ response: Response<some Method>) throws {
        id = response.id
        switch response.result {
            case let .success(result):
                let data = try JSONEncoder().encode(result)
                let resultValue = try JSONDecoder().decode(Value.self, from: data)
                self.result = .success(resultValue)
            case let .failure(error):
                result = .failure(error)
        }
    }
}

// MARK: -

/// A notification message.
public protocol Notification: Hashable, Codable, Sendable {
    /// The parameters of the notification.
    associatedtype Parameters: Hashable, Codable, Sendable = Empty
    /// The name of the notification.
    static var name: String { get }
}

/// A type-erased notification for message handling.
public struct AnyNotification: Notification, Sendable {
    public static var name: String {
        ""
    }

    public typealias Parameters = Value
}

/// Protocol for type-erased notification messages.
///
/// This protocol allows sending notification messages with parameters through
/// a type-erased interface. `Message<N>` conforms to this protocol.
public protocol NotificationMessageProtocol: Sendable, Encodable {
    /// The notification method name.
    var method: String { get }
}

/// A message that can be used to send notifications.
public struct Message<N: Notification>: NotificationMessageProtocol, Hashable, Codable, Sendable {
    /// The method name.
    public let method: String
    /// The notification parameters.
    public let params: N.Parameters

    public init(method: String, params: N.Parameters) {
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        if N.Parameters.self != Empty.self {
            try container.encode(params, forKey: .params)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .jsonrpc)
        guard version == jsonrpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version",
            )
        }
        method = try container.decode(String.self, forKey: .method)

        if N.Parameters.self is NotRequired.Type {
            // For NotRequired parameters, use decodeIfPresent or init()
            if let decoded = try container.decodeIfPresent(N.Parameters.self, forKey: .params) {
                params = decoded
            } else if let notRequiredType = N.Parameters.self as? NotRequired.Type,
                      let defaultValue = notRequiredType.init() as? N.Parameters
            {
                params = defaultValue
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Failed to create default NotRequired parameters",
                    ),
                )
            }
        } else if let value = try? container.decode(N.Parameters.self, forKey: .params) {
            // If params exists and can be decoded, use it
            params = value
        } else if !container.contains(.params)
            || (try? container.decodeNil(forKey: .params)) == true
        {
            // If params is missing or explicitly null, use Empty for Empty parameters
            // or throw for non-Empty parameters
            if let emptyValue = Empty() as? N.Parameters {
                params = emptyValue
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Missing required params field",
                    ),
                )
            }
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid params field",
                ),
            )
        }
    }
}

/// A type-erased message for message handling.
public typealias AnyMessage = Message<AnyNotification>

public extension Notification where Parameters == Empty {
    /// Create a message with empty parameters.
    static func message() -> Message<Self> {
        Message(method: name, params: Empty())
    }
}

public extension Notification where Parameters == NotificationParams {
    /// Create a message with default parameters (no metadata).
    static func message() -> Message<Self> {
        Message(method: name, params: NotificationParams())
    }
}

public extension Notification {
    /// Create a message with the given parameters.
    static func message(_ parameters: Parameters) -> Message<Self> {
        Message(method: name, params: parameters)
    }
}

// Notification / client-request handler type-erasure infrastructure is defined
// in the MCP runtime target because it references `RequestHandlerContext`. See
// `Sources/MCP/Base/RequestHandlers.swift`.
