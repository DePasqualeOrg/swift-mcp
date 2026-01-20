import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import ServiceLifecycle

@testable import MCP

/// A minimal HTTP server for integration testing.
/// Uses Hummingbird to accept connections and routes requests to HTTPServerTransport.
actor TestHTTPServer {
    private let transport: HTTPServerTransport
    private let serviceGroup: ServiceGroup
    private let serverPort: Int
    private let serverTask: Task<Void, Error>

    /// The actual port the server is listening on.
    var port: UInt16 {
        UInt16(serverPort)
    }

    /// The base URL for this test server (e.g., "http://127.0.0.1:8080")
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(serverPort)")!
    }

    /// Creates a test HTTP server on a random available port.
    private init(transport: HTTPServerTransport, serviceGroup: ServiceGroup, port: Int, serverTask: Task<Void, Error>) {
        self.transport = transport
        self.serviceGroup = serviceGroup
        serverPort = port
        self.serverTask = serverTask
    }

    /// Creates and starts a test HTTP server with default transport options.
    static func create(
        sessionIdGenerator: (@Sendable () -> String)? = nil,
        onSessionInitialized: (@Sendable (String) async -> Void)? = nil,
        onSessionClosed: (@Sendable (String) async -> Void)? = nil
    ) async throws -> TestHTTPServer {
        let transport = HTTPServerTransport(
            options: .init(
                sessionIdGenerator: sessionIdGenerator,
                onSessionInitialized: onSessionInitialized,
                onSessionClosed: onSessionClosed,
                dnsRebindingProtection: .localhost() // URLSession sets Host header automatically
            )
        )
        try await transport.connect()

        // Create router with MCP endpoint - handle all HTTP methods
        let router = Router()

        // Handle POST requests
        router.post("/") { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }

        // Handle GET requests (for SSE streams)
        router.get("/") { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }

        // Handle DELETE requests (for session termination)
        router.delete("/") { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }

        // Handle OPTIONS, PUT, PATCH - for testing unsupported methods
        router.on("/", method: .options) { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }
        router.on("/", method: .put) { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }
        router.on("/", method: .patch) { request, _ -> Hummingbird.Response in
            let mcpRequest = try await Self.convertRequest(request)
            let mcpResponse = await transport.handleRequest(mcpRequest)
            return Self.convertResponse(mcpResponse)
        }

        // Use a promise to capture the port when the server starts
        let portPromise = PortPromise()

        // Create app with random port (0)
        var logger = Logger(label: "test-http-server")
        logger.logLevel = .error // Suppress noise during tests

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                await portPromise.fulfill(with: channel.localAddress?.port ?? 0)
            },
            logger: logger
        )

        // Create service group for graceful shutdown
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [app],
                gracefulShutdownSignals: [],
                logger: logger
            )
        )

        // Start server in background task
        let serverTask = Task {
            try await serviceGroup.run()
        }

        // Wait for server to be ready
        let port = await portPromise.wait()
        guard port > 0 else {
            serverTask.cancel()
            throw TestHTTPServerError.failedToBind
        }

        return TestHTTPServer(
            transport: transport,
            serviceGroup: serviceGroup,
            port: port,
            serverTask: serverTask
        )
    }

    /// Stops the server.
    func stop() async {
        await serviceGroup.triggerGracefulShutdown()
        serverTask.cancel()
        await transport.disconnect()
    }

    // MARK: - Request/Response Conversion

    private static func convertRequest(_ request: Hummingbird.Request) async throws -> MCP.HTTPRequest {
        var headers: [String: String] = [:]
        for header in request.headers {
            headers[header.name.rawName] = header.value
        }

        // HTTPTypes stores Host header separately in the authority property
        // (HTTP/2 uses :authority pseudo-header instead of Host)
        if let authority = request.head.authority {
            headers["Host"] = authority
        }

        let body: Data?
        let collected = try await request.body.collect(upTo: 10 * 1024 * 1024) // 10MB limit
        if collected.readableBytes > 0 {
            body = Data(buffer: collected)
        } else {
            body = nil
        }

        return MCP.HTTPRequest(
            method: request.method.rawValue,
            headers: headers,
            body: body
        )
    }

    private static func convertResponse(_ response: MCP.HTTPResponse) -> Hummingbird.Response {
        var headers = HTTPFields()
        for (key, value) in response.headers {
            if let name = HTTPField.Name(key) {
                headers.append(HTTPField(name: name, value: value))
            }
        }

        let status = HTTPTypes.HTTPResponse.Status(code: response.statusCode)
        let body = if let bodyData = response.body {
            ResponseBody(byteBuffer: ByteBuffer(data: bodyData))
        } else {
            ResponseBody()
        }

        return Hummingbird.Response(status: status, headers: headers, body: body)
    }
}

// MARK: - Promise for Port

private actor PortPromise {
    private var port: Int?
    private var continuations: [CheckedContinuation<Int, Never>] = []

    func fulfill(with port: Int) {
        self.port = port
        for continuation in continuations {
            continuation.resume(returning: port)
        }
        continuations.removeAll()
    }

    func wait() async -> Int {
        if let port {
            return port
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

enum TestHTTPServerError: Error {
    case failedToBind
    case invalidResponse
}

// MARK: - URLSession Test Helpers

extension TestHTTPServer {
    /// Makes a POST request to this test server using URLSession.
    func post(
        body: String,
        sessionId: String? = nil,
        protocolVersion: String = Version.v2024_11_05
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)

        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: HTTPHeader.sessionId)
        }

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestHTTPServerError.invalidResponse
        }

        return (data, httpResponse)
    }

    /// Makes a GET request to this test server using URLSession.
    func get(
        sessionId: String,
        protocolVersion: String = Version.v2024_11_05
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestHTTPServerError.invalidResponse
        }

        return (data, httpResponse)
    }

    /// Makes a DELETE request to this test server using URLSession.
    func delete(
        sessionId: String,
        protocolVersion: String = Version.v2024_11_05
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "DELETE"
        request.setValue(sessionId, forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestHTTPServerError.invalidResponse
        }

        return (data, httpResponse)
    }

    /// Makes a custom request to this test server using URLSession.
    /// Use this for testing edge cases like missing headers, wrong content types, etc.
    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestHTTPServerError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// Makes a custom method request (PUT, PATCH, etc.) to this test server.
    func customMethod(
        _ method: String,
        body: String? = nil,
        sessionId: String? = nil,
        protocolVersion: String = Version.v2024_11_05
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)

        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: HTTPHeader.sessionId)
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
        }

        return try await self.request(request)
    }
}
