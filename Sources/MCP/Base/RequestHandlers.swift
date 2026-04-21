// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

// MARK: - Any Request Bridge

extension AnyRequest {
    /// Encode a concrete typed `Request<M>` into an `AnyRequest` by round-tripping
    /// through JSON. Used inside the MCP runtime when forwarding typed requests
    /// through type-erased handler queues.
    init(_ request: Request<some MCPCore.Method>) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        self = try decoder.decode(AnyRequest.self, from: data)
    }
}

// MARK: - Server Request Handlers

/// A box for request handlers that can be type-erased.
///
/// This class uses `@unchecked Sendable` because Swift cannot automatically infer
/// `Sendable` for non-final classes. However, this is safe because:
/// - The only subclass (`TypedRequestHandler`) stores only an immutable `@Sendable` closure
/// - No mutable state exists in either class after initialization
/// - The closure is `let` and marked `@Sendable`
class RequestHandlerBox: @unchecked Sendable {
    func callAsFunction(_: AnyRequest, context _: RequestHandlerContext) async throws -> AnyResponse {
        fatalError("Must override")
    }
}

/// A typed request handler that can be used to handle requests of a specific type.
///
/// See `RequestHandlerBox` for why `@unchecked Sendable` is safe here.
final class TypedRequestHandler<M: MCPCore.Method>: RequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (Request<M>, RequestHandlerContext) async throws -> Response<M>

    init(_ handler: @escaping @Sendable (Request<M>, RequestHandlerContext) async throws -> Response<M>) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: RequestHandlerContext) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Create a concrete request from the type-erased one
        let data = try encoder.encode(request)
        let request = try decoder.decode(Request<M>.self, from: data)

        // Handle with concrete type
        let response = try await _handle(request, context)

        // Convert result to AnyMethod response
        switch response.result {
            case let .success(result):
                let resultData = try encoder.encode(result)
                let resultValue = try decoder.decode(Value.self, from: resultData)
                return Response(id: response.id, result: resultValue)
            case let .failure(error):
                return Response(id: response.id, error: error)
        }
    }
}

/// A request handler that works directly with type-erased requests.
///
/// Used for fallback handlers that need to handle any request method.
/// See `RequestHandlerBox` for why `@unchecked Sendable` is safe here.
final class AnyRequestHandler: RequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (AnyRequest, RequestHandlerContext) async throws -> AnyResponse

    init(_ handler: @escaping @Sendable (AnyRequest, RequestHandlerContext) async throws -> AnyResponse) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: RequestHandlerContext) async throws -> AnyResponse {
        try await _handle(request, context)
    }
}

// MARK: - Notification Handlers

/// A box for notification handlers that can be type-erased.
///
/// This class uses `@unchecked Sendable` because Swift cannot automatically infer
/// `Sendable` for non-final classes. However, this is safe because:
/// - The only subclass (`TypedNotificationHandler`) stores only an immutable `@Sendable` closure
/// - No mutable state exists in either class after initialization
/// - The closure is `let` and marked `@Sendable`
class NotificationHandlerBox: @unchecked Sendable {
    func callAsFunction(_: Message<AnyNotification>) async throws {}
}

/// A typed notification handler that can be used to handle notifications of a specific type.
///
/// See `NotificationHandlerBox` for why `@unchecked Sendable` is safe here.
final class TypedNotificationHandler<N: MCPCore.Notification>: NotificationHandlerBox,
    @unchecked Sendable
{
    private let _handle: @Sendable (Message<N>) async throws -> Void

    init(_ handler: @escaping @Sendable (Message<N>) async throws -> Void) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ notification: Message<AnyNotification>) async throws {
        // Create a concrete notification from the type-erased one
        let data = try JSONEncoder().encode(notification)
        let typedNotification = try JSONDecoder().decode(Message<N>.self, from: data)

        try await _handle(typedNotification)
    }
}

// MARK: - Client Request Handlers

/// A box for client request handlers that can be type-erased.
///
/// This class uses `@unchecked Sendable` because Swift cannot automatically infer
/// `Sendable` for non-final classes. However, this is safe because:
/// - The only subclass (`TypedClientRequestHandler`) stores only an immutable `@Sendable` closure
/// - No mutable state exists in either class after initialization
/// - The closure is `let` and marked `@Sendable`
class ClientRequestHandlerBox: @unchecked Sendable {
    func callAsFunction(_: AnyRequest, context _: RequestHandlerContext) async throws -> AnyResponse {
        fatalError("Must override")
    }
}

/// A typed client request handler that can be used to handle requests of a specific type.
///
/// See `ClientRequestHandlerBox` for why `@unchecked Sendable` is safe here.
final class TypedClientRequestHandler<M: MCPCore.Method>: ClientRequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result

    init(_ handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: RequestHandlerContext) async throws -> AnyResponse {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Create a concrete request from the type-erased one
        let data = try encoder.encode(request)
        let typedRequest = try decoder.decode(Request<M>.self, from: data)

        // Handle with concrete type
        do {
            let result = try await _handle(typedRequest.params, context)

            // Convert result to AnyMethod response
            let resultData = try encoder.encode(result)
            let resultValue = try decoder.decode(Value.self, from: resultData)
            return Response(id: typedRequest.id, result: resultValue)
        } catch let error as MCPError {
            return Response(id: typedRequest.id, error: error)
        } catch {
            // Sanitize non-MCP errors to avoid leaking internal details
            return Response(id: typedRequest.id, error: MCPError.internalError("An internal error occurred"))
        }
    }
}

/// A client request handler that works directly with type-erased requests.
///
/// Used for fallback handlers that need to handle any request method.
/// See `ClientRequestHandlerBox` for why `@unchecked Sendable` is safe here.
final class AnyClientRequestHandler: ClientRequestHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (AnyRequest, RequestHandlerContext) async throws -> AnyResponse

    init(_ handler: @escaping @Sendable (AnyRequest, RequestHandlerContext) async throws -> AnyResponse) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ request: AnyRequest, context: RequestHandlerContext) async throws -> AnyResponse {
        try await _handle(request, context)
    }
}

/// A notification handler that works directly with type-erased notifications.
///
/// Used for fallback handlers that need to handle any notification method.
/// See `NotificationHandlerBox` for why `@unchecked Sendable` is safe here.
final class AnyNotificationHandler: NotificationHandlerBox, @unchecked Sendable {
    private let _handle: @Sendable (Message<AnyNotification>) async throws -> Void

    init(_ handler: @escaping @Sendable (Message<AnyNotification>) async throws -> Void) {
        _handle = handler
        super.init()
    }

    override func callAsFunction(_ notification: Message<AnyNotification>) async throws {
        try await _handle(notification)
    }
}
