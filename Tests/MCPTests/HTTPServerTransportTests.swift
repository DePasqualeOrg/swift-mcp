// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

// MARK: - Test Helpers

/// Creates an HTTPServerTransport configured for testing with DNS rebinding protection disabled.
/// Most tests don't send Host headers, so they need protection disabled to avoid 421 errors.
private func testTransport(
    sessionIdGenerator: (@Sendable () -> String)? = nil,
    onSessionInitialized: (@Sendable (String) async -> Void)? = nil,
    onSessionClosed: (@Sendable (String) async -> Void)? = nil,
    enableJsonResponse: Bool = false,
    eventStore: EventStore? = nil,
    retryInterval: Int? = nil,
    sessionIdleTimeout: Duration? = nil,
) -> HTTPServerTransport {
    HTTPServerTransport(
        options: .init(
            sessionIdGenerator: sessionIdGenerator,
            onSessionInitialized: onSessionInitialized,
            onSessionClosed: onSessionClosed,
            enableJsonResponse: enableJsonResponse,
            eventStore: eventStore,
            retryInterval: retryInterval,
            dnsRebindingProtection: .none,
            sessionIdleTimeout: sessionIdleTimeout,
        ),
    )
}

struct HTTPServerTransportTests {
    // MARK: - Basic Initialization

    @Test
    func `Stateless mode initialization`() async {
        let transport = testTransport()

        // Should not have a session ID in stateless mode
        let sessionId = await transport.sessionId
        #expect(sessionId == nil)
    }

    @Test
    func `Stateful mode initialization`() async {
        let transport = testTransport(sessionIdGenerator: { UUID().uuidString })

        // Session ID not generated until initialize request
        let sessionId = await transport.sessionId
        #expect(sessionId == nil)
    }

    @Test
    func `Stateless mode does not support server-to-client requests`() async {
        let transport = testTransport()

        let supportsRequests = await transport.supportsServerToClientRequests
        #expect(supportsRequests == false)
    }

    @Test
    func `Stateful mode supports server-to-client requests`() async {
        let transport = testTransport(sessionIdGenerator: { UUID().uuidString })

        let supportsRequests = await transport.supportsServerToClientRequests
        #expect(supportsRequests == true)
    }

    // MARK: - POST Request Handling

