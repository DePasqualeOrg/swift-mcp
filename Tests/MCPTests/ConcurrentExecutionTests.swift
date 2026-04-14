// Copyright © Anthony DePasquale

@testable import MCP
import Testing

/// Tests that verify server handlers execute concurrently.
///
/// These tests are based on Python SDK's `test_188_concurrency.py`:
/// - `test_messages_are_executed_concurrently_tools`
/// - `test_messages_are_executed_concurrently_tools_and_resources`
///
/// The pattern uses coordination primitives (events) to prove concurrent execution:
/// 1. First handler starts and waits on an event
/// 2. Second handler starts (only possible if handlers run concurrently)
/// 3. Second handler signals the event
/// 4. First handler completes
///
/// If handlers ran sequentially, the first handler would block forever
/// waiting for an event that the second handler (which never starts) should signal.
struct ConcurrentExecutionTests {
    // MARK: - Helper Types

    // MARK: - Concurrent Tool Execution Tests

    /// Tests that tool calls execute concurrently on the server.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - "trigger" tool starts (proves concurrency), waits for sleep to start, then signals
    /// - Both tools complete
    ///
    /// If execution were sequential, the sleep tool would block forever.
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Tool calls execute concurrently on server`() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"]),
                Tool(name: "trigger", description: "Triggers the event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            } else if request.name == "trigger" {
                // Wait for sleep tool to start before signaling
                await toolStarted.wait()
                await callOrder.append("trigger_started")
                await event.signal()
                await callOrder.append("trigger_end")
                return CallTool.Result(content: [.text("triggered")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the trigger tool (will signal the event)
        let triggerTask = Task {
            try await client.send(CallTool.request(.init(name: "trigger", arguments: nil)))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await triggerTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "trigger_started", "trigger_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)",
        )
    }

    /// Tests that tool and resource handlers execute concurrently.
    ///
    /// Based on Python SDK's `test_messages_are_executed_concurrently_tools_and_resources`.
    ///
    /// Pattern:
    /// - "sleep" tool starts and waits on an event
    /// - resource read starts (proves concurrency), signals the event
    /// - Both complete
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Tool and resource calls execute concurrently on server`() async throws {
        let event = AsyncEvent()
        let toolStarted = AsyncEvent()
        let callOrder = CallOrderTracker()

        let server = Server(
            name: "ConcurrentMixedServer",
            version: "1.0.0",
            capabilities: .init(resources: .init(), tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Waits for event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "sleep" {
                await callOrder.append("waiting_for_event")
                await toolStarted.signal()
                await event.wait()
                await callOrder.append("tool_end")
                return CallTool.Result(content: [.text("done")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(name: "Slow Resource", uri: "test://slow_resource"),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            if request.uri == "test://slow_resource" {
                // Wait for tool to start before signaling
                await toolStarted.wait()
                await event.signal()
                await callOrder.append("resource_end")
                return ReadResource.Result(contents: [
                    .text("slow", uri: "test://slow_resource"),
                ])
            }
            return ReadResource.Result(contents: [])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ConcurrentMixedClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start the sleep tool (will wait on event)
        let sleepTask = Task {
            try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
        }

        // Start the resource read (will signal the event)
        let resourceTask = Task {
            try await client.send(ReadResource.request(.init(uri: "test://slow_resource")))
        }

        // Wait for both to complete
        _ = try await sleepTask.value
        _ = try await resourceTask.value

        // Verify the order proves concurrent execution
        let events = await callOrder.events
        #expect(
            events == ["waiting_for_event", "resource_end", "tool_end"],
            "Expected concurrent execution order, but got: \(events)",
        )
    }

    /// Tests that multiple concurrent tool calls all execute in parallel.
    ///
    /// Pattern: Start N tools that all wait on a shared event, then signal it once.
    /// If sequential, only the first would run and block forever.
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Multiple concurrent tool calls all execute in parallel`() async throws {
        let event = AsyncEvent()
        let startedCount = CallCounter()
        let expectedConcurrency = 5

        let server = Server(
            name: "ParallelToolServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "wait_tool", description: "Waits for event", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            // Track that this handler started
            await startedCount.increment()

            // Wait for the event
            await event.wait()
            return CallTool.Result(content: [.text("done")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ParallelTestClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start multiple tool calls concurrently
        let tasks = (0 ..< expectedConcurrency).map { _ in
            Task {
                try await client.send(CallTool.request(.init(name: "wait_tool", arguments: nil)))
            }
        }

        // Wait for all handlers to start (proves they're running concurrently)
        var attempts = 0
        while await startedCount.value < expectedConcurrency, attempts < 100 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }

        let started = await startedCount.value
        #expect(
            started == expectedConcurrency,
            "All \(expectedConcurrency) handlers should have started concurrently, but only \(started) started",
        )

        // Signal the event to let all handlers complete
        await event.signal()

        // Wait for all tasks to complete
        for task in tasks {
            _ = try await task.value
        }
    }

    /// Tests that a tool throwing an error does not affect other concurrent tool calls.
    ///
    /// Pattern:
    /// - Start a "failing" tool and a "succeeding" tool concurrently
    /// - The failing tool throws after the succeeding tool starts (proving concurrency)
    /// - The succeeding tool completes normally despite the other tool's failure
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Concurrent tool error does not affect other tool calls`() async throws {
        let succeedingToolStarted = AsyncEvent()
        let succeedingToolCanFinish = AsyncEvent()

        let server = Server(
            name: "ErrorIsolationServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "failing", description: "Will throw", inputSchema: ["type": "object"]),
                Tool(name: "succeeding", description: "Will succeed", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "failing" {
                // Wait for the succeeding tool to start (proves concurrency)
                await succeedingToolStarted.wait()
                // Throw an error
                throw MCPError.internalError("Deliberate failure")
            } else if request.name == "succeeding" {
                await succeedingToolStarted.signal()
                // Wait for permission to finish (after the failing tool has thrown)
                await succeedingToolCanFinish.wait()
                return CallTool.Result(content: [.text("success")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ErrorIsolationClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start both tool calls concurrently
        let failingTask = Task {
            try await client.send(CallTool.request(.init(name: "failing", arguments: nil)))
        }

        let succeedingTask = Task {
            try await client.send(CallTool.request(.init(name: "succeeding", arguments: nil)))
        }

        // The failing tool's error is returned as a JSON-RPC error response,
        // which causes client.send() to throw.
        do {
            _ = try await failingTask.value
            Issue.record("Failing tool should throw an error")
        } catch {
            // Expected - the error propagates from the server handler
        }

        // Now let the succeeding tool finish
        await succeedingToolCanFinish.signal()

        let succeedResult = try await succeedingTask.value
        #expect(
            succeedResult.content.first != nil,
            "Succeeding tool should complete normally despite concurrent failure",
        )
        if case let .text(text, _, _) = succeedResult.content.first {
            #expect(text == "success")
        }
    }

    /// Tests that cancelling one tool call does not affect other concurrent tool calls.
    ///
    /// Pattern:
    /// - Start two tools concurrently, both block on events
    /// - Cancel the first tool call's task
    /// - Signal the second tool to finish
    /// - Verify the second tool completes normally
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Cancelling one tool call does not affect others`() async throws {
        let toolAStarted = AsyncEvent()
        let toolBStarted = AsyncEvent()
        let toolBCanFinish = AsyncEvent()

        let server = Server(
            name: "CancellationIsolationServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "tool_a", description: "Will be cancelled", inputSchema: ["type": "object"]),
                Tool(name: "tool_b", description: "Should succeed", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "tool_a" {
                await toolAStarted.signal()
                // Block forever (will be cancelled)
                try await Task.sleep(for: .seconds(300))
                return CallTool.Result(content: [.text("a_done")])
            } else if request.name == "tool_b" {
                await toolBStarted.signal()
                await toolBCanFinish.wait()
                return CallTool.Result(content: [.text("b_done")])
            }
            return CallTool.Result(content: [.text("unknown")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "CancellationClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Start both tool calls
        let taskA = Task {
            try await client.send(CallTool.request(.init(name: "tool_a", arguments: nil)))
        }

        let taskB = Task {
            try await client.send(CallTool.request(.init(name: "tool_b", arguments: nil)))
        }

        // Wait for both handlers to start
        await toolAStarted.wait()
        await toolBStarted.wait()

        // Cancel task A
        taskA.cancel()

        // Let task B finish
        await toolBCanFinish.signal()

        let resultB = try await taskB.value
        if case let .text(text, _, _) = resultB.content.first {
            #expect(text == "b_done", "Tool B should complete normally after Tool A is cancelled")
        } else {
            Issue.record("Expected text content from tool B")
        }
    }

    /// Wall-clock regression guard for the protocol message loop.
    ///
    /// Fires N tool calls whose handlers sleep for D seconds, then asserts
    /// total wall-clock is close to D rather than N·D. If the message loop
    /// ever re-serializes (e.g. by dropping the `TaskGroup` dispatch), this
    /// test is the one that catches it — the other concurrency tests block
    /// on events and would deadlock rather than measure overlap.
    ///
    /// `handlerCount` is tuned so that a partial-serialization regression
    /// (e.g. k-at-a-time with k < N) visibly exceeds the bound: with N=10
    /// and D=1s, fully parallel is ≈ 1s, 2-at-a-time is ≈ 5s, 5-at-a-time
    /// is ≈ 2s. The 2·D bound catches anything worse than roughly
    /// half-parallel.
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Parallel tool calls complete in approximately one handler duration`() async throws {
        let handlerCount = 10
        let handlerDuration: Duration = .seconds(1)

        let server = Server(
            name: "ParallelThroughputServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "sleep", description: "Sleeps for a fixed duration",
                     inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            try await Task.sleep(for: handlerDuration)
            return CallTool.Result(content: [.text("slept")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "ParallelThroughputClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< handlerCount {
                group.addTask {
                    _ = try await client.send(CallTool.request(.init(name: "sleep", arguments: nil)))
                }
            }
            try await group.waitForAll()
        }
        let elapsed = ContinuousClock.now - start

        let upperBound: Duration = handlerDuration * 2
        let lowerBound: Duration = handlerDuration * 9 / 10
        #expect(elapsed < upperBound,
                "\(handlerCount) parallel handlers should complete in ~\(handlerDuration), not \(handlerCount)×. Elapsed: \(elapsed)")
        #expect(elapsed >= lowerBound,
                "Handler should actually sleep; elapsed \(elapsed) < \(lowerBound) suggests the handler did not run its sleep.")
    }

    /// Drain-on-shutdown: in-flight handlers must be cancelled before
    /// `server.stop()` returns.
    ///
    /// Scope note: the cancellation here is delivered by `Server.stop()`'s
    /// own iteration over `inFlightHandlerTasks`, not by the TaskGroup's
    /// cancellation propagation inside `startProtocolMessageLoop`. This test
    /// guards the public `stop()` contract and would catch a regression that
    /// drops the `inFlightHandlerTasks` cancel loop or fails to call
    /// `stopProtocol()`. A regression that only dropped `group.waitForAll()`
    /// from the message loop would not be caught here — the dispatch shims
    /// are too short to exercise it.
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Server stop cancels in-flight handlers and drains them`() async throws {
        let handlerStarted = AsyncEvent()
        let handlerObservedCancellation = AsyncEvent()

        let server = Server(
            name: "DrainOnShutdownServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "block", description: "Blocks forever until cancelled",
                     inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { _, _ in
            await handlerStarted.signal()
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                // Task.sleep throws CancellationError on cancel — surface it.
                if Task.isCancelled {
                    await handlerObservedCancellation.signal()
                }
                throw error
            }
            return CallTool.Result(content: [.text("unreachable")])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "DrainOnShutdownClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Fire a call that will block in the handler. We don't await its result
        // — the server will cancel it during stop().
        let blockedTask = Task {
            try await client.send(CallTool.request(.init(name: "block", arguments: nil)))
        }

        await handlerStarted.wait()

        // Shut the server down. This must cancel the in-flight handler task
        // and not return until the TaskGroup has drained.
        await server.stop()

        // Handler should observe cancellation.
        await handlerObservedCancellation.wait()

        #expect(await handlerObservedCancellation.isSignaled,
                "In-flight handler must observe Task.isCancelled when the server stops")

        // Clean up the blocked client task (its response will come back as an
        // error once the connection is closed, or it will simply fail).
        blockedTask.cancel()
        _ = try? await blockedTask.value
    }

    /// Regression guard for the `.connected` state guard in
    /// `Server.handleIncomingRequest`. Under parallel dispatch, a shim for
    /// a second request arriving while `server.stop()` is in progress could
    /// repopulate `inFlightHandlerTasks` after the stop-time clear — the
    /// new unstructured handler Task would then escape both TaskGroup
    /// cancellation (it's unstructured) and the stop-time cancel loop
    /// (already ran).
    ///
    /// The `.connected` guard prevents this: once the Server actor flips to
    /// `.disconnecting` (synchronously in `stopProtocol`), any dispatch shim
    /// that subsequently runs sees the state and drops the request instead
    /// of registering a new handler.
    ///
    /// Scope: this test cannot determine from the client side whether a
    /// particular second-request arrived before or after the state flip, so
    /// it asserts only the stable post-stop invariant: the in-flight map
    /// must be empty. A regression that removes the guard or moves the
    /// state flip after the loop drain would reliably fail this assertion
    /// because late shims would register into the already-cleared map.
    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Server.stop leaves inFlightHandlerTasks empty under parallel dispatch`() async throws {
        let firstHandlerStarted = AsyncEvent()
        let firstHandlerCanFinish = AsyncEvent()

        let server = Server(
            name: "DisconnectingGuardServer",
            version: "1.0.0",
            capabilities: .init(tools: .init()),
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "first", description: "Blocks until released",
                     inputSchema: ["type": "object"]),
                Tool(name: "second", description: "Arrives during stop",
                     inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { request, _ in
            if request.name == "first" {
                await firstHandlerStarted.signal()
                await firstHandlerCanFinish.wait()
                return CallTool.Result(content: [.text("first-ok")])
            } else {
                return CallTool.Result(content: [.text("second-ok")])
            }
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "DisconnectingGuardClient", version: "1.0")

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        // Fire the first (blocking) call so stop() has something to cancel
        // and drain.
        let firstTask = Task {
            try? await client.send(CallTool.request(.init(name: "first", arguments: nil)))
        }
        await firstHandlerStarted.wait()

        let stopTask = Task { await server.stop() }

        // Fire a second call during stop. Its dispatch shim may or may not
        // beat the state flip — that's intentionally nondeterministic. The
        // test only asserts the post-stop invariant below.
        let secondTask = Task {
            try? await client.send(CallTool.request(.init(name: "second", arguments: nil)))
        }

        await firstHandlerCanFinish.signal()
        _ = await stopTask.value
        _ = await firstTask.value
        _ = await secondTask.value

        let inFlightAfterStop = await server.registeredHandlers.inFlightHandlerTasks.count
        #expect(inFlightAfterStop == 0,
                "inFlightHandlerTasks must be empty after server.stop() returns. Got: \(inFlightAfterStop)")
    }
}
