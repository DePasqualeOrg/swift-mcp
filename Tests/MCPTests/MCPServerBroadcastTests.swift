// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Tests for MCPServer session broadcasting behavior.
struct MCPServerBroadcastTests {
    // MARK: - Helpers

    /// Creates a connected client-server pair from an MCPServer session.
    /// Returns the client and server transport for test control.
    struct SessionPair {
        let client: Client
        let session: Server
        let clientTransport: InMemoryTransport
        let serverTransport: InMemoryTransport
    }

    func createSessionPair(from mcpServer: MCPServer) async throws -> SessionPair {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        return SessionPair(
            client: client,
            session: session,
            clientTransport: clientTransport,
            serverTransport: serverTransport,
        )
    }

    /// Actor for collecting notifications received by clients.
    actor NotificationCollector {
        var count = 0
        func increment() {
            count += 1
        }

        func get() -> Int {
            count
        }
    }

    // MARK: - Tool List Changed Broadcast

    @Test
    func `Broadcast ToolListChangedNotification to multiple sessions`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        // Register initial tool so sessions have tools capability
        _ = try await mcpServer.register(
            name: "initial_tool",
        ) { (_: HandlerContext) in "hello" }

        // Create three sessions
        let pair1 = try await createSessionPair(from: mcpServer)
        let pair2 = try await createSessionPair(from: mcpServer)
        let pair3 = try await createSessionPair(from: mcpServer)

        // Set up notification listeners on each client
        let collector1 = NotificationCollector()
        let collector2 = NotificationCollector()
        let collector3 = NotificationCollector()

        await pair1.client.onNotification(ToolListChangedNotification.self) { _ in
            await collector1.increment()
        }
        await pair2.client.onNotification(ToolListChangedNotification.self) { _ in
            await collector2.increment()
        }
        await pair3.client.onNotification(ToolListChangedNotification.self) { _ in
            await collector3.increment()
        }

        // Register a new tool (triggers broadcast)
        _ = try await mcpServer.register(
            name: "new_tool",
        ) { (_: HandlerContext) in "world" }

        // Wait for all three clients to receive the notification
        let allReceived = await pollUntil {
            let c1 = await collector1.get()
            let c2 = await collector2.get()
            let c3 = await collector3.get()
            return c1 >= 1 && c2 >= 1 && c3 >= 1
        }
        #expect(allReceived, "All three clients should receive ToolListChanged notification")

        let count1 = await collector1.get()
        let count2 = await collector2.get()
        let count3 = await collector3.get()

        #expect(count1 == 1, "Client 1 should receive exactly one ToolListChanged notification")
        #expect(count2 == 1, "Client 2 should receive exactly one ToolListChanged notification")
        #expect(count3 == 1, "Client 3 should receive exactly one ToolListChanged notification")

