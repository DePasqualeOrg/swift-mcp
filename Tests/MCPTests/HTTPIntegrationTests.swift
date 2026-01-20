import Foundation
import Testing

@testable import MCP

/// Integration tests for HTTP transport using real HTTP requests.
///
/// These tests verify:
/// - Multi-client scenarios (10+ concurrent clients)
/// - Session lifecycle (create, use, delete)
/// - Stateful vs stateless mode
/// - Response routing
///
/// Uses TestHTTPServer (Hummingbird) to run a real HTTP server and URLSession
/// to make real HTTP requests, similar to Python (httpx) and TypeScript (fetch) SDKs.
/// This ensures Host headers are set correctly and DNS rebinding protection works.
@Suite("HTTP Integration Tests", .serialized)
struct HTTPIntegrationTests {
    // MARK: - Test Message Templates

    static let initializeMessage = TestPayloads.initializeRequest(id: "init-1", clientName: "test-client")
    static let toolsListMessage = TestPayloads.listToolsRequest(id: "tools-1")

    // MARK: - Initialization Tests

    @Test("Initialize server and generate session ID")
    func initializeServerAndGenerateSessionId() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        let (_, response) = try await server.post(body: Self.initializeMessage)

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: HTTPHeader.contentType) == "text/event-stream")
        #expect(response.value(forHTTPHeaderField: HTTPHeader.sessionId) != nil)
    }

    @Test("Reject second initialization request")
    func rejectSecondInitializationRequest() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        // First initialize
        let (_, response1) = try await server.post(body: Self.initializeMessage)
        #expect(response1.statusCode == 200)

        let sessionId = response1.value(forHTTPHeaderField: HTTPHeader.sessionId)!

        // Second initialize - should fail
        let secondInitMessage = TestPayloads.initializeRequest(id: "init-2", clientName: "test-client")
        let (_, response2) = try await server.post(body: secondInitMessage, sessionId: sessionId)

        #expect(response2.statusCode == 400)
    }

    @Test("Reject batch initialize request")
    func rejectBatchInitializeRequest() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        let batchInitMessages = TestPayloads.batchRequest([
            TestPayloads.initializeRequest(id: "init-1", clientName: "test-client-1"),
            TestPayloads.initializeRequest(id: "init-2", clientName: "test-client-2"),
        ])
        let (_, response) = try await server.post(body: batchInitMessages)

        #expect(response.statusCode == 400)
    }

    // MARK: - Session Validation Tests

    @Test("Reject requests without valid session ID")
    func rejectRequestsWithoutValidSessionId() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        // Initialize first
        _ = try await server.post(body: Self.initializeMessage)

        // Try without session ID - should fail
        let (_, response) = try await server.post(body: Self.toolsListMessage)

        #expect(response.statusCode == 400)
    }

    @Test("Reject invalid session ID")
    func rejectInvalidSessionId() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        // Initialize first
        _ = try await server.post(body: Self.initializeMessage)

        // Try with invalid session ID
        let (_, response) = try await server.post(body: Self.toolsListMessage, sessionId: "invalid-session-id")

        #expect(response.statusCode == 404)
    }

    // MARK: - SSE Stream Tests

    // Note: "Reject second SSE stream for same session" test is not applicable with real HTTP
    // because URLSession closes the connection after receiving the response. This behavior
    // is tested in HTTPServerTransportTests with direct handleRequest() calls.

    @Test("Reject GET requests without Accept header for SSE")
    func rejectGETRequestsWithoutAcceptHeader() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // GET with wrong Accept header
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept") // Wrong Accept
        request.setValue("test-session", forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(Version.v2024_11_05, forHTTPHeaderField: HTTPHeader.protocolVersion)

        let (_, response) = try await server.request(request)
        #expect(response.statusCode == 406)
    }

    // MARK: - Content Type Validation

    @Test("Reject POST requests without proper Accept header")
    func rejectPOSTRequestsWithoutProperAcceptHeader() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // POST without text/event-stream in Accept
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept") // Missing text/event-stream
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("test-session", forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(Version.v2024_11_05, forHTTPHeaderField: HTTPHeader.protocolVersion)
        request.httpBody = Self.toolsListMessage.data(using: .utf8)

        let (_, response) = try await server.request(request)
        #expect(response.statusCode == 406)
    }

    @Test("Reject unsupported Content-Type")
    func rejectUnsupportedContentType() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // POST with wrong Content-Type
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type") // Wrong Content-Type
        request.setValue("test-session", forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(Version.v2024_11_05, forHTTPHeaderField: HTTPHeader.protocolVersion)
        request.httpBody = "This is plain text".data(using: .utf8)

        let (_, response) = try await server.request(request)
        #expect(response.statusCode == 415)
    }

    // MARK: - Notification Handling

    @Test("Handle JSON-RPC batch notification messages with 202 response")
    func handleJSONRPCBatchNotificationMessagesWith202Response() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // Send batch of notifications (no IDs)
        let batchNotifications = """
        [{"jsonrpc":"2.0","method":"someNotification1","params":{}},{"jsonrpc":"2.0","method":"someNotification2","params":{}}]
        """
        let (_, response) = try await server.post(body: batchNotifications, sessionId: "test-session")

        #expect(response.statusCode == 202)
    }

    // MARK: - JSON Parsing

    @Test("Handle invalid JSON data properly")
    func handleInvalidJSONDataProperly() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // Send invalid JSON
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("test-session", forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue(Version.v2024_11_05, forHTTPHeaderField: HTTPHeader.protocolVersion)
        request.httpBody = "This is not valid JSON".data(using: .utf8)

        let (_, response) = try await server.request(request)
        #expect(response.statusCode == 400)
    }

    // MARK: - DELETE Tests

    @Test("Handle DELETE requests and close session properly")
    func handleDELETERequestsAndCloseSession() async throws {
        actor ClosedState {
            var closed = false
            func markClosed() { closed = true }
            func isClosed() -> Bool { closed }
        }
        let state = ClosedState()

        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" },
            onSessionClosed: { _ in await state.markClosed() }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // DELETE
        let (_, response) = try await server.delete(sessionId: "test-session")

        #expect(response.statusCode == 200)
        let closed = await state.isClosed()
        #expect(closed == true)
    }

    @Test("Reject DELETE requests with invalid session ID")
    func rejectDELETERequestsWithInvalidSessionId() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "valid-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // DELETE with invalid session ID
        let (_, response) = try await server.delete(sessionId: "invalid-session-id")

        #expect(response.statusCode == 404)
    }

    // MARK: - Protocol Version Tests

    @Test("Accept requests with matching protocol version")
    func acceptRequestsWithMatchingProtocolVersion() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // Request with valid protocol version
        let (_, response) = try await server.post(body: Self.toolsListMessage, sessionId: "test-session")

        #expect(response.statusCode == 200)
    }

    @Test("Reject unsupported protocol version")
    func rejectUnsupportedProtocolVersion() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize
        _ = try await server.post(body: Self.initializeMessage)

        // Request with unsupported protocol version
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("test-session", forHTTPHeaderField: HTTPHeader.sessionId)
        request.setValue("1999-01-01", forHTTPHeaderField: HTTPHeader.protocolVersion) // Unsupported
        request.httpBody = Self.toolsListMessage.data(using: .utf8)

        let (_, response) = try await server.request(request)
        #expect(response.statusCode == 400)
    }

    // MARK: - Session Callbacks

    @Test("Session initialized callback fires")
    func sessionInitializedCallbackFires() async throws {
        actor CallbackTracker {
            var sessionId: String?
            func set(_ id: String) { sessionId = id }
            func get() -> String? { sessionId }
        }
        let tracker = CallbackTracker()

        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "callback-test-session" },
            onSessionInitialized: { sessionId in
                await tracker.set(sessionId)
            }
        )
        defer { Task { await server.stop() } }

        _ = try await server.post(body: Self.initializeMessage)

        let trackedSessionId = await tracker.get()
        #expect(trackedSessionId == "callback-test-session")
    }

    // MARK: - Method Not Allowed Tests

    @Test("Reject unsupported HTTP methods with 405")
    func rejectUnsupportedHttpMethods() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "method-test-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize first to get a valid session
        let (_, initResponse) = try await server.post(body: Self.initializeMessage)
        #expect(initResponse.statusCode == 200)

        // Test PUT method
        let (_, putResponse) = try await server.customMethod("PUT", body: Self.initializeMessage, sessionId: "method-test-session")
        #expect(putResponse.statusCode == 405, "PUT method should be rejected with 405 Method Not Allowed")

        // Test PATCH method
        let (_, patchResponse) = try await server.customMethod("PATCH", body: Self.initializeMessage, sessionId: "method-test-session")
        #expect(patchResponse.statusCode == 405, "PATCH method should be rejected with 405 Method Not Allowed")
    }

    // MARK: - Session Termination Tests

    @Test("Requests to terminated session fail with 404")
    func requestsToTerminatedSessionFail() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "terminated-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize the session
        let (_, initResponse) = try await server.post(body: Self.initializeMessage)
        #expect(initResponse.statusCode == 200)

        // Make a successful request to confirm session is working
        let (_, pingResponse) = try await server.post(body: TestPayloads.pingRequest(), sessionId: "terminated-session")
        #expect(pingResponse.statusCode == 200)

        // Terminate the session with DELETE
        let (_, deleteResponse) = try await server.delete(sessionId: "terminated-session")
        #expect(deleteResponse.statusCode == 200)

        // Attempt to use the terminated session - should fail
        let (data, afterDeleteResponse) = try await server.post(body: TestPayloads.pingRequest(), sessionId: "terminated-session")
        #expect(afterDeleteResponse.statusCode == 404, "Request to terminated session should return 404")

        // Verify the error message mentions session termination
        if let text = String(data: data, encoding: .utf8) {
            #expect(
                text.lowercased().contains("terminated") || text.lowercased().contains("session"),
                "Error message should indicate session termination"
            )
        }
    }

    // MARK: - Backwards Compatibility Tests

    @Test("Backwards compatibility - accept requests without protocol version header")
    func backwardsCompatibilityNoProtocolVersion() async throws {
        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { "compat-session" }
        )
        defer { Task { await server.stop() } }

        // Initialize the session (with protocol version)
        let (_, initResponse) = try await server.post(body: Self.initializeMessage)
        #expect(initResponse.statusCode == 200)

        // Make a request WITHOUT the protocol version header
        var request = await URLRequest(url: server.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("compat-session", forHTTPHeaderField: HTTPHeader.sessionId)
        // Note: NO protocolVersion header
        request.httpBody = TestPayloads.pingRequest().data(using: .utf8)

        let (_, response) = try await server.request(request)

        // Should succeed for backwards compatibility
        #expect(response.statusCode == 200, "Server should accept requests without protocol version header for backwards compatibility")
    }

    // MARK: - Real HTTP with DNS Rebinding Protection

    @Test("Real HTTP request includes Host header automatically")
    func realHTTPRequestIncludesHostHeader() async throws {
        // This test verifies that real HTTP requests via URLSession include Host headers,
        // which is how DNS rebinding protection works in production.
        // TestHTTPServer uses default DNS rebinding protection (.localhost())

        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        // URLSession automatically adds Host header based on the URL
        let (_, response) = try await server.post(body: Self.initializeMessage)

        // If DNS rebinding protection blocked us, we'd get 421. Getting 200 proves
        // URLSession set the Host header correctly and protection allowed it.
        #expect(response.statusCode == 200)
    }

    @Test("DNS rebinding attack blocked with spoofed Host header")
    func dnsRebindingAttackBlocked() async throws {
        // This test verifies that DNS rebinding protection actually blocks attacks.
        // We use curl to send a request with a spoofed Host header (simulating an attack).
        // URLSession can't do this because it automatically sets Host based on URL.

        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        let port = await server.port

        // Use curl to send a request with a malicious Host header
        // This simulates a DNS rebinding attack where attacker controls DNS
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s", // Silent mode
            "-o", "/dev/null", // Discard body
            "-w", "%{http_code}", // Output only status code
            "-X", "POST",
            "-H", "Host: evil.attacker.com", // Spoofed Host header (attack)
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json, text/event-stream",
            "-H", "\(HTTPHeader.protocolVersion): \(Version.v2024_11_05)",
            "-d", Self.initializeMessage,
            "http://127.0.0.1:\(port)/",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let statusCode = String(data: data, encoding: .utf8) ?? ""

        // Should get 421 Misdirected Request because Host header doesn't match
        #expect(statusCode == "421", "Expected 421 for spoofed Host, got \(statusCode)")
    }

    @Test("DNS rebinding attack blocked with missing Host header")
    func dnsRebindingAttackBlockedMissingHost() async throws {
        // Verify that requests without a Host header are rejected

        let server = try await TestHTTPServer.create(
            sessionIdGenerator: { UUID().uuidString }
        )
        defer { Task { await server.stop() } }

        let port = await server.port

        // Use curl with HTTP/1.0 to avoid automatic Host header
        // Or explicitly set an empty host - curl still sends Host but we test the path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s",
            "-o", "/dev/null",
            "-w", "%{http_code}",
            "-X", "POST",
            "--http1.0", // HTTP/1.0 doesn't require Host
            "-H", "Host:", // Empty Host header
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json, text/event-stream",
            "-H", "\(HTTPHeader.protocolVersion): \(Version.v2024_11_05)",
            "-d", Self.initializeMessage,
            "http://127.0.0.1:\(port)/",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let statusCode = String(data: data, encoding: .utf8) ?? ""

        // Should get 421 Misdirected Request because Host header is missing/empty
        #expect(statusCode == "421", "Expected 421 for missing Host, got \(statusCode)")
    }
}
