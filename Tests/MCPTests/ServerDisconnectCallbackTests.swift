// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Tests for Server.setOnDisconnect callback behavior.
struct ServerDisconnectCallbackTests {
    // MARK: - Helpers

    func createServer() -> Server {
        Server(
            name: "test-server",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true)),
        )
    }

    // MARK: - Callback Invocation

    @Test
    func `Callback invoked on transport disconnect`() async throws {
        let server = createServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor Flag {
            var value = false
            func set() {
                value = true
            }

            func get() -> Bool {
                value
            }
        }

        let disconnectCalled = Flag()

        await server.setOnDisconnect {
            await disconnectCalled.set()
        }

        // Register a minimal handler so the server can start
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Connect a client
        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        // Disconnect the client transport
        await clientTransport.disconnect()

        // Wait for the server's message loop to notice and call onDisconnect
        let wasCalled = await pollUntil { await disconnectCalled.get() }
        #expect(wasCalled, "onDisconnect callback should be invoked when transport disconnects")
    }

    @Test
    func `Callback invoked when server transport disconnects`() async throws {
        let server = createServer()
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor Flag {
            var value = false
            func set() {
                value = true
            }

            func get() -> Bool {
                value
            }
        }

        let disconnectCalled = Flag()

        await server.setOnDisconnect {
            await disconnectCalled.set()
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Disconnect from the server side
        await serverTransport.disconnect()

        let wasCalled = await pollUntil { await disconnectCalled.get() }
        #expect(wasCalled, "onDisconnect callback should be invoked when server transport disconnects")
    }

    @Test
    func `Callback not invoked during normal operation`() async throws {
        let server = createServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor Counter {
            var count = 0
            func increment() {
                count += 1
            }

            func get() -> Int {
                count
            }
        }

        let callCount = Counter()

        await server.setOnDisconnect {
            await callCount.increment()
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_tool", description: "A test tool", inputSchema: ["type": "object"]),
            ])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        // Make some requests (normal operation)
        let result = try await client.listTools()
        #expect(result.tools.count == 1)

        try await client.ping()

        // Wait and verify the callback was NOT called
        try await Task.sleep(for: .milliseconds(100))

        let count = await callCount.get()
        #expect(count == 0, "onDisconnect should not be called during normal operation")

        // Clean up
        await client.disconnect()
    }

    @Test
    func `Nil callback does not cause issues on disconnect`() async throws {
        let server = createServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Explicitly set to nil
        await server.setOnDisconnect(nil)

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        // Disconnect - should not crash even with nil callback
        await clientTransport.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        // No assertion needed - test passes if no crash occurs
    }

    @Test
    func `Callback can be replaced before disconnect`() async throws {
        let server = createServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor Tracker {
            var firstCalled = false
            var secondCalled = false
            func markFirst() {
                firstCalled = true
            }

            func markSecond() {
                secondCalled = true
            }

            func getFirst() -> Bool {
                firstCalled
            }

            func getSecond() -> Bool {
                secondCalled
            }
        }

        let tracker = Tracker()

        // Set first callback
        await server.setOnDisconnect {
            await tracker.markFirst()
        }

        // Replace with second callback
        await server.setOnDisconnect {
            await tracker.markSecond()
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0")
        try await client.connect(transport: clientTransport)

        await clientTransport.disconnect()

        let secondCalled = await pollUntil { await tracker.getSecond() }
        #expect(secondCalled, "Replaced callback should be called on disconnect")

        let firstCalled = await tracker.getFirst()
        #expect(!firstCalled, "First callback should not be called after replacement")
    }

    @Test
    func `Callback invoked after server stop`() async throws {
        let server = createServer()
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        actor Flag {
            var value = false
            func set() {
                value = true
            }

            func get() -> Bool {
                value
            }
        }

        let disconnectCalled = Flag()

        await server.setOnDisconnect {
            await disconnectCalled.set()
        }

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // stop() cancels the message loop task and disconnects the transport,
        // which causes the message loop to exit and invoke onDisconnect
        await server.stop()

        let wasCalled = await pollUntil { await disconnectCalled.get() }
        #expect(wasCalled, "onDisconnect callback should be invoked when server is stopped")
    }
}