        // Clean up
        await pair1.client.disconnect()
        await pair2.client.disconnect()
        await pair3.client.disconnect()
    }

    // MARK: - Resource List Changed Broadcast

    @Test
    func `Broadcast ResourceListChangedNotification on resource registration`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        // Register an initial resource so sessions have resource capability
        _ = try await mcpServer.registerResource(
            uri: "config://initial",
            name: "initial",
        ) { .text("{}", uri: "config://initial") }

        let pair1 = try await createSessionPair(from: mcpServer)
        let pair2 = try await createSessionPair(from: mcpServer)

        let collector1 = NotificationCollector()
        let collector2 = NotificationCollector()

        await pair1.client.onNotification(ResourceListChangedNotification.self) { _ in
            await collector1.increment()
        }
        await pair2.client.onNotification(ResourceListChangedNotification.self) { _ in
            await collector2.increment()
        }

        // Register a new resource (triggers broadcast)
        _ = try await mcpServer.registerResource(
            uri: "config://app",
            name: "app_config",
        ) { .text("{\"debug\": true}", uri: "config://app") }

        let bothReceived = await pollUntil {
            let c1 = await collector1.get()
            let c2 = await collector2.get()
            return c1 >= 1 && c2 >= 1
        }
        #expect(bothReceived, "Both clients should receive ResourceListChanged notification")

        let count1 = await collector1.get()
        let count2 = await collector2.get()

        #expect(count1 == 1, "Client 1 should receive exactly one ResourceListChanged notification")
        #expect(count2 == 1, "Client 2 should receive exactly one ResourceListChanged notification")

        await pair1.client.disconnect()
        await pair2.client.disconnect()
    }

    // MARK: - Prompt List Changed Broadcast

    @Test
    func `Broadcast PromptListChangedNotification on prompt registration`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        // Register an initial prompt so sessions have prompt capability
        _ = try await mcpServer.registerPrompt(
            name: "initial_prompt",
        ) { [Prompt.Message.user(.text("initial"))] }

        let pair1 = try await createSessionPair(from: mcpServer)
        let pair2 = try await createSessionPair(from: mcpServer)

        let collector1 = NotificationCollector()
        let collector2 = NotificationCollector()

        await pair1.client.onNotification(PromptListChangedNotification.self) { _ in
            await collector1.increment()
        }
        await pair2.client.onNotification(PromptListChangedNotification.self) { _ in
            await collector2.increment()
        }

        // Register a new prompt (triggers broadcast)
        _ = try await mcpServer.registerPrompt(
            name: "new_prompt",
        ) { [Prompt.Message.user(.text("hello"))] }

        let bothReceived = await pollUntil {
            let c1 = await collector1.get()
            let c2 = await collector2.get()
            return c1 >= 1 && c2 >= 1
        }
        #expect(bothReceived, "Both clients should receive PromptListChanged notification")

        let count1 = await collector1.get()
        let count2 = await collector2.get()

        #expect(count1 == 1, "Client 1 should receive exactly one PromptListChanged notification")
        #expect(count2 == 1, "Client 2 should receive exactly one PromptListChanged notification")

        await pair1.client.disconnect()
        await pair2.client.disconnect()
    }

    // MARK: - Failed Session Cleanup

    @Test
    func `Failed session removed during broadcast`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        _ = try await mcpServer.register(
            name: "initial_tool",
        ) { (_: HandlerContext) in "hello" }

        // Create two sessions
        let pair1 = try await createSessionPair(from: mcpServer)
        let pair2 = try await createSessionPair(from: mcpServer)

        let collector2 = NotificationCollector()

        await pair2.client.onNotification(ToolListChangedNotification.self) { _ in
            await collector2.increment()
        }

        // Disconnect session 1's transport (simulating a dropped connection)
        await pair1.serverTransport.disconnect()

        // Wait for the disconnect to propagate
        try await Task.sleep(for: .milliseconds(50))

        // Register a new tool (triggers broadcast to all sessions)
        // Session 1's send should fail, and it should be cleaned up
        _ = try await mcpServer.register(
            name: "another_tool",
        ) { (_: HandlerContext) in "world" }

        // Session 2 should still get the notification
        let received = await pollUntil { await collector2.get() >= 1 }
        #expect(received, "Remaining session should receive notification")

        let count2 = await collector2.get()
        #expect(count2 == 1, "Remaining session should receive exactly one notification")

        // Clean up
        await pair2.client.disconnect()
    }

    // MARK: - removeSession on Disconnect

    @Test
    func `Session removed from MCPServer when transport disconnects`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        _ = try await mcpServer.register(
            name: "tool",
        ) { (_: HandlerContext) in "hello" }

        let pair = try await createSessionPair(from: mcpServer)

        // Disconnect the server transport
        await pair.serverTransport.disconnect()

        // Wait for the disconnect to propagate and session to be cleaned up
        try await Task.sleep(for: .milliseconds(200))

        // Create a new session and register a tool - if the old session was cleaned up,
        // broadcast should only go to the new session (no errors from dead sessions)
        let pair2 = try await createSessionPair(from: mcpServer)
        let collector = NotificationCollector()

        await pair2.client.onNotification(ToolListChangedNotification.self) { _ in
            await collector.increment()
        }

        _ = try await mcpServer.register(
            name: "tool_2",
        ) { (_: HandlerContext) in "world" }

        let received = await pollUntil { await collector.get() >= 1 }
        #expect(received, "New session should receive notification")

        let count = await collector.get()
        #expect(count == 1, "New session should receive exactly one notification")

        await pair2.client.disconnect()
    }

    // MARK: - Concurrent Broadcast

    @Test
    func `Concurrent tool registration and session creation`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        // Register initial tool
        _ = try await mcpServer.register(
            name: "base_tool",
        ) { (_: HandlerContext) in "base" }

        // Create some initial sessions
        var pairs: [SessionPair] = []
        for _ in 0 ..< 3 {
            let pair = try await createSessionPair(from: mcpServer)
            pairs.append(pair)
        }

        // Concurrently register tools while creating/removing sessions
        await withTaskGroup(of: Void.self) { group in
            // Register tools concurrently
            for i in 0 ..< 5 {
                group.addTask {
                    _ = try? await mcpServer.register(
                        name: "concurrent_tool_\(i)",
                    ) { (_: HandlerContext) in "result_\(i)" }
                }
            }

            // Create new sessions concurrently
            for _ in 0 ..< 3 {
                group.addTask {
                    let pair = try? await createSessionPair(from: mcpServer)
                    if let pair {
                        // Let the session run briefly
                        try? await Task.sleep(for: .milliseconds(50))
                        await pair.client.disconnect()
                    }
                }
            }

            await group.waitForAll()
        }

        // Verify no crashes and existing sessions still work.
        // All 6 tools (1 base + 5 concurrent) should be visible.
        for pair in pairs {
            let result = try await pair.client.listTools()
            #expect(
                result.tools.count == 6,
                "All 6 tools (1 base + 5 concurrent) should be visible, but got \(result.tools.count)",
            )
        }

        // Clean up
        for pair in pairs {
            await pair.client.disconnect()
        }
    }
}
