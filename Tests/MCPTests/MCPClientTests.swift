// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Tests for MCPClient, the high-level client that provides automatic reconnection,
/// health monitoring, and transparent retry on recoverable errors.
struct MCPClientTests {
    // MARK: - Helpers

    /// Manages an MCPServer and tracks server-side transports for test control.
    actor TestServerManager {
        let mcpServer: MCPServer
        private var serverTransports: [InMemoryTransport] = []
        private var serverSessions: [Server] = []

        init() {
            mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        }

        /// Creates a client transport connected to a fresh server session.
        func createClientTransport() async throws -> InMemoryTransport {
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            let session = await mcpServer.createSession()
            try await session.start(transport: serverTransport)
            serverTransports.append(serverTransport)
            serverSessions.append(session)
            return clientTransport
        }

        /// Disconnects the most recent server transport to simulate connection loss.
        func severLatestConnection() async {
            if let transport = serverTransports.last {
                await transport.disconnect()
            }
        }
    }

    /// Collects state transitions for verification.
    actor StateCollector {
        var states: [MCPClient.ConnectionState] = []
        func append(_ state: MCPClient.ConnectionState) {
            states.append(state)
        }

        func get() -> [MCPClient.ConnectionState] {
            states
        }
    }

    /// Collects tool lists from onToolsChanged callbacks.
    actor ToolCollector {
        var toolLists: [[Tool]] = []
        func append(_ tools: [Tool]) {
            toolLists.append(tools)
        }

        func get() -> [[Tool]] {
            toolLists
        }
    }

    // MARK: - State Transition Tests

