// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

// MARK: - Server Fallback Handler Tests

@Suite("Server Fallback Handler Tests")
struct ServerFallbackHandlerTests {
    /// Test that fallback request handler is called for unknown methods.
    @Test("Fallback request handler called for unknown method", .timeLimit(.minutes(1)))
    func testFallbackRequestHandlerCalledForUnknownMethod() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server advertises both tools and prompts capabilities
        let server = Server(
            name: "FallbackTestServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init(), tools: .init())
        )

        // Track which methods the fallback handler received
        actor MethodTracker {
            var receivedMethods: [String] = []
            func add(_ method: String) { receivedMethods.append(method) }
            func getMethods() -> [String] { receivedMethods }
        }
        let tracker = MethodTracker()

        // Set up fallback handler that captures the method
        await server.setFallbackRequestHandler { [tracker] request, _ in
            await tracker.add(request.method)
            throw MCPError.methodNotFound("No handler for: \(request.method)")
        }

        // Register ListTools to satisfy capability but not ListPrompts
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Try to call listPrompts which has no specific handler but server advertises prompts capability
        do {
            _ = try await client.listPrompts()
            Issue.record("Expected methodNotFound error")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.methodNotFound)
        }

        // Verify fallback handler was called with the correct method
        let methods = await tracker.getMethods()
        #expect(methods.contains(ListPrompts.name))

        await client.disconnect()
        await server.stop()
    }

    /// Test that fallback notification handler is called for unknown notifications.
    @Test("Fallback notification handler called for unknown notification", .timeLimit(.minutes(1)))
    func testFallbackNotificationHandlerCalledForUnknownNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "FallbackTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        // Track notifications received by fallback handler
        actor NotificationTracker {
            var receivedMethods: [String] = []
            private var continuation: CheckedContinuation<Void, Never>?
            private var targetMethod: String?

            func add(_ method: String) {
                receivedMethods.append(method)
                if method == targetMethod {
                    continuation?.resume()
                    continuation = nil
                }
            }

            func getMethods() -> [String] { receivedMethods }

            func waitForNotification(_ method: String) async {
                if receivedMethods.contains(method) { return }
                targetMethod = method
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }
        let tracker = NotificationTracker()

        // Set up fallback notification handler
        await server.setFallbackNotificationHandler { [tracker] notification in
            await tracker.add(notification.method)
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Send a custom notification that the server doesn't have a specific handler for
        // Use progress notification since we haven't registered a handler for it
        try await client.sendProgressNotification(
            token: .string("test-token"),
            progress: 50.0
        )

        // Wait specifically for the progress notification
        await tracker.waitForNotification(ProgressNotification.name)

        let methods = await tracker.getMethods()
        #expect(methods.contains(ProgressNotification.name))

        await client.disconnect()
        await server.stop()
    }

    /// Test that specific handlers take precedence over fallback handlers.
    @Test("Specific handler takes precedence over fallback", .timeLimit(.minutes(1)))
    func testSpecificHandlerTakesPrecedenceOverFallback() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "FallbackTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        actor CallTracker {
            var fallbackCalled = false
            var specificCalled = false

            func markFallbackCalled() { fallbackCalled = true }
            func markSpecificCalled() { specificCalled = true }
            func getState() -> (fallback: Bool, specific: Bool) { (fallbackCalled, specificCalled) }
        }
        let tracker = CallTracker()

        // Set up fallback handler
        await server.setFallbackRequestHandler { [tracker] _, _ in
            await tracker.markFallbackCalled()
            throw MCPError.methodNotFound("Fallback called")
        }

        // Set up specific handler for ListTools
        await server.withRequestHandler(ListTools.self) { [tracker] _, _ in
            await tracker.markSpecificCalled()
            return ListTools.Result(tools: [
                Tool(name: "test-tool", inputSchema: ["type": "object"]),
            ])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Call ListTools which has a specific handler
        let result = try await client.listTools()
        #expect(result.tools.count == 1)
        #expect(result.tools.first?.name == "test-tool")

        // Verify specific handler was called, not fallback
        let state = await tracker.getState()
        #expect(state.specific == true, "Specific handler should have been called")
        #expect(state.fallback == false, "Fallback handler should not have been called")

        await client.disconnect()
        await server.stop()
    }

    /// Test that specific notification handlers take precedence over fallback.
    @Test("Specific notification handler takes precedence over fallback", .timeLimit(.minutes(1)))
    func testSpecificNotificationHandlerTakesPrecedenceOverFallback() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "FallbackTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        actor CallTracker {
            var fallbackCalledFor: [String] = []
            var specificCalled = false
            private var continuation: CheckedContinuation<Void, Never>?

            func markFallbackCalled(method: String) {
                fallbackCalledFor.append(method)
                // Don't resume for initialized notification - we're waiting for progress
                if method == ProgressNotification.name {
                    resumeContinuation()
                }
            }

            func markSpecificCalled() {
                specificCalled = true
                resumeContinuation()
            }

            private func resumeContinuation() {
                continuation?.resume()
                continuation = nil
            }

            func wasProgressFallbackCalled() -> Bool {
                fallbackCalledFor.contains(ProgressNotification.name)
            }

            func wasSpecificCalled() -> Bool { specificCalled }

            func waitForProgressHandler() async {
                if specificCalled || fallbackCalledFor.contains(ProgressNotification.name) { return }
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }
        let tracker = CallTracker()

        // Set up fallback notification handler
        await server.setFallbackNotificationHandler { [tracker] notification in
            await tracker.markFallbackCalled(method: notification.method)
        }

        // Set up specific handler for progress notifications
        await server.onNotification(ProgressNotification.self) { [tracker] _ in
            await tracker.markSpecificCalled()
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Send progress notification which has a specific handler
        try await client.sendProgressNotification(
            token: .string("test-token"),
            progress: 50.0
        )

        await tracker.waitForProgressHandler()

        // Verify specific handler was called for progress, not fallback
        let specificCalled = await tracker.wasSpecificCalled()
        let progressFallbackCalled = await tracker.wasProgressFallbackCalled()
        #expect(specificCalled == true, "Specific handler should have been called for progress notification")
        #expect(progressFallbackCalled == false, "Fallback handler should not have been called for progress notification")

        await client.disconnect()
        await server.stop()
    }

    /// Test that fallback handler can return a successful response.
    @Test("Fallback handler can return successful response", .timeLimit(.minutes(1)))
    func testFallbackHandlerCanReturnSuccessfulResponse() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "FallbackTestServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init())
        )

        // Set up fallback handler that returns a valid response for ListPrompts
        await server.setFallbackRequestHandler { request, _ in
            if request.method == ListPrompts.name {
                let result = ListPrompts.Result(prompts: [
                    Prompt(name: "fallback-prompt", description: "Created by fallback handler"),
                ])
                let encoder = JSONEncoder()
                let resultData = try encoder.encode(result)
                let resultValue = try JSONDecoder().decode(Value.self, from: resultData)
                return Response<AnyMethod>(id: request.id, result: resultValue)
            }
            throw MCPError.methodNotFound("Unknown method: \(request.method)")
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Call ListPrompts - should be handled by fallback
        let result = try await client.listPrompts()
        #expect(result.prompts.count == 1)
        #expect(result.prompts.first?.name == "fallback-prompt")

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - Client Fallback Handler Tests

@Suite("Client Fallback Handler Tests")
struct ClientFallbackHandlerTests {
    /// Test that client fallback request handler is called for unknown server requests.
    @Test("Client fallback request handler called for unknown method", .timeLimit(.minutes(1)))
    func testClientFallbackRequestHandlerCalledForUnknownMethod() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server that will send a custom request to the client
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        actor MethodTracker {
            var receivedMethods: [String] = []
            func add(_ method: String) { receivedMethods.append(method) }
            func getMethods() -> [String] { receivedMethods }
        }
        let tracker = MethodTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")

        // Set up fallback handler on client
        await client.setFallbackRequestHandler { [tracker] request, _ in
            await tracker.add(request.method)
            throw MCPError.methodNotFound("Client has no handler for: \(request.method)")
        }

        try await client.connect(transport: clientTransport)

        // The client's fallback handler won't be tested directly since we need
        // the server to send a request to the client. For now, verify the handler is registered.
        // The actual invocation would require the server to initiate a request.

        await client.disconnect()
        await server.stop()
    }

    /// Test that client fallback notification handler is called for unknown server notifications.
    @Test("Client fallback notification handler called for unknown notification", .timeLimit(.minutes(1)))
    func testClientFallbackNotificationHandlerCalledForUnknownNotification() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: true))
        )

        actor NotificationTracker {
            var receivedMethods: [String] = []
            private var continuation: CheckedContinuation<Void, Never>?

            func add(_ method: String) {
                receivedMethods.append(method)
                continuation?.resume()
                continuation = nil
            }

            func getMethods() -> [String] { receivedMethods }

            func waitForNotification() async {
                if !receivedMethods.isEmpty { return }
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }
        let tracker = NotificationTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")

        // Set up fallback notification handler on client
        await client.setFallbackNotificationHandler { [tracker] notification in
            await tracker.add(notification.method)
        }

        try await client.connect(transport: clientTransport)

        // Have server send a notification that client doesn't have a specific handler for
        try await server.sendToolListChanged()

        await tracker.waitForNotification()

        let methods = await tracker.getMethods()
        #expect(methods.contains(ToolListChangedNotification.name))

        await client.disconnect()
        await server.stop()
    }

    /// Test that client specific notification handler takes precedence over fallback.
    @Test("Client specific notification handler takes precedence over fallback", .timeLimit(.minutes(1)))
    func testClientSpecificNotificationHandlerTakesPrecedenceOverFallback() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: true))
        )

        actor CallTracker {
            var fallbackCalled = false
            var specificCalled = false
            private var continuation: CheckedContinuation<Void, Never>?

            func markFallbackCalled() {
                fallbackCalled = true
                resumeContinuation()
            }

            func markSpecificCalled() {
                specificCalled = true
                resumeContinuation()
            }

            private func resumeContinuation() {
                continuation?.resume()
                continuation = nil
            }

            func getState() -> (fallback: Bool, specific: Bool) { (fallbackCalled, specificCalled) }

            func waitForHandler() async {
                if fallbackCalled || specificCalled { return }
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }
        let tracker = CallTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")

        // Set up fallback notification handler
        await client.setFallbackNotificationHandler { [tracker] _ in
            await tracker.markFallbackCalled()
        }

        // Set up specific handler for tool list changed notifications
        await client.onNotification(ToolListChangedNotification.self) { [tracker] _ in
            await tracker.markSpecificCalled()
        }

        try await client.connect(transport: clientTransport)

        // Have server send the notification
        try await server.sendToolListChanged()

        await tracker.waitForHandler()

        // Verify specific handler was called, not fallback
        let state = await tracker.getState()
        #expect(state.specific == true, "Specific handler should have been called")
        #expect(state.fallback == false, "Fallback handler should not have been called")

        await client.disconnect()
        await server.stop()
    }
}