    @Test
    func `POST requires correct Accept header`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Missing text/event-stream in Accept header
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"initialize","id":"1"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
    }

    @Test
    func `POST requires Content-Type`() async throws {
        let transport = testTransport()
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
            ],
            body: #"{"jsonrpc":"2.0","method":"initialize","id":"1"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 415)
    }

    @Test
    func `POST with valid initialize request`() async throws {
        let transport = testTransport()
        try await transport.connect()

        let initializeRequest =
            TestPayloads.initializeRequest()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: initializeRequest.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
        #expect(response.headers[HTTPHeader.contentType] == "text/event-stream")
    }

    @Test
    func `POST with notification only returns 202`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Then send a notification (no id field)
        let notificationRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(notificationRequest)
        #expect(response.statusCode == 202)
    }

    @Test
    func `POST with batch notifications returns 202`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send batch of notifications (no id fields) - should return 202
        let batchNotificationsRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            #"[{"jsonrpc":"2.0","method":"notifications/someNotification1","params":{}},{"jsonrpc":"2.0","method":"notifications/someNotification2","params":{}}]"#
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(batchNotificationsRequest)
        #expect(response.statusCode == 202)
    }

    @Test
    func `POST with invalid JSON returns parse error`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send invalid JSON
        let invalidJsonRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: "This is not valid JSON".data(using: .utf8),
        )

        let response = await transport.handleRequest(invalidJsonRequest)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC parse error
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)") || text.lowercased().contains("parse"))
        }
    }

    @Test
    func `POST with invalid JSON-RPC format returns error`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // First initialize the transport
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send message missing jsonrpc version (invalid JSON-RPC format)
        let invalidFormatRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(invalidFormatRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - Session Management

    @Test
    func `Stateful mode generates session ID`() async throws {
        actor SessionStore {
            var sessionId: String?
            func set(_ id: String) {
                sessionId = id
            }

            func get() -> String? {
                sessionId
            }
        }
        let store = SessionStore()
        let expectedSessionId = "test-session-123"

        let transport = testTransport(
            sessionIdGenerator: { expectedSessionId },
            onSessionInitialized: { sessionId in
                await store.set(sessionId)
            },
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.sessionId] == expectedSessionId)

        let generatedSessionId = await store.get()
        #expect(generatedSessionId == expectedSessionId)

        let actualSessionId = await transport.sessionId
        #expect(actualSessionId == expectedSessionId)
    }

    @Test
    func `Stateful mode rejects invalid session ID`() async throws {
        let transport = testTransport(sessionIdGenerator: { "valid-session" })
        try await transport.connect()

        // First initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Then try with wrong session ID
        let badRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "wrong-session",
            ],
            body:
            #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(badRequest)
        #expect(response.statusCode == 404)
    }

    @Test
    func `Stateful mode requires session ID after init`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Try without session ID
        let noSessionRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(noSessionRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - GET Request Handling

    @Test
    func `GET requires Accept header`() async throws {
        let transport = testTransport()
        try await transport.connect()

        let request = HTTPRequest(method: "GET", headers: [:])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 406)
    }

    @Test
    func `GET returns SSE stream`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first (stateless mode - no session required)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        let request = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "text/event-stream")
        #expect(response.stream != nil)
    }

    @Test
    func `GET rejects multiple SSE streams`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // First GET
        let request1 = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response1 = await transport.handleRequest(request1)
        #expect(response1.statusCode == 200)

        // Second GET - should fail
        let request2 = HTTPRequest(method: "GET", headers: [HTTPHeader.accept: "text/event-stream"])
        let response2 = await transport.handleRequest(request2)
        #expect(response2.statusCode == 409)
    }

    // MARK: - DELETE Request Handling

    @Test
    func `DELETE closes session`() async throws {
        actor ClosedState {
            var closed = false
            func markClosed() {
                closed = true
            }

            func isClosed() -> Bool {
                closed
            }
        }
        let state = ClosedState()

        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            onSessionClosed: { _ in await state.markClosed() },
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"],
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 200)
        let sessionClosed = await state.isClosed()
        #expect(sessionClosed == true)
    }

    @Test
    func `DELETE in stateless mode returns 405`() async throws {
        // Stateless mode (no session ID generator)
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE should return 405 in stateless mode (no session to terminate)
        let deleteRequest = HTTPRequest(method: "DELETE", headers: [:])
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeader.allow] == "GET, POST")

        // Verify it's a proper JSON-RPC error
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Session management is not enabled") || text.contains("Method Not Allowed"))
        }
    }

    @Test
    func `Session terminated - requests return 404`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE to terminate session
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"],
        )
        let deleteResponse = await transport.handleRequest(deleteRequest)
        #expect(deleteResponse.statusCode == 200)

        // Try to use the terminated session - should return 404
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // GET with terminated session should also return 404
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ],
        )
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 404)
    }

    // MARK: - Unsupported Methods

    @Test
    func `Unsupported method returns 405`() async throws {
        let transport = testTransport()
        try await transport.connect()

        let request = HTTPRequest(method: "PUT", headers: [:])
        let response = await transport.handleRequest(request)

        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeader.allow] == "GET, POST, DELETE")
    }

    // MARK: - Protocol Version Validation

    @Test
    func `Rejects unsupported protocol version`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Then try with unsupported version
        let badRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.protocolVersion: "1999-01-01",
            ],
            body:
            #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(badRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - JSON Response Mode

    @Test
    func `JSON response mode only requires application/json Accept header`() async throws {
        let transport = testTransport(enableJsonResponse: true)
        try await transport.connect()

        // Should succeed with only application/json (no text/event-stream required)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json", // Only JSON, no SSE
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        // Start a task to send the response
        Task {
            try await Task.sleep(for: .milliseconds(50))
            let responseData =
                TestPayloads.initializeResult()
                    .data(using: .utf8)!
            try await transport.send(responseData, options: TransportSendOptions(relatedRequestId: .string("1")))
        }

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
    }

    @Test
    func `JSON response mode rejects request without application/json Accept header`() async throws {
        let transport = testTransport(enableJsonResponse: true)
        try await transport.connect()

        // Should fail without application/json
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "text/plain",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
    }

    @Test
    func `SSE mode requires both Accept types`() async throws {
        let transport = testTransport(enableJsonResponse: false) // SSE mode (default)
        try await transport.connect()

        // Should fail with only application/json (missing text/event-stream)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json", // Missing text/event-stream
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 406)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("both"))
        }
    }

    @Test
    func `JSON response mode returns JSON`() async throws {
        let transport = testTransport(enableJsonResponse: true)
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        // Start a task to send the response
        Task {
            // Wait a bit for the request to be processed
            try await Task.sleep(for: .milliseconds(50))

            // Send a response
            let responseData =
                TestPayloads.initializeResult()
                    .data(using: .utf8)!
            try await transport.send(responseData, options: TransportSendOptions(relatedRequestId: .string("1")))
        }

        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
        #expect(response.body != nil)
        #expect(response.stream == nil)
    }

    // MARK: - Multiple Initialize Rejection

    @Test
    func `Rejects double initialize`() async throws {
        let transport = testTransport(sessionIdGenerator: { UUID().uuidString })
        try await transport.connect()

        // First initialize
        let initRequest1 = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        let response1 = await transport.handleRequest(initRequest1)
        #expect(response1.statusCode == 200)

        let sessionId = try #require(response1.headers[HTTPHeader.sessionId])

        // Second initialize - should fail
        let initRequest2 = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: sessionId,
            ],
            body:
            TestPayloads.initializeRequest(id: "2")
                .data(using: .utf8),
        )
        let response2 = await transport.handleRequest(initRequest2)
        #expect(response2.statusCode == 400)
    }

    // MARK: - DNS Rebinding Protection

    @Test
    func `DNS rebinding protection allows valid host`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test
    func `DNS rebinding protection rejects invalid host`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "evil.com:8080",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        // 421 Misdirected Request for invalid Host
        #expect(response.statusCode == 421)
    }

    @Test
    func `DNS rebinding protection rejects missing host`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                // No Host header
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        // 421 Misdirected Request for missing Host
        #expect(response.statusCode == 421)
    }

    @Test
    func `DNS rebinding protection allows wildcard port`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost()), // Wildcard port
        )
        try await transport.connect()

        // Test with various ports
        for port in [8080, 3000, 9999] {
            let request = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                    HTTPHeader.host: "127.0.0.1:\(port)",
                ],
                body:
                TestPayloads.initializeRequest()
                    .data(using: .utf8),
            )

            let response = await transport.handleRequest(request)
            // First request succeeds (200), subsequent ones fail (400) because already initialized
            #expect(response.statusCode == 200 || response.statusCode == 400)
        }
    }

    @Test
    func `DNS rebinding protection allows valid origin`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                HTTPHeader.origin: "http://localhost:8080",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test
    func `DNS rebinding protection rejects invalid origin`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                HTTPHeader.origin: "http://evil.com",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 403)
    }

    @Test
    func `DNS rebinding protection allows request without origin`() async throws {
        // Non-browser clients (like curl) don't send Origin header
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
                // No Origin header
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test
    func `DNS rebinding protection can be disabled with .none`() async throws {
        // With .none, any host should be allowed
        let transport = testTransport() // Uses dnsRebindingProtection: .none
        try await transport.connect()

        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "any-host.com:8080",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    @Test
    func `DNS rebinding protection enabled by default`() async throws {
        // Default is .localhost() - should reject requests without valid Host header
        let transport = HTTPServerTransport()
        try await transport.connect()

        // Request without Host header should be rejected
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                // No Host header
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 421) // Misdirected Request
    }

    @Test
    func `forBindAddress returns appropriate protection for address`() {
        // Should return .localhost for localhost addresses
        let localhost1 = DNSRebindingProtection.forBindAddress(host: "127.0.0.1", port: 8080)
        #expect(localhost1.isEnabled == true)

        let localhost2 = DNSRebindingProtection.forBindAddress(host: "localhost", port: 3000)
        #expect(localhost2.isEnabled == true)

        let localhost3 = DNSRebindingProtection.forBindAddress(host: "::1", port: 9000)
        #expect(localhost3.isEnabled == true)

        // Should return .none for other addresses (cloud deployments)
        let wildcard = DNSRebindingProtection.forBindAddress(host: "0.0.0.0", port: 8080)
        #expect(wildcard.isEnabled == false)

        let privateAddr = DNSRebindingProtection.forBindAddress(host: "192.168.1.1", port: 8080)
        #expect(privateAddr.isEnabled == false)
    }

    @Test
    func `HTTPServerTransportOptions.forBindAddress auto-configures protection`() {
        // For localhost, should auto-enable DNS rebinding protection
        let localhostOptions = HTTPServerTransportOptions.forBindAddress(host: "127.0.0.1", port: 8080)
        #expect(localhostOptions.dnsRebindingProtection.isEnabled == true)
        #expect(localhostOptions.dnsRebindingProtection.allowedHosts.contains("127.0.0.1:8080") == true)

        // For 0.0.0.0, should disable protection (cloud deployment)
        let wildcardOptions = HTTPServerTransportOptions.forBindAddress(host: "0.0.0.0", port: 8080)
        #expect(wildcardOptions.dnsRebindingProtection.isEnabled == false)

        // Should allow explicit protection override
        let customProtection = DNSRebindingProtection.custom(
            allowedHosts: ["custom.local:8080"],
            allowedOrigins: ["http://custom.local:8080"],
        )
        let overriddenOptions = HTTPServerTransportOptions.forBindAddress(
            host: "127.0.0.1",
            port: 8080,
            dnsRebindingProtection: customProtection,
        )
        #expect(overriddenOptions.dnsRebindingProtection.allowedHosts.contains("custom.local:8080") == true)
        #expect(overriddenOptions.dnsRebindingProtection.allowedHosts.contains("127.0.0.1:8080") == false)
    }

    @Test
    func `DNS rebinding protection rejects invalid host on GET`() async throws {
        let transport = HTTPServerTransport(
            options: .init(dnsRebindingProtection: .localhost(port: 8080)),
        )
        try await transport.connect()

        // Initialize first with valid host
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.host: "localhost:8080",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // GET with invalid host
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.host: "evil.com:8080",
            ],
        )
        let response = await transport.handleRequest(getRequest)
        #expect(response.statusCode == 421)
    }

    // MARK: - Protocol Version on GET/DELETE

    @Test
    func `Rejects unsupported protocol version on GET`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // GET with unsupported protocol version
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: "1999-01-01",
            ],
        )
        let response = await transport.handleRequest(getRequest)
        #expect(response.statusCode == 400)
    }

    @Test
    func `Rejects unsupported protocol version on DELETE`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE with unsupported protocol version
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: "1999-01-01",
            ],
        )
        let response = await transport.handleRequest(deleteRequest)
        #expect(response.statusCode == 400)
    }

    @Test
    func `Accepts requests without protocol version header`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Request without protocol version header should work
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                // No protocol version header
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )
        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 200)
    }

    // MARK: - Session Closed Callback Edge Cases

    @Test
    func `Session closed callback not called for invalid session`() async throws {
        actor CallbackState {
            var called = false
            func markCalled() {
                called = true
            }

            func wasCalled() -> Bool {
                called
            }
        }
        let state = CallbackState()

        let transport = testTransport(
            sessionIdGenerator: { "valid-session" },
            onSessionClosed: { _ in await state.markCalled() },
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Try to DELETE with invalid session ID
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "invalid-session"],
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 404)
        let called = await state.wasCalled()
        #expect(called == false) // Callback should NOT be called for invalid session
    }

    @Test
    func `DELETE without callback works`() async throws {
        // No onSessionClosed callback provided
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE should work without callback
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "test-session"],
        )
        let response = await transport.handleRequest(deleteRequest)
        #expect(response.statusCode == 200)
    }

    // MARK: - Batch Request Handling

    @Test
    func `Batch initialize request rejected`() async throws {
        let transport = testTransport(sessionIdGenerator: { UUID().uuidString })
        try await transport.connect()

        // Batch with initialize messages should be rejected
        let batchRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.batchRequest([
                TestPayloads.initializeRequest(id: "1"),
                TestPayloads.initializeRequest(id: "2", clientName: "test2"),
            ])
            .data(using: .utf8),
        )
        let response = await transport.handleRequest(batchRequest)
        #expect(response.statusCode == 400)
    }

    // MARK: - Uninitialized Server Handling

    @Test
    func `Rejects requests to uninitialized server`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Send a non-initialize request without first initializing
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"1"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC error with "not initialized"
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    @Test
    func `Rejects GET requests to uninitialized server`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Send a GET request without first initializing
        let request = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ],
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify it's a JSON-RPC error with "not initialized"
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    // MARK: - Stateless Mode

    @Test
    func `Stateless mode accepts requests with any session ID`() async throws {
        // No session ID generator = stateless mode
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // In stateless mode, requests with different session IDs should work
        for sessionId in ["session-1", "session-2", "random-id", ""] {
            var headers = [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ]
            if !sessionId.isEmpty {
                headers[HTTPHeader.sessionId] = sessionId
            }

            let request = HTTPRequest(
                method: "POST",
                headers: headers,
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8),
            )

            let response = await transport.handleRequest(request)
            // Notifications should return 202 regardless of session ID in stateless mode
            #expect(response.statusCode == 202)
        }
    }

    @Test
    func `Stateless mode allows request without session ID`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Request without session ID should work in stateless mode
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                // No session ID header
            ],
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 202)
    }

    @Test
    func `Stateless mode rejects requests before initialization`() async throws {
        // No session ID generator = stateless mode
        let transport = testTransport()
        try await transport.connect()

        // Try to send request without initializing first
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"1"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        // Verify error message mentions initialization
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    @Test
    func `Stateless mode rejects GET requests before initialization`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Try GET without initializing first
        let request = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"],
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)

        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.lowercased().contains("not initialized"))
        }
    }

    // MARK: - JSON-RPC Error Code Validation

    @Test
    func `Parse error returns -32700`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send invalid JSON
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: "not valid json".data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
        }
    }

    @Test
    func `Invalid request returns -32600`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send message missing jsonrpc version (invalid JSON-RPC format)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.invalidRequest)"))
        }
    }

    @Test
    func `Empty body returns parse error -32700`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send empty body
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: nil,
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
            #expect(text.contains("Empty request body"))
        }
    }

    @Test
    func `Valid JSON but not JSON-RPC array returns parse error`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send valid JSON but not a JSON-RPC message (not an object or array of objects)
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"["string", 123, true]"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.parseError)"))
        }
    }

    @Test
    func `Wrong jsonrpc version returns invalid request error`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send message with wrong jsonrpc version
        let request = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"1.0","method":"tools/list","params":{},"id":"2"}"#.data(using: .utf8),
        )

        let response = await transport.handleRequest(request)
        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("\(ErrorCode.invalidRequest)"))
            #expect(text.lowercased().contains("jsonrpc"))
        }
    }

    // MARK: - Session ID Validation Tests (per Python/TypeScript SDK patterns)

    @Test
    func `Valid session IDs accepted`() async throws {
        // Valid session IDs: visible ASCII (0x21-0x7E)
        let validSessionIds = [
            "test-session-id",
            "1234567890",
            "session!@#$%^&*()_+-=[]{}|;:,.<>?/",
            "~", // 0x7E
            "!", // 0x21
            UUID().uuidString,
        ]

        for validId in validSessionIds {
            let transport = testTransport(sessionIdGenerator: { validId })
            try await transport.connect()

            let initRequest = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                ],
                body:
                TestPayloads.initializeRequest()
                    .data(using: .utf8),
            )

            let response = await transport.handleRequest(initRequest)
            #expect(response.statusCode == 200, "Session ID '\(validId)' should be accepted")
            #expect(response.headers[HTTPHeader.sessionId] == validId)
        }
    }

    @Test
    func `Invalid session IDs rejected - space`() async throws {
        let transport = testTransport(sessionIdGenerator: { "session with space" })
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 500) // Internal error for invalid generated ID
    }

    @Test
    func `Invalid session IDs rejected - control characters`() async throws {
        let invalidIds = [
            "session\twith\ttab", // Tab (0x09)
            "session\nwith\nnewline", // Newline (0x0A)
            "session\rwith\rcarriage", // Carriage return (0x0D)
            "session\u{7F}with\u{7F}del", // DEL (0x7F)
            "session\u{00}with\u{00}null", // NULL (0x00)
        ]

        for invalidId in invalidIds {
            let transport = testTransport(sessionIdGenerator: { invalidId })
            try await transport.connect()

            let initRequest = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                ],
                body:
                TestPayloads.initializeRequest()
                    .data(using: .utf8),
            )

            let response = await transport.handleRequest(initRequest)
            #expect(response.statusCode == 500, "Session ID with control chars should be rejected")
        }
    }

    @Test
    func `Invalid session IDs rejected - empty string`() async throws {
        let transport = testTransport(sessionIdGenerator: { "" })
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 500) // Empty session ID is invalid
    }

    // MARK: - GET Priming Events Tests (per Python/TypeScript SDK patterns)

    @Test
    func `GET stream receives priming event with event store`() async throws {
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
        )
        try await transport.connect()

        // Initialize with protocol version that supports priming events
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should receive priming event
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
            ],
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)

        // Verify priming event was stored
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1) // At least one priming event
    }

    @Test
    func `GET stream does not receive priming event for old protocol version`() async throws {
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
        )
        try await transport.connect()

        // Initialize with old protocol version
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should NOT receive priming event for old protocol
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2024_11_05,
            ],
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)

        // No priming event for old protocol
        let eventCount = await eventStore.eventCount
        #expect(eventCount == 0)
    }

    @Test
    func `GET stream does not receive priming event without event store`() async throws {
        // No event store configured
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // GET request should still work but no priming event
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
            ],
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
    }

    @Test
    func `Priming event includes retry interval when configured`() async throws {
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
            retryInterval: 5000, // 5 seconds
        )
        try await transport.connect()

        // Initialize with new protocol version
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        let response = await transport.handleRequest(initRequest)

        #expect(response.statusCode == 200)
        #expect(response.stream != nil)

        // Read first event from stream to check for retry field
        if let stream = response.stream {
            var receivedData = Data()
            for try await chunk in stream {
                receivedData.append(chunk)
                break // Just get first chunk (priming event)
            }
            let eventString = String(data: receivedData, encoding: .utf8) ?? ""
            #expect(eventString.contains("retry: 5000"))
        }
    }

    // MARK: - Resumability Tests (per Python/TypeScript SDK patterns)

    @Test
    func `Event store stores events with unique IDs`() async throws {
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg1".utf8))
        let id2 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg2".utf8))
        let id3 = try await eventStore.storeEvent(streamId: "stream-2", message: Data("msg3".utf8))

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)

        let eventCount = await eventStore.eventCount
        #expect(eventCount == 3)
    }

    @Test
    func `Event store replays events after last event ID`() async throws {
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) {
                messages.append(text)
            }

            func getMessages() -> [String] {
                messages
            }
        }
        let collector = MessageCollector()
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg2".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("msg3".utf8))

        let replayedStreamId = try await eventStore.replayEventsAfter(id1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        let replayedMessages = await collector.getMessages()
        #expect(replayedStreamId == "stream-1")
        #expect(replayedMessages.count == 2) // msg2 and msg3, not msg1
        #expect(replayedMessages.contains("msg2"))
        #expect(replayedMessages.contains("msg3"))
        #expect(!replayedMessages.contains("msg1"))
    }

    @Test
    func `Event store only replays events from same stream`() async throws {
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) {
                messages.append(text)
            }

            func getMessages() -> [String] {
                messages
            }
        }
        let collector = MessageCollector()
        let eventStore = InMemoryEventStore()

        let id1 = try await eventStore.storeEvent(streamId: "stream-1", message: Data("stream1-msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-2", message: Data("stream2-msg1".utf8))
        _ = try await eventStore.storeEvent(streamId: "stream-1", message: Data("stream1-msg2".utf8))

        _ = try await eventStore.replayEventsAfter(id1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        let replayedMessages = await collector.getMessages()
        // Should only replay stream-1 messages after id1
        #expect(replayedMessages.count == 1)
        #expect(replayedMessages.contains("stream1-msg2"))
        #expect(!replayedMessages.contains("stream2-msg1"))
    }

    @Test
    func `GET with Last-Event-ID replays events`() async throws {
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Store some events directly
        let eventId = try await eventStore.storeEvent(
            streamId: "_GET_stream",
            message: Data(#"{"jsonrpc":"2.0","method":"test"}"#.utf8),
        )

        // GET with Last-Event-ID should trigger replay
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.lastEventId: eventId,
            ],
        )
        let response = await transport.handleRequest(getRequest)

        // Should return 200 with stream (replay mode)
        #expect(response.statusCode == 200)
        #expect(response.stream != nil)
    }

    // MARK: - Protocol Version Negotiation Tests

    @Test
    func `Protocol version stored after initialization`() async throws {
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
        )
        try await transport.connect()

        // Initialize with 2025-11-25
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Priming event should be stored (only for >= 2025-11-25)
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1)
    }

    // MARK: - Cache-Control Header Tests

    @Test
    func `POST SSE response has correct Cache-Control header`() async throws {
        let transport = testTransport()
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        let response = await transport.handleRequest(initRequest)
        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.cacheControl] == "no-cache, no-transform")
    }

    @Test
    func `GET SSE response has correct Cache-Control header`() async throws {
        let transport = testTransport()
        try await transport.connect()

        // Initialize first
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        let getRequest = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"],
        )
        let response = await transport.handleRequest(getRequest)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.cacheControl] == "no-cache, no-transform")
    }

    // MARK: - Session Callback Tests (per Python/TypeScript SDK patterns)

    @Test
    func `Session initialized callback called with session ID`() async throws {
        actor SessionTracker {
            var sessionId: String?
            func set(_ id: String) {
                sessionId = id
            }

            func get() -> String? {
                sessionId
            }
        }
        let tracker = SessionTracker()

        let transport = testTransport(
            sessionIdGenerator: { "callback-test-session" },
            onSessionInitialized: { sessionId in
                await tracker.set(sessionId)
            },
        )
        try await transport.connect()

        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )

        _ = await transport.handleRequest(initRequest)

        let capturedId = await tracker.get()
        #expect(capturedId == "callback-test-session")
    }

    @Test
    func `Session closed callback called on DELETE`() async throws {
        actor SessionTracker {
            var closedSessionId: String?
            func setClosed(_ id: String) {
                closedSessionId = id
            }

            func getClosed() -> String? {
                closedSessionId
            }
        }
        let tracker = SessionTracker()

        let transport = testTransport(
            sessionIdGenerator: { "close-test-session" },
            onSessionClosed: { sessionId in
                await tracker.setClosed(sessionId)
            },
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "close-test-session"],
        )
        _ = await transport.handleRequest(deleteRequest)

        let closedId = await tracker.getClosed()
        #expect(closedId == "close-test-session")
    }

    @Test
    func `Session closed callback not invoked for invalid session DELETE`() async throws {
        actor CallCounter {
            var count = 0
            func increment() {
                count += 1
            }

            func getCount() -> Int {
                count
            }
        }
        let counter = CallCounter()

        let transport = testTransport(
            sessionIdGenerator: { "valid-session" },
            onSessionClosed: { _ in
                await counter.increment()
            },
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE with wrong session ID
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "wrong-session"],
        )
        let response = await transport.handleRequest(deleteRequest)

        #expect(response.statusCode == 404)
        let callCount = await counter.getCount()
        #expect(callCount == 0) // Callback should NOT be called
    }

    // MARK: - Terminated State Tests

    @Test
    func `Terminated stateless transport returns 404`() async throws {
        // Stateless mode
        let transport = testTransport()
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Manually disconnect/close the transport
        await transport.disconnect()

        // Any subsequent request should return 404
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // GET should also return 404
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [HTTPHeader.accept: "text/event-stream"],
        )
        let getResponse = await transport.handleRequest(getRequest)
        #expect(getResponse.statusCode == 404)

        // Even initialize should return 404 after termination
        let reInitRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(id: "3")
                .data(using: .utf8),
        )
        let reInitResponse = await transport.handleRequest(reInitRequest)
        #expect(reInitResponse.statusCode == 404)
    }

    @Test
    func `Terminated stateful transport returns 404 for all requests`() async throws {
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Close the transport directly (simulating server shutdown)
        await transport.close()

        // Any request should now return 404 - even with correct session ID
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"2"}"#.data(using: .utf8),
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 404)

        // Verify the error message indicates termination
        if let body = postResponse.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("terminated"))
        }
    }

    // MARK: - Stream Resumability Tests (Per MCP Spec)

    @Test
    func `POST-initiated stream can be resumed via GET with Last-Event-ID`() async throws {
        // Per spec: "This mechanism applies regardless of how the original SSE stream
        // was initiated—even if a stream was originally started for a specific client
        // request (via HTTP POST), the client will resume it via HTTP GET."
        let eventStore = InMemoryEventStore()
        let transport = testTransport(
            sessionIdGenerator: { "test-session" },
            eventStore: eventStore,
        )
        try await transport.connect()

        // Initialize with protocol version 2025-11-25 (supports priming events)
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest(id: "init", protocolVersion: Version.v2025_11_25)
                .data(using: .utf8),
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Send a POST request that starts an SSE stream
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
            ],
            body: #"{"jsonrpc":"2.0","method":"tools/list","id":"req-1"}"#.data(using: .utf8),
        )
        let postResponse = await transport.handleRequest(postRequest)
        #expect(postResponse.statusCode == 200)
        #expect(postResponse.stream != nil)

        // The event store should have events from the POST stream (priming event at minimum)
        let eventCount = await eventStore.eventCount
        #expect(eventCount >= 1, "Event store should have at least one event from POST stream")

        // Get an event ID from the store to simulate client reconnection
        // We need to manually store an event to get an ID for the POST stream
        let testStreamId = "test-stream-\(UUID().uuidString)"
        let eventId = try await eventStore.storeEvent(
            streamId: testStreamId,
            message: #require(#"{"jsonrpc":"2.0","result":{"tools":[]},"id":"req-1"}"#.data(using: .utf8)),
        )

        // Client reconnects via GET with Last-Event-ID (even though original was POST)
        let getRequest = HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeader.accept: "text/event-stream",
                HTTPHeader.sessionId: "test-session",
                HTTPHeader.protocolVersion: Version.v2025_11_25,
                HTTPHeader.lastEventId: eventId,
            ],
        )
        let getResponse = await transport.handleRequest(getRequest)

        // Should return 200 with stream (resumption mode)
        #expect(getResponse.statusCode == 200)
        #expect(getResponse.stream != nil)
        #expect(getResponse.headers[HTTPHeader.contentType] == "text/event-stream")
    }

    @Test
    func `Cross-stream event isolation during replay`() async throws {
        // Per spec: "Server MUST NOT replay messages delivered on a different stream"
        let eventStore = InMemoryEventStore()

        // Store events for two different streams
        let stream1Id = "stream-1"
        let stream2Id = "stream-2"

        let event1_1 = try await eventStore.storeEvent(
            streamId: stream1Id,
            message: #require(#"{"jsonrpc":"2.0","result":"stream1-msg1","id":"1"}"#.data(using: .utf8)),
        )
        _ = try await eventStore.storeEvent(
            streamId: stream2Id,
            message: #require(#"{"jsonrpc":"2.0","result":"stream2-msg1","id":"2"}"#.data(using: .utf8)),
        )
        _ = try await eventStore.storeEvent(
            streamId: stream1Id,
            message: #require(#"{"jsonrpc":"2.0","result":"stream1-msg2","id":"3"}"#.data(using: .utf8)),
        )
        _ = try await eventStore.storeEvent(
            streamId: stream2Id,
            message: #require(#"{"jsonrpc":"2.0","result":"stream2-msg2","id":"4"}"#.data(using: .utf8)),
        )

        // Replay events after event1_1 (should only get stream1 events)
        actor MessageCollector {
            var messages: [String] = []
            func append(_ text: String) {
                messages.append(text)
            }

            func getMessages() -> [String] {
                messages
            }
        }
        let collector = MessageCollector()

        let replayedStreamId = try await eventStore.replayEventsAfter(event1_1) { _, message in
            if let text = String(data: message, encoding: .utf8) {
                await collector.append(text)
            }
        }

        // Should only replay stream-1 events
        #expect(replayedStreamId == stream1Id)
        let replayedMessages = await collector.getMessages()
        #expect(replayedMessages.count == 1, "Should only replay one event from stream-1")
        #expect(replayedMessages.contains { $0.contains("stream1-msg2") }, "Should contain stream1-msg2")
        #expect(!replayedMessages.contains { $0.contains("stream2") }, "Should NOT contain any stream-2 events")
    }

    @Test
    func `Client sending JSON-RPC response returns 202 Accepted`() async throws {
        // Per spec: For JSON-RPC response or notification input,
        // server returns 202 Accepted with no body
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Client sends a JSON-RPC response (e.g., in reply to a sampling request from server)
        // A response has "result" or "error" but no "method"
        let responseRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Sample response"}]},"id":"server-req-1"}"#.data(using: .utf8),
        )
        let response = await transport.handleRequest(responseRequest)

        // Per spec, responses should return 202 Accepted
        #expect(response.statusCode == 202)
        #expect(response.body == nil || response.body?.isEmpty == true, "202 response should have no body")
    }

    @Test
    func `Client sending JSON-RPC error response returns 202 Accepted`() async throws {
        // Per spec: For JSON-RPC response (including error responses) input,
        // server returns 202 Accepted
        let transport = testTransport(sessionIdGenerator: { "test-session" })
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body:
            TestPayloads.initializeRequest()
                .data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Client sends a JSON-RPC error response (e.g., rejecting a sampling request)
        let errorResponseRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "test-session",
            ],
            body: #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"User rejected sampling request"},"id":"server-req-1"}"#.data(using: .utf8),
        )
        let response = await transport.handleRequest(errorResponseRequest)

        // Per spec, error responses should also return 202 Accepted
        #expect(response.statusCode == 202)
    }

    @Test
    func `Priming events are not replayed during resumption`() async throws {
        // Per spec and InMemoryEventStore design: priming events (empty data)
        // should be stored but NOT replayed as regular messages
        let eventStore = InMemoryEventStore()
        let streamId = "test-stream"

        // Store a priming event (empty data)
        let primingEventId = try await eventStore.storeEvent(streamId: streamId, message: Data())

        // Store a regular message
        _ = try await eventStore.storeEvent(
            streamId: streamId,
            message: #require(#"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)),
        )

        // Replay from before priming event (using a fake "before" ID approach)
        // We'll replay from the priming event itself
        actor MessageCollector {
            var messages: [Data] = []
            func append(_ data: Data) {
                messages.append(data)
            }

            func getMessages() -> [Data] {
                messages
            }
        }
        let collector = MessageCollector()

        _ = try await eventStore.replayEventsAfter(primingEventId) { _, message in
            await collector.append(message)
        }

        let replayedMessages = await collector.getMessages()

        // Should only have 1 message (the regular one), not the priming event
        #expect(replayedMessages.count == 1, "Should only replay regular messages, not priming events")
        #expect(!replayedMessages.contains { $0.isEmpty }, "Should not contain empty (priming) events")
    }
}

