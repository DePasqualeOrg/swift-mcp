// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Tests for notification handler dispatch behavior.
///
/// Notification handlers are dispatched via AsyncStream (outside the message loop)
/// so that handlers can make requests back to the server without deadlocking.
struct NotificationHandlerDispatchTests {
    // MARK: - Helpers

    struct ConnectedPair {
        let client: Client
        let server: Server
        let clientTransport: InMemoryTransport
        let serverTransport: InMemoryTransport
    }

    func createConnectedPair() async throws -> ConnectedPair {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "test-server",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true)),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "A test tool", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            CallTool.Result(content: [.text("called \(request.name)", annotations: nil, _meta: nil)])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        return ConnectedPair(
            client: client,
            server: server,
            clientTransport: clientTransport,
            serverTransport: serverTransport,
        )
    }

    // MARK: - Handler Makes Protocol Request

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Handler can call protocol methods without deadlocking`() async throws {
        let pair = try await createConnectedPair()

        actor ResultHolder {
            var tools: [Tool]?
            func set(_ tools: [Tool]) {
                self.tools = tools
            }

            func get() -> [Tool]? {
                tools
            }
        }

        let holder = ResultHolder()

        // Register a notification handler that calls listTools() back to the server.
        // Under the old inline dispatch, this would deadlock because the message loop
        // would be blocked waiting for the handler to complete, while the handler would
        // be blocked waiting for the listTools response (which the loop can't process).
        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            let result = try await pair.client.listTools()
            await holder.set(result.tools)
        }

        // Send the notification from the server to trigger the handler
        try await pair.server.notify(ToolListChangedNotification.message())

        // Poll until the handler completes or timeout triggers
        var tools: [Tool]?
        for _ in 0 ..< 50 {
            try await Task.sleep(for: .milliseconds(50))
            tools = await holder.get()
            if tools != nil { break }
        }

        #expect(tools != nil, "Handler should have received tools from listTools()")
        if let tools {
            #expect(tools.count == 1)
            #expect(tools[0].name == "test_tool")
        }

        await pair.client.disconnect()
    }

    // MARK: - Multiple Handlers

    @Test
    func `Multiple handlers for the same notification type all execute`() async throws {
        let pair = try await createConnectedPair()

        actor Counter {
            var count = 0
            func increment() {
                count += 1
            }

            func get() -> Int {
                count
            }
        }

        let counter1 = Counter()
        let counter2 = Counter()

        // Register two handlers for the same notification type
        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            await counter1.increment()
        }

        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            await counter2.increment()
        }

        // Trigger the notification
        try await pair.server.notify(ToolListChangedNotification.message())

        // Wait for both handlers to execute
        let bothCalled = await pollUntil {
            let c1 = await counter1.get()
            let c2 = await counter2.get()
            return c1 >= 1 && c2 >= 1
        }
        #expect(bothCalled, "Both handlers should be called")

        let count1 = await counter1.get()
        let count2 = await counter2.get()

        #expect(count1 == 1, "First handler should be called exactly once")
        #expect(count2 == 1, "Second handler should be called exactly once")

        await pair.client.disconnect()
    }

    // MARK: - Handler Errors

    @Test
    func `Handler errors are logged, not fatal`() async throws {
        let pair = try await createConnectedPair()

        actor CallTracker {
            var called = false
            func markCalled() {
                called = true
            }

            func wasCalled() -> Bool {
                called
            }
        }

        let tracker = CallTracker()

        // Register a handler that throws
        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            throw MCPError.internalError("Handler error for testing")
        }

        // Register a second handler that should still execute
        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            await tracker.markCalled()
        }

        // Trigger the notification
        try await pair.server.notify(ToolListChangedNotification.message())

        // Wait for the second handler to execute (despite the first one throwing)
        let secondCalled = await pollUntil { await tracker.wasCalled() }
        #expect(secondCalled, "Second handler should execute even when first handler throws")

        // Verify the client still functions after the error
        let result = try await pair.client.listTools()
        #expect(result.tools.count == 1, "Client should still work after handler error")

        await pair.client.disconnect()
    }

    @Test
    func `Client continues to function after notification handler throws`() async throws {
        let pair = try await createConnectedPair()

        // Register a failing handler
        await pair.client.onNotification(ToolListChangedNotification.self) { _ in
            throw MCPError.internalError("Simulated handler failure")
        }

        // Trigger the notification multiple times
        for _ in 0 ..< 3 {
            try await pair.server.notify(ToolListChangedNotification.message())
        }

        // Allow time for notifications to be processed
        try await Task.sleep(for: .milliseconds(200))

        // Client should still be able to make requests
        let toolResult = try await pair.client.callTool(name: "test_tool")
        if case let .text(text, _, _) = toolResult.content.first {
            #expect(text == "called test_tool")
        } else {
            Issue.record("Expected text content")
        }

        await pair.client.disconnect()
    }
}
