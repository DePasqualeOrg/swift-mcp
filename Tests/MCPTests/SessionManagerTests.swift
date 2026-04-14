// Copyright © Anthony DePasquale

@testable import MCP
import Testing

/// Tests for SessionManager - a thread-safe session storage helper.
///
/// These tests follow the TypeScript SDK's pattern for session management.
struct SessionManagerTests {
    // MARK: - Basic Operations

    @Test
    func `Initialization creates empty manager`() async {
        let manager = SessionManager()
        let count = await manager.activeSessionCount
        #expect(count == 0)
    }

    @Test
    func `Max sessions configuration`() async {
        let manager = SessionManager(maxSessions: 5)
        let max = await manager.maxSessions
        #expect(max == 5)
    }

    @Test
    func `Store and retrieve transport`() async {
        let manager = SessionManager()
        let transport = HTTPServerTransport()

        await manager.store(transport, forSessionId: "test-session-1")

        let retrieved = await manager.transport(forSessionId: "test-session-1")
        #expect(retrieved != nil)

        let count = await manager.activeSessionCount
        #expect(count == 1)
    }

    @Test
    func `Transport not found returns nil`() async {
        let manager = SessionManager()

        let retrieved = await manager.transport(forSessionId: "nonexistent")
        #expect(retrieved == nil)
    }

    @Test
    func `Remove transport`() async {
        let manager = SessionManager()
        let transport = HTTPServerTransport()

        await manager.store(transport, forSessionId: "test-session")

        var count = await manager.activeSessionCount
        #expect(count == 1)

        await manager.remove("test-session")

        count = await manager.activeSessionCount
        #expect(count == 0)

        let retrieved = await manager.transport(forSessionId: "test-session")
        #expect(retrieved == nil)
    }

    @Test
    func `Active session IDs`() async {
        let manager = SessionManager()

        await manager.store(HTTPServerTransport(), forSessionId: "session-a")
        await manager.store(HTTPServerTransport(), forSessionId: "session-b")
        await manager.store(HTTPServerTransport(), forSessionId: "session-c")

        let ids = await manager.activeSessionIds
        #expect(ids.sorted() == ["session-a", "session-b", "session-c"])
    }

    @Test
    func `Close all sessions`() async {
        let manager = SessionManager()

        await manager.store(HTTPServerTransport(), forSessionId: "session-1")
        await manager.store(HTTPServerTransport(), forSessionId: "session-2")

        var count = await manager.activeSessionCount
        #expect(count == 2)

        await manager.closeAll()

        count = await manager.activeSessionCount
        #expect(count == 0)
    }

    // MARK: - Capacity Limits

    @Test
    func `Capacity check`() async {
        let manager = SessionManager(maxSessions: 2)

        // Initially can add
        var canAdd = await manager.canAddSession()
        #expect(canAdd == true)

        // Add two sessions
        await manager.store(HTTPServerTransport(), forSessionId: "session-1")
        await manager.store(HTTPServerTransport(), forSessionId: "session-2")

        // Now at capacity
        canAdd = await manager.canAddSession()
        #expect(canAdd == false)

        // Remove one
        await manager.remove("session-1")

        // Can add again
        canAdd = await manager.canAddSession()
        #expect(canAdd == true)
    }

    @Test
    func `Unlimited capacity`() async {
        let manager = SessionManager() // No maxSessions

        // Add many sessions
        for i in 0 ..< 100 {
            await manager.store(HTTPServerTransport(), forSessionId: "session-\(i)")
        }

        // Should still be able to add
        let canAdd = await manager.canAddSession()
        #expect(canAdd == true)

        let count = await manager.activeSessionCount
        #expect(count == 100)
    }

    // MARK: - Session Cleanup

    @Test
    func `Cleanup stale sessions`() async throws {
        let manager = SessionManager()

        // Store some sessions
        await manager.store(HTTPServerTransport(), forSessionId: "old-session")

        // Wait a small amount to ensure the session activity time is in the past
        try await Task.sleep(for: .milliseconds(10))

        // Clean up with zero timeout - should remove all sessions since they're now "stale"
        let removed = await manager.cleanUpStaleSessions(olderThan: .zero)
        #expect(removed == 1)

        let count = await manager.activeSessionCount
        #expect(count == 0)
    }

    @Test
    func `Recent session not cleaned`() async {
        let manager = SessionManager()

        await manager.store(HTTPServerTransport(), forSessionId: "recent-session")

        // Clean up with long timeout - should not remove recent session
        let removed = await manager.cleanUpStaleSessions(olderThan: .seconds(3600))
        #expect(removed == 0)

        let count = await manager.activeSessionCount
        #expect(count == 1)
    }

    // MARK: - Multi-Client Simulation

    @Test
    func `Multiple clients sequential`() async {
        let manager = SessionManager()

        // Simulate 10 clients connecting sequentially
        for i in 0 ..< 10 {
            let transport = HTTPServerTransport()
            await manager.store(transport, forSessionId: "session-\(i)")
        }

        let count = await manager.activeSessionCount
        #expect(count == 10)

        let ids = await manager.activeSessionIds
        #expect(ids.count == 10)
    }

    @Test
    func `Multiple clients concurrent`() async {
        let manager = SessionManager()

        // Simulate 10 clients connecting concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 10 {
                group.addTask {
                    let transport = HTTPServerTransport()
                    await manager.store(transport, forSessionId: "concurrent-session-\(i)")
                }
            }
        }

        let count = await manager.activeSessionCount
        #expect(count == 10)
    }

    @Test
    func `Concurrent access and removal`() async {
        let manager = SessionManager()

        // Pre-populate with sessions
        for i in 0 ..< 20 {
            await manager.store(HTTPServerTransport(), forSessionId: "session-\(i)")
        }

        // Concurrently access and remove sessions
        await withTaskGroup(of: Void.self) { group in
            // Readers
            for i in 0 ..< 10 {
                group.addTask {
                    _ = await manager.transport(forSessionId: "session-\(i)")
                }
            }

            // Removers
            for i in 10 ..< 20 {
                group.addTask {
                    await manager.remove("session-\(i)")
                }
            }
        }

        let count = await manager.activeSessionCount
        #expect(count == 10) // Only the first 10 should remain
    }
}