// MARK: - Session Idle Timeout Tests

struct SessionIdleTimeoutTests {
    @Test
    func `Session expires after idle timeout`() async throws {
        actor ClosedState {
            var closedSessionId: String?
            func markClosed(_ id: String) {
                closedSessionId = id
            }

            func getClosedSessionId() -> String? {
                closedSessionId
            }
        }
        let state = ClosedState()

        let transport = testTransport(
            sessionIdGenerator: { "idle-test-session" },
            onSessionClosed: { id in await state.markClosed(id) },
            sessionIdleTimeout: .milliseconds(100),
        )
        try await transport.connect()

        // Initialize the session
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializeRequest().data(using: .utf8),
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Wait for idle timeout to fire
        try await Task.sleep(for: .milliseconds(250))

        // Session should have been closed
        let closedId = await state.getClosedSessionId()
        #expect(closedId == "idle-test-session")

        // Subsequent requests should get 404
        let postRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
                HTTPHeader.sessionId: "idle-test-session",
            ],
            body: TestPayloads.pingRequest().data(using: .utf8),
        )
        let response = await transport.handleRequest(postRequest)
        #expect(response.statusCode == 404)
    }

    @Test
    func `Activity resets the idle timer`() async throws {
        actor ClosedState {
            var closed = false
            func markClosed() {
                closed = true
            }

            func isClosed() -> Bool {
                closed
            }
        }
        let state = ClosedState()

        let transport = testTransport(
            sessionIdGenerator: { "active-session" },
            onSessionClosed: { _ in await state.markClosed() },
            sessionIdleTimeout: .milliseconds(200),
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializeRequest().data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Send requests at intervals shorter than the timeout to keep the session alive
        for _ in 0 ..< 4 {
            try await Task.sleep(for: .milliseconds(100))
            let notification = HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeader.accept: "application/json, text/event-stream",
                    HTTPHeader.contentType: "application/json",
                    HTTPHeader.sessionId: "active-session",
                ],
                body: TestPayloads.initializedNotification().data(using: .utf8),
            )
            _ = await transport.handleRequest(notification)
        }

        // Session should still be alive (total elapsed ~400ms, but timer kept resetting)
        let closed = await state.isClosed()
        #expect(closed == false)

        // Now wait for the timeout to actually fire
        try await Task.sleep(for: .milliseconds(350))
        let closedAfterIdle = await state.isClosed()
        #expect(closedAfterIdle == true)
    }

    @Test
    func `DELETE before timeout cancels timer cleanly`() async throws {
        actor ClosedState {
            var callCount = 0
            func increment() {
                callCount += 1
            }

            func getCount() -> Int {
                callCount
            }
        }
        let state = ClosedState()

        let transport = testTransport(
            sessionIdGenerator: { "delete-test-session" },
            onSessionClosed: { _ in await state.increment() },
            sessionIdleTimeout: .milliseconds(200),
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializeRequest().data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // DELETE immediately
        let deleteRequest = HTTPRequest(
            method: "DELETE",
            headers: [HTTPHeader.sessionId: "delete-test-session"],
        )
        let response = await transport.handleRequest(deleteRequest)
        #expect(response.statusCode == 200)

        // Wait past the original timeout
        try await Task.sleep(for: .milliseconds(350))

        // onSessionClosed should have been called exactly once (from DELETE, not from idle timeout)
        let count = await state.getCount()
        #expect(count == 1)
    }

    @Test
    func `Idle timeout is no-op in stateless mode`() async throws {
        // Stateless mode (no sessionIdGenerator) with a timeout set
        let transport = testTransport(
            sessionIdleTimeout: .milliseconds(100),
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializeRequest().data(using: .utf8),
        )
        let initResponse = await transport.handleRequest(initRequest)
        #expect(initResponse.statusCode == 200)

        // Wait past the timeout
        try await Task.sleep(for: .milliseconds(250))

        // Transport should still be alive (no session to expire)
        let terminated = await transport.sessionId
        // In stateless mode, sessionId is always nil, but the transport should not be terminated
        #expect(terminated == nil)

        // Sending another request should still work
        let notification = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializedNotification().data(using: .utf8),
        )
        let response = await transport.handleRequest(notification)
        #expect(response.statusCode == 202)
    }

    @Test
    func `Idle timeout is no-op when nil`() async throws {
        actor ClosedState {
            var closed = false
            func markClosed() {
                closed = true
            }

            func isClosed() -> Bool {
                closed
            }
        }
        let state = ClosedState()

        let transport = testTransport(
            sessionIdGenerator: { "no-timeout-session" },
            onSessionClosed: { _ in await state.markClosed() },
            // sessionIdleTimeout defaults to nil
        )
        try await transport.connect()

        // Initialize
        let initRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeader.accept: "application/json, text/event-stream",
                HTTPHeader.contentType: "application/json",
            ],
            body: TestPayloads.initializeRequest().data(using: .utf8),
        )
        _ = await transport.handleRequest(initRequest)

        // Wait a reasonable amount of time
        try await Task.sleep(for: .milliseconds(200))

        // Session should not have been closed
        let closed = await state.isClosed()
        #expect(closed == false)
    }
}