    @Test
    func `State transitions during successful connect`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
            description: "Echo tool",
        ) { (_: HandlerContext) in "hello" }

        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        let states = await collector.get()
        #expect(states == [.connecting, .connected])
        #expect(await mcpClient.state == .connected)

        await mcpClient.disconnect()
    }

    @Test
    func `State transitions during failed connect`() async throws {
        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        // Transport factory that always fails
        await #expect(throws: Error.self) {
            try await mcpClient.connect {
                throw MCPError.internalError("Connection refused")
            }
        }

        let states = await collector.get()
        #expect(states == [.connecting, .disconnected])
        #expect(await mcpClient.state == .disconnected)
    }

    @Test
    func `Disconnect transitions to disconnected state`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        #expect(await mcpClient.state == .connected)

        await mcpClient.disconnect()
        #expect(await mcpClient.state == .disconnected)
    }

    // MARK: - onStateChanged Callback Tests

    @Test
    func `onStateChanged fires on each transition with correct value`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        // Connect
        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Disconnect
        await mcpClient.disconnect()

        let states = await collector.get()
        #expect(states == [.connecting, .connected, .disconnected])
    }

    // MARK: - Transparent Retry Tests

    @Test
    func `Non-recoverable errors propagate immediately without reconnection`() async throws {
        let manager = TestServerManager()

        // Register a tool that returns an error
        _ = try await manager.mcpServer.register(
            name: "failing_tool",
        ) { (_: HandlerContext) -> String in
            throw MCPError.invalidParams("Bad input")
        }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Tool execution errors are returned as isError: true in the result, not thrown
        let result = try await mcpClient.callTool(name: "failing_tool")
        #expect(result.isError == true)

        // Verify still connected (no reconnection triggered)
        #expect(await mcpClient.state == .connected)

        await mcpClient.disconnect()
    }

    @Test
    func `Calling tool when not connected throws connectionClosed`() async throws {
        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await #expect(throws: MCPError.self) {
            _ = try await mcpClient.callTool(name: "any_tool")
        }
    }

    // MARK: - Reconnection Tests

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Reconnection on connection loss via pending request`() async throws {
        let callCount = CallCounter()
        let firstCallStarted = AsyncEvent()

        let manager = TestServerManager()

        // Register a tool that blocks on first call, responds immediately on subsequent calls
        _ = try await manager.mcpServer.register(
            name: "smart_tool",
        ) { (_: HandlerContext) -> String in
            let n = await callCount.increment()
            if n == 1 {
                await firstCallStarted.signal()
                // Block until the connection is severed (sleep will be interrupted)
                try? await Task.sleep(for: .seconds(30))
                return "first"
            } else {
                return "reconnected"
            }
        }

        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                maxRetries: 3,
                initialDelay: .milliseconds(10),
                maxDelay: .milliseconds(100),
                delayGrowFactor: 2.0,
                healthCheckInterval: nil,
            ),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Start a tool call that will block
        let callTask = Task {
            try await mcpClient.callTool(name: "smart_tool")
        }

        // Wait for the first call to start
        await firstCallStarted.wait()
        // Give the request a moment to be fully registered
        try await Task.sleep(for: .milliseconds(50))

        // Sever the connection - the pending request will get connectionClosed
        await manager.severLatestConnection()

        // The callTask should complete after reconnection + retry
        let result = try await callTask.value
        let firstText = result.content.first
        if case let .text(text, _, _) = firstText {
            #expect(text == "reconnected")
        } else {
            Issue.record("Expected text content")
        }

        // Verify state transitions included reconnecting
        let states = await collector.get()
        #expect(states.contains(.connecting))
        #expect(states.contains(.connected))
        let hasReconnecting = states.contains { state in
            if case .reconnecting = state { return true }
            return false
        }
        #expect(hasReconnecting, "Expected a .reconnecting state during reconnection")

        await mcpClient.disconnect()
    }

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Max retries exceeded leads to disconnected state`() async throws {
        let manager = TestServerManager()

        // Register a tool so the server is functional for initial connection
        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let collector = StateCollector()
        let factoryCallCount = CallCounter()
        let firstCallStarted = AsyncEvent()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                maxRetries: 2,
                initialDelay: .milliseconds(10),
                maxDelay: .milliseconds(50),
                delayGrowFactor: 1.5,
                healthCheckInterval: nil,
            ),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        // First call succeeds, subsequent calls fail (simulating factory failure during reconnection)
        try await mcpClient.connect {
            let n = await factoryCallCount.increment()
            if n == 1 {
                return try await manager.createClientTransport()
            } else {
                throw MCPError.internalError("Cannot connect")
            }
        }

        // Register a blocking tool
        _ = try await manager.mcpServer.register(
            name: "blocking_tool",
        ) { (_: HandlerContext) -> String in
            await firstCallStarted.signal()
            try? await Task.sleep(for: .seconds(30))
            return "done"
        }

        // Start a blocking call
        let callTask = Task {
            try await mcpClient.callTool(name: "blocking_tool")
        }

        await firstCallStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        // Sever the connection
        await manager.severLatestConnection()

        // The call should fail after max retries are exhausted
        do {
            _ = try await callTask.value
            Issue.record("Expected error after max retries")
        } catch {
            // Expected
        }

        // Verify final state is disconnected
        let states = await collector.get()
        let lastState = states.last
        #expect(lastState == .disconnected)
    }

    // MARK: - Deduplication Tests

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Multiple concurrent failures trigger only one reconnection`() async throws {
        let toolCallCount = CallCounter()
        let allToolsStarted = AsyncEvent()

        let manager = TestServerManager()

        // Track how many times the transport factory is called during reconnection
        let factoryCallCount = CallCounter()

        // Register a tool that blocks on all initial calls, then succeeds after reconnection
        _ = try await manager.mcpServer.register(
            name: "blocking_tool",
        ) { (_: HandlerContext) -> String in
            let n = await toolCallCount.increment()
            if n <= 3 {
                // First 3 calls: block until connection is severed
                if n == 3 {
                    await allToolsStarted.signal()
                }
                try? await Task.sleep(for: .seconds(30))
                return "blocked"
            } else {
                // After reconnection: return immediately
                return "retried"
            }
        }

        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                maxRetries: 3,
                initialDelay: .milliseconds(10),
                maxDelay: .milliseconds(100),
                delayGrowFactor: 2.0,
                healthCheckInterval: nil,
            ),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        try await mcpClient.connect {
            let n = await factoryCallCount.increment()
            if n == 1 {
                return try await manager.createClientTransport()
            } else {
                // Reconnection calls also go through the factory
                return try await manager.createClientTransport()
            }
        }

        // Start 3 concurrent tool calls that will all block
        let task1 = Task { try await mcpClient.callTool(name: "blocking_tool") }
        let task2 = Task { try await mcpClient.callTool(name: "blocking_tool") }
        let task3 = Task { try await mcpClient.callTool(name: "blocking_tool") }

        // Wait for all 3 tool handlers to start
        await allToolsStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        // Sever the connection - all 3 calls will fail concurrently
        await manager.severLatestConnection()

        // All 3 tasks should complete (via reconnection + retry)
        _ = try await task1.value
        _ = try await task2.value
        _ = try await task3.value

        // Count the number of distinct reconnection sequences.
        // Each sequence starts with .reconnecting(attempt: 1).
        // With deduplication, there should be exactly one sequence.
        let states = await collector.get()
        let reconnectingAttempt1Count = states.count(where: { $0 == .reconnecting(attempt: 1) })
        #expect(
            reconnectingAttempt1Count == 1,
            "Multiple concurrent failures should trigger only one reconnection, but got \(reconnectingAttempt1Count) sequences",
        )

        // The transport factory should have been called exactly twice:
        // once for initial connect, once for reconnection
        let totalFactoryCalls = await factoryCallCount.value
        #expect(
            totalFactoryCalls == 2,
            "Transport factory should be called twice (initial + one reconnection), but was called \(totalFactoryCalls) times",
        )

        await mcpClient.disconnect()
    }

    // MARK: - onToolsChanged Callback Tests

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `onToolsChanged fires after reconnection`() async throws {
        let callCount = CallCounter()
        let firstCallStarted = AsyncEvent()
        let toolCollector = ToolCollector()

        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "persistent_tool",
            description: "A tool that persists across reconnections",
        ) { (_: HandlerContext) -> String in
            let n = await callCount.increment()
            if n == 1 {
                await firstCallStarted.signal()
                try? await Task.sleep(for: .seconds(30))
                return "first"
            } else {
                return "reconnected"
            }
        }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                maxRetries: 3,
                initialDelay: .milliseconds(10),
                maxDelay: .milliseconds(100),
                delayGrowFactor: 2.0,
                healthCheckInterval: nil,
            ),
        )

        await mcpClient.setOnToolsChanged { tools in
            await toolCollector.append(tools)
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Start a blocking call to trigger reconnection
        let callTask = Task {
            try await mcpClient.callTool(name: "persistent_tool")
        }

        await firstCallStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        await manager.severLatestConnection()

        _ = try await callTask.value

        // Verify onToolsChanged was called after reconnection
        let toolLists = await toolCollector.get()
        #expect(!toolLists.isEmpty, "onToolsChanged should have fired after reconnection")
        if let tools = toolLists.last {
            let toolNames = tools.map(\.name)
            #expect(toolNames.contains("persistent_tool"))
        }

        await mcpClient.disconnect()
    }

    @Test
    func `onToolsChanged fires on ToolListChangedNotification`() async throws {
        let toolCollector = ToolCollector()
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "initial_tool",
        ) { (_: HandlerContext) in "hello" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await mcpClient.setOnToolsChanged { tools in
            await toolCollector.append(tools)
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Register another tool on the server (this triggers ToolListChangedNotification)
        _ = try await manager.mcpServer.register(
            name: "new_tool",
        ) { (_: HandlerContext) in "world" }

        // Wait for the notification to be delivered and processed
        let received = await pollUntil { await !(toolCollector.get()).isEmpty }
        #expect(received, "onToolsChanged should fire on ToolListChangedNotification")

        await mcpClient.disconnect()
    }

    // MARK: - Health Check Tests

    @Test
    func `Health check disabled when interval is nil`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Wait a bit to ensure no health checks are sent
        try await Task.sleep(for: .milliseconds(100))

        // Still connected, no reconnection triggered
        #expect(await mcpClient.state == .connected)

        await mcpClient.disconnect()
    }

    // MARK: - Handler Persistence Tests

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Handlers registered on client survive reconnection`() async throws {
        let callCount = CallCounter()
        let firstCallStarted = AsyncEvent()
        let notificationReceived = AsyncEvent()

        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "smart_tool",
        ) { (_: HandlerContext) -> String in
            let n = await callCount.increment()
            if n == 1 {
                await firstCallStarted.signal()
                try? await Task.sleep(for: .seconds(30))
                return "first"
            } else {
                return "reconnected"
            }
        }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                maxRetries: 3,
                initialDelay: .milliseconds(10),
                maxDelay: .milliseconds(100),
                delayGrowFactor: 2.0,
                healthCheckInterval: nil,
            ),
        )

        // Register a notification handler BEFORE connecting
        await mcpClient.client.onNotification(ToolListChangedNotification.self) { _ in
            await notificationReceived.signal()
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Start a blocking call to trigger reconnection
        let callTask = Task {
            try await mcpClient.callTool(name: "smart_tool")
        }

        await firstCallStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        await manager.severLatestConnection()
        _ = try await callTask.value

        // After reconnection, register a new tool to trigger ToolListChangedNotification
        _ = try await manager.mcpServer.register(
            name: "post_reconnect_tool",
        ) { (_: HandlerContext) in "new" }

        // Wait for the notification handler (registered before first connection) to fire
        var received = false
        for _ in 0 ..< 50 {
            try await Task.sleep(for: .milliseconds(50))
            received = await notificationReceived.isSignaled
            if received { break }
        }

        #expect(received, "Notification handler registered before first connection should survive reconnection")
        #expect(await mcpClient.state == .connected)

        await mcpClient.disconnect()
    }

    // MARK: - Disconnect Tests

    @Test
    func `Disconnect cancels health checks and reconnection tasks`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(
                healthCheckInterval: .milliseconds(50),
            ),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Give health check a chance to start
        try await Task.sleep(for: .milliseconds(30))

        // Disconnect should cancel everything cleanly
        await mcpClient.disconnect()
        #expect(await mcpClient.state == .disconnected)

        // Ensure no further state changes after disconnect
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mcpClient.state == .disconnected)
    }

    @Test
    func `Can reconnect after disconnect`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        // First connect
        try await mcpClient.connect {
            try await manager.createClientTransport()
        }
        #expect(await mcpClient.state == .connected)

        // Disconnect
        await mcpClient.disconnect()
        #expect(await mcpClient.state == .disconnected)

        // Reconnect
        try await mcpClient.connect {
            try await manager.createClientTransport()
        }
        #expect(await mcpClient.state == .connected)

        // Verify the new connection works
        let result = try await mcpClient.callTool(name: "echo")
        if case let .text(text, _, _) = result.content.first {
            #expect(text == "hello")
        } else {
            Issue.record("Expected text content")
        }

        await mcpClient.disconnect()
    }

    // MARK: - Protocol Method Forwarding Tests

    @Test
    func `listTools forwards to underlying client`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "tool_a",
            description: "First tool",
        ) { (_: HandlerContext) in "a" }

        _ = try await manager.mcpServer.register(
            name: "tool_b",
            description: "Second tool",
        ) { (_: HandlerContext) in "b" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        let result = try await mcpClient.listTools()
        let names = result.tools.map(\.name).sorted()
        #expect(names == ["tool_a", "tool_b"])

        await mcpClient.disconnect()
    }

    @Test
    func `callTool executes tool and returns result`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "greet",
        ) { (_: HandlerContext) in "Hello, World!" }

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        let result = try await mcpClient.callTool(name: "greet")
        if case let .text(text, _, _) = result.content.first {
            #expect(text == "Hello, World!")
        } else {
            Issue.record("Expected text content")
        }

        await mcpClient.disconnect()
    }

    @Test
    func `ping does not trigger reconnection on failure`() async throws {
        let manager = TestServerManager()

        _ = try await manager.mcpServer.register(
            name: "echo",
        ) { (_: HandlerContext) in "hello" }

        let collector = StateCollector()

        let mcpClient = MCPClient(
            name: "test-client",
            version: "1.0",
            reconnectionOptions: .init(healthCheckInterval: nil),
        )

        await mcpClient.setOnStateChanged { state in
            await collector.append(state)
        }

        try await mcpClient.connect {
            try await manager.createClientTransport()
        }

        // Clear the state collector to only track post-sever transitions
        let statesBefore = await collector.get()
        #expect(statesBefore == [.connecting, .connected])

        // Sever the connection
        await manager.severLatestConnection()

        // Give the receive loop time to exit
        try await Task.sleep(for: .milliseconds(50))

        // Ping should fail because the transport is dead
        await #expect(throws: Error.self) {
            try await mcpClient.ping()
        }

        // Wait to verify no reconnection is triggered
        try await Task.sleep(for: .milliseconds(200))

        // ping() does not use withReconnection, so no .reconnecting state should appear
        let statesAfter = await collector.get()
        let hasReconnecting = statesAfter.contains { state in
            if case .reconnecting = state { return true }
            return false
        }
        #expect(!hasReconnecting, "ping() should not trigger reconnection")

        await mcpClient.disconnect()
    }

    // MARK: - ReconnectionOptions Tests

    @Test
    func `Default reconnection options`() {
        let options = MCPClient.ReconnectionOptions.default
        #expect(options.maxRetries == 3)
        #expect(options.initialDelay == .seconds(1))
        #expect(options.maxDelay == .seconds(30))
        #expect(options.delayGrowFactor == 2.0)
        #expect(options.healthCheckInterval == .seconds(60))
    }

    @Test
    func `Custom reconnection options`() {
        let options = MCPClient.ReconnectionOptions(
            maxRetries: 5,
            initialDelay: .milliseconds(500),
            maxDelay: .seconds(10),
            delayGrowFactor: 3.0,
            healthCheckInterval: .seconds(30),
        )
        #expect(options.maxRetries == 5)
        #expect(options.initialDelay == .milliseconds(500))
        #expect(options.maxDelay == .seconds(10))
        #expect(options.delayGrowFactor == 3.0)
        #expect(options.healthCheckInterval == .seconds(30))
    }

    @Test
    func `ConnectionState equatable conformance`() {
        #expect(MCPClient.ConnectionState.disconnected == .disconnected)
        #expect(MCPClient.ConnectionState.connecting == .connecting)
        #expect(MCPClient.ConnectionState.connected == .connected)
        #expect(MCPClient.ConnectionState.reconnecting(attempt: 1) == .reconnecting(attempt: 1))
        #expect(MCPClient.ConnectionState.reconnecting(attempt: 1) != .reconnecting(attempt: 2))
        #expect(MCPClient.ConnectionState.connected != .disconnected)
    }
}
