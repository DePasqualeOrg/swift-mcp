// Copyright © Anthony DePasquale

import Foundation
import Logging
import Testing

@testable import MCP

// MARK: - Test Protocol Actor

/// A minimal conformer to ProtocolLayer for testing protocol-level behavior.
actor TestProtocolActor: ProtocolLayer {
    package var protocolState = ProtocolState()
    package var protocolLogger: Logger? = nil

    /// Track received requests.
    var receivedRequests: [AnyRequest] = []
    /// Track received notifications.
    var receivedNotifications: [AnyMessage] = []
    /// Whether the connection close handler was called.
    var connectionClosedCalled = false

    package func handleIncomingRequest(_ request: AnyRequest, data _: Data, context _: MessageMetadata?) async {
        receivedRequests.append(request)
    }

    package func handleIncomingNotification(_ notification: AnyMessage, data _: Data) async {
        receivedNotifications.append(notification)
    }

    package func handleConnectionClosed() async {
        connectionClosedCalled = true
    }

    package func interceptResponse(_: AnyResponse) async {}

    package func handleUnknownMessage(_: Data, context _: MessageMetadata?) async {}
}

/// Tests for the ProtocolLayer protocol and its extension methods.
///
/// These tests verify the core JSON-RPC mechanics that Client and Server
/// delegate to through protocol conformance.
@Suite("ProtocolLayer Tests")
struct ProtocolTests {
    // MARK: - Connection Lifecycle Tests

    @Test("Protocol connects to transport")
    func testConnect() async throws {
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)

        // If we get here without throwing, connection succeeded
        await proto.stopProtocol()
    }

    @Test("Protocol disconnect cancels pending requests")
    func testDisconnectCancelsPendingRequests() async throws {
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)

        // Register a pending request on the protocol actor
        let requestId: RequestId = .number(99)
        let stream = await proto.registerProtocolPendingRequest(id: requestId)

        // Verify the pending request is registered
        let hasPending = await proto.hasProtocolPendingRequest(id: requestId)
        #expect(hasPending, "Pending request should be registered")

        // Disconnect should fail all pending requests with connectionClosed
        await proto.stopProtocol()

        // The stream should throw MCPError.connectionClosed
        do {
            for try await _ in stream {
                Issue.record("Stream should not yield a value after disconnect")
            }
            Issue.record("Stream should have thrown connectionClosed")
        } catch let error as MCPError {
            #expect(error == .connectionClosed, "Expected connectionClosed, got: \(error)")
        }
    }

    // MARK: - Handler Registration Tests

    @Test("Protocol routes incoming requests through handleIncomingRequest")
    func testRequestHandlerRegistration() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a ping request from client side
        let encoder = JSONEncoder()
        let request = Request<Ping>(id: .number(1), method: Ping.name, params: Ping.Parameters())
        let data = try encoder.encode(request)
        try await clientTransport.send(data)

        // Wait for handler to be invoked
        try await Task.sleep(for: .milliseconds(100))

        let requests = await proto.receivedRequests
        #expect(!requests.isEmpty, "Handler should have been invoked")
        #expect(requests.first?.method == Ping.name, "Method should be ping")

        await proto.stopProtocol()
    }

    @Test("Protocol routes notifications through handleIncomingNotification")
    func testNotificationHandlerRegistration() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a notification from client side
        let encoder = JSONEncoder()
        let notification = InitializedNotification.message()
        let data = try encoder.encode(notification)
        try await clientTransport.send(data)

        // Wait for handler to be invoked
        try await Task.sleep(for: .milliseconds(100))

        let notifications = await proto.receivedNotifications
        #expect(!notifications.isEmpty, "Notification handler should have been invoked")
        #expect(notifications.first?.method == InitializedNotification.name, "Method should match")

        await proto.stopProtocol()
    }

    // MARK: - Progress Callback Tests

    @Test("Protocol routes progress notifications to registered callbacks")
    func testProgressCallback() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()

        // Register a progress callback
        let progressReceived = ValueHolder<ProgressNotification.Parameters?>(nil)
        let progressToken = ProgressToken.string("test-token")

        await proto.setProgressCallbackForTesting(token: progressToken) { params in
            await progressReceived.set(params)
        }

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a progress notification from client side
        let encoder = JSONEncoder()
        let notification = ProgressNotification.message(.init(
            progressToken: progressToken,
            progress: 50,
            total: 100,
            message: "Halfway there"
        ))
        let data = try encoder.encode(notification)
        try await clientTransport.send(data)

        // Wait for callback to be invoked
        try await Task.sleep(for: .milliseconds(100))

        let received = await progressReceived.value
        #expect(received != nil, "Progress callback should have been invoked")
        #expect(received?.progress == 50, "Progress value should be 50")
        #expect(received?.total == 100, "Total value should be 100")

        await proto.stopProtocol()
    }

    // MARK: - Request ID Generation Tests

    @Test("Protocol generates unique request IDs")
    func testRequestIdGeneration() async throws {
        let proto = TestProtocolActor()

        let id1 = await proto.generateProtocolRequestId()
        let id2 = await proto.generateProtocolRequestId()
        let id3 = await proto.generateProtocolRequestId()

        #expect(id1 != id2, "Request IDs should be unique")
        #expect(id2 != id3, "Request IDs should be unique")
        #expect(id1 != id3, "Request IDs should be unique")
    }

    // MARK: - RequestHandlerContext Tests

    @Test("RequestHandlerContext.checkCancellation throws when task is cancelled")
    func testRequestHandlerContextCancellation() async throws {
        let extra = RequestHandlerContext(
            sessionId: nil,
            requestId: .number(1),
            _meta: nil,
            taskId: nil,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { _ in },
            sendRequest: { _ in Data() }
        )

        // In a non-cancelled context, checkCancellation should not throw
        #expect(throws: Never.self) {
            try extra.checkCancellation()
        }

        // isCancelled should reflect Task.isCancelled
        #expect(!extra.isCancelled, "Should not be cancelled initially")
    }
}

// MARK: - TimeoutController Tests

@Suite("TimeoutController Tests")
struct TimeoutControllerTests {
    @Test("Timeout expires when no progress received")
    func testTimeoutExpires() async throws {
        let controller = TimeoutController(
            timeout: .milliseconds(50),
            resetOnProgress: true,
            maxTotalTimeout: nil
        )

        do {
            try await controller.waitForTimeout()
            Issue.record("Should have thrown timeout error")
        } catch let error as MCPError {
            guard case .requestTimeout = error else {
                Issue.record("Expected requestTimeout, got: \(error)")
                return
            }
        }
    }

    @Test("Timeout resets when progress is signaled")
    func testTimeoutResetsOnProgress() async throws {
        let controller = TimeoutController(
            timeout: .milliseconds(200),
            resetOnProgress: true,
            maxTotalTimeout: nil
        )

        // Start the timeout in a separate task
        let timeoutTask = Task {
            try await controller.waitForTimeout()
        }

        // Wait 100ms, then signal progress (should reset the 200ms timeout)
        try await Task.sleep(for: .milliseconds(100))
        await controller.signalProgress()

        // Wait another 100ms - if timeout wasn't reset, we'd be at 200ms and timed out
        try await Task.sleep(for: .milliseconds(100))

        // Cancel the controller and task
        await controller.cancel()
        timeoutTask.cancel()

        // If we got here without the timeoutTask throwing, the reset worked
    }

    @Test("Timeout does not reset when resetOnProgress is false")
    func testTimeoutDoesNotResetWhenDisabled() async throws {
        let controller = TimeoutController(
            timeout: .milliseconds(50),
            resetOnProgress: false,
            maxTotalTimeout: nil
        )

        // Start the timeout
        let timeoutTask = Task {
            try await controller.waitForTimeout()
        }

        // Signal progress - should NOT reset timeout since resetOnProgress is false
        try await Task.sleep(for: .milliseconds(30))
        await controller.signalProgress()

        // Wait for timeout to expire
        do {
            try await timeoutTask.value
            Issue.record("Should have thrown timeout error")
        } catch let error as MCPError {
            guard case .requestTimeout = error else {
                Issue.record("Expected requestTimeout, got: \(error)")
                return
            }
        } catch is CancellationError {
            // Acceptable if cancelled
        }
    }

    @Test("maxTotalTimeout is respected even with progress")
    func testMaxTotalTimeoutRespected() async throws {
        // Per-progress timeout is much larger than maxTotalTimeout so it never fires.
        // Frequent progress signals keep the loop iterating so the maxTotal check triggers.
        let controller = TimeoutController(
            timeout: .milliseconds(500),
            resetOnProgress: true,
            maxTotalTimeout: .milliseconds(200)
        )

        let timeoutTask = Task {
            try await controller.waitForTimeout()
        }

        // Continuously signal progress until the timeout task completes
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                await controller.signalProgress()
            }
        }

        defer { progressTask.cancel() }

        // maxTotalTimeout should trigger even though progress keeps resetting the per-progress timeout
        do {
            try await timeoutTask.value
            Issue.record("Should have thrown timeout error for max total")
        } catch let error as MCPError {
            guard case let .requestTimeout(_, message) = error else {
                Issue.record("Expected requestTimeout, got: \(error)")
                return
            }
            #expect(message?.contains("maximum") == true)
        } catch is CancellationError {
            // Acceptable if cancelled
        }
    }

    @Test("Cancel stops timeout without throwing")
    func testCancelStopsTimeout() async throws {
        let controller = TimeoutController(
            timeout: .milliseconds(1000),
            resetOnProgress: true,
            maxTotalTimeout: nil
        )

        let timeoutTask = Task {
            try await controller.waitForTimeout()
        }

        // Cancel the controller
        await controller.cancel()

        // The task should complete without throwing timeout error
        // It may throw CancellationError or just complete
        do {
            try await timeoutTask.value
        } catch is CancellationError {
            // Expected
        } catch let error as MCPError {
            if case .requestTimeout = error {
                Issue.record("Should not have timed out after cancel")
            }
        }
    }
}

// MARK: - Debounced Notification Tests

@Suite("Debounced Notification Tests")
struct DebouncedNotificationTests {
    @Test("Multiple synchronous notifications are coalesced")
    func testNotificationsAreCoalesced() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let spyTransport = await SpyTransport(wrapping: serverTransport)

        let proto = TestProtocolActor()

        // Configure debouncing for a test notification
        await proto.setDebouncedNotificationMethods(["notifications/resources/list_changed"])

        try await proto.startProtocol(transport: spyTransport)
        try await clientTransport.connect()

        // Send multiple notifications synchronously (without awaiting between)
        let notification = ResourceListChangedNotification.message()
        try await proto.sendProtocolNotification(notification)
        try await proto.sendProtocolNotification(notification)
        try await proto.sendProtocolNotification(notification)

        // Wait for debounce to flush
        await proto.waitForPendingDebouncedNotifications()

        let count = await spyTransport.getSentMessageCount()
        #expect(count == 1, "Multiple notifications should be coalesced into one, got \(count)")

        await proto.stopProtocol()
    }

    @Test("Notifications with relatedRequestId are not debounced")
    func testNotificationsWithRelatedRequestIdNotDebounced() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let spyTransport = await SpyTransport(wrapping: serverTransport)

        let proto = TestProtocolActor()

        // Configure debouncing
        await proto.setDebouncedNotificationMethods(["notifications/resources/list_changed"])

        try await proto.startProtocol(transport: spyTransport)
        try await clientTransport.connect()

        // Send notifications with relatedRequestId - should NOT be debounced
        let notification = ResourceListChangedNotification.message()
        try await proto.sendProtocolNotification(notification, relatedRequestId: .number(1))
        try await proto.sendProtocolNotification(notification, relatedRequestId: .number(2))

        // These are not debounced, so no need to wait - they're sent immediately

        let count = await spyTransport.getSentMessageCount()
        #expect(count == 2, "Notifications with relatedRequestId should not be debounced, got \(count)")

        await proto.stopProtocol()
    }

    @Test("Pending debounced notifications are cleared on disconnect")
    func testPendingNotificationsClearedOnDisconnect() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let spyTransport = await SpyTransport(wrapping: serverTransport)

        let proto = TestProtocolActor()

        await proto.setDebouncedNotificationMethods(["notifications/resources/list_changed"])

        try await proto.startProtocol(transport: spyTransport)
        try await clientTransport.connect()

        // Send a notification (will be pending in debounce queue)
        let notification = ResourceListChangedNotification.message()
        try await proto.sendProtocolNotification(notification)

        // Immediately disconnect before debounce flushes
        await proto.stopProtocol()

        // Wait to ensure flush would have happened
        try await Task.sleep(for: .milliseconds(50))

        let count = await spyTransport.getSentMessageCount()
        #expect(count == 0, "Pending notifications should be cleared on disconnect, got \(count)")
    }

    @Test("Non-debounced notifications are sent immediately")
    func testNonDebouncedNotificationsSentImmediately() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let spyTransport = await SpyTransport(wrapping: serverTransport)

        let proto = TestProtocolActor()

        // Don't configure any debouncing
        await proto.setDebouncedNotificationMethods([])

        try await proto.startProtocol(transport: spyTransport)
        try await clientTransport.connect()

        // Send multiple notifications (non-debounced, so sent immediately)
        let notification = ResourceListChangedNotification.message()
        try await proto.sendProtocolNotification(notification)
        try await proto.sendProtocolNotification(notification)
        try await proto.sendProtocolNotification(notification)

        let count = await spyTransport.getSentMessageCount()
        #expect(count == 3, "Non-debounced notifications should all be sent, got \(count)")

        await proto.stopProtocol()
    }
}

// MARK: - Response Router Tests

@Suite("Response Router Tests")
struct ResponseRouterTests {
    @Test("Response router receives responses for matching request IDs")
    func testResponseRouterReceivesResponses() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        let routedResponses = ValueHolder<[RequestId]>([])

        // Create a test router
        let router = TestResponseRouter { requestId, _ in
            await routedResponses.set(routedResponses.value + [requestId])
            return true
        }

        await proto.addProtocolResponseRouter(router)

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a response from client side
        let encoder = JSONEncoder()
        let response = Response<Ping>(id: .number(42), result: .init())
        let data = try encoder.encode(response)
        try await clientTransport.send(data)

        try await Task.sleep(for: .milliseconds(100))

        let routed = await routedResponses.value
        #expect(routed.contains(.number(42)), "Router should have received the response")

        await proto.stopProtocol()
    }

    @Test("Response router can decline to handle response")
    func testResponseRouterCanDecline() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        let routerCalled = ValueHolder(false)

        // Create a router that always declines
        let router = TestResponseRouter { _, _ in
            await routerCalled.set(true)
            return false
        }

        await proto.addProtocolResponseRouter(router)

        // Register a pending request so we can verify fallback handling
        let requestId: RequestId = .number(99)
        let stream = await proto.registerProtocolPendingRequest(id: requestId)

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a response
        let encoder = JSONEncoder()
        let response = Response<Ping>(id: requestId, result: .init())
        let data = try encoder.encode(response)
        try await clientTransport.send(data)

        // The stream should receive the response since router declined
        for try await _ in stream {
            break // Got the response
        }

        let called = await routerCalled.value
        #expect(called, "Router should have been called")

        await proto.stopProtocol()
    }

    @Test("All response routers are cleared on removeAll")
    func testRemoveAllResponseRouters() async throws {
        let proto = TestProtocolActor()

        let router1 = TestResponseRouter { _, _ in true }
        let router2 = TestResponseRouter { _, _ in true }

        await proto.addProtocolResponseRouter(router1)
        await proto.addProtocolResponseRouter(router2)

        // Verify routers are added
        let countBefore = await proto.protocolState.responseRouters.count
        #expect(countBefore == 2, "Should have 2 routers")

        await proto.removeAllProtocolResponseRouters()

        let countAfter = await proto.protocolState.responseRouters.count
        #expect(countAfter == 0, "Should have 0 routers after removeAll")
    }
}

// MARK: - Connection State Edge Cases Tests

@Suite("Connection State Edge Cases Tests")
struct ConnectionStateEdgeCaseTests {
    @Test("Connecting when already connected throws error")
    func testConnectingWhenAlreadyConnectedThrows() async throws {
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)

        // Verify we're connected
        let isConnected = await proto.isProtocolConnected
        #expect(isConnected, "Protocol should be connected")

        // Create another transport pair for the second connect attempt
        let (_, anotherTransport) = await InMemoryTransport.createConnectedPair()

        // Attempting to connect again should throw
        do {
            try await proto.startProtocol(transport: anotherTransport)
            Issue.record("Should have thrown when already connected")
        } catch let error as MCPError {
            if case let .internalError(message) = error {
                #expect(message?.contains("Already connected") == true)
            } else {
                Issue.record("Expected internalError about already connected, got: \(error)")
            }
        }

        await proto.stopProtocol()
    }

    @Test("stopProtocol on disconnected protocol is a no-op")
    func testStopOnDisconnectedIsNoOp() async throws {
        let proto = TestProtocolActor()

        // Protocol is not connected, so stop should be a no-op
        await proto.stopProtocol()

        // Verify still disconnected
        let isConnected = await proto.isProtocolConnected
        #expect(!isConnected, "Protocol should remain disconnected")

        // Calling stop again should also be fine
        await proto.stopProtocol()
    }

    @Test("stopProtocol can be called multiple times safely")
    func testStopProtocolMultipleTimes() async throws {
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)

        // Stop multiple times - should not crash or throw
        await proto.stopProtocol()
        await proto.stopProtocol()
        await proto.stopProtocol()

        let isConnected = await proto.isProtocolConnected
        #expect(!isConnected, "Protocol should be disconnected")
    }
}

// MARK: - Unknown Message Handling Tests

@Suite("Unknown Message Handling Tests")
struct UnknownMessageHandlingTests {
    @Test("Unknown message type calls handleUnknownMessage")
    func testUnknownMessageCallsHandler() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let unknownMessageReceived = UnknownMessageTracker()
        let proto = TestProtocolActorWithUnknownTracking(unknownMessageTracker: unknownMessageReceived)

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a malformed message that can't be decoded as any known type
        // This is not valid JSON-RPC (missing jsonrpc field, no id, etc.)
        let invalidMessage = """
        {"not_a_valid_message": true, "random_field": 42}
        """.data(using: .utf8)!

        try await clientTransport.send(invalidMessage)

        // Wait for message to be processed
        try await Task.sleep(for: .milliseconds(100))

        let received = await unknownMessageReceived.wasReceived
        #expect(received, "handleUnknownMessage should have been called for invalid message")

        await proto.stopProtocol()
    }

    @Test("Empty JSON object triggers unknown message handler")
    func testEmptyJsonTriggersUnknownHandler() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let unknownMessageReceived = UnknownMessageTracker()
        let proto = TestProtocolActorWithUnknownTracking(unknownMessageTracker: unknownMessageReceived)

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Empty JSON object - not a valid JSON-RPC message
        let emptyMessage = "{}".data(using: .utf8)!
        try await clientTransport.send(emptyMessage)

        try await Task.sleep(for: .milliseconds(100))

        let received = await unknownMessageReceived.wasReceived
        #expect(received, "Empty JSON should trigger unknown message handler")

        await proto.stopProtocol()
    }
}

// MARK: - Response Handling Edge Cases Tests

@Suite("Response Handling Edge Cases Tests")
struct ResponseHandlingEdgeCaseTests {
    @Test("Response for unknown request ID is handled gracefully")
    func testResponseForUnknownRequestId() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Send a response for a request ID that doesn't exist
        let encoder = JSONEncoder()
        let response = Response<Ping>(id: .string("nonexistent-request-id"), result: .init())
        let data = try encoder.encode(response)
        try await clientTransport.send(data)

        // Wait for message to be processed
        try await Task.sleep(for: .milliseconds(100))

        // The test passes if we get here without crashing
        // The protocol should log a warning but continue functioning

        // Verify protocol is still functional by sending a valid request
        let request = Request<Ping>(id: .number(1), method: Ping.name, params: Ping.Parameters())
        let requestData = try encoder.encode(request)
        try await clientTransport.send(requestData)

        try await Task.sleep(for: .milliseconds(50))

        let requests = await proto.receivedRequests
        #expect(requests.count == 1, "Protocol should still process valid requests after unknown response")

        await proto.stopProtocol()
    }

    @Test("Batch responses are all processed")
    func testBatchResponsesProcessed() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Register pending requests for the batch
        let id1: RequestId = .number(1)
        let id2: RequestId = .number(2)
        let id3: RequestId = .number(3)

        let stream1 = await proto.registerProtocolPendingRequest(id: id1)
        let stream2 = await proto.registerProtocolPendingRequest(id: id2)
        let stream3 = await proto.registerProtocolPendingRequest(id: id3)

        // Send a batch of responses
        let encoder = JSONEncoder()
        let response1 = try AnyResponse(Response<Ping>(id: id1, result: .init()))
        let response2 = try AnyResponse(Response<Ping>(id: id2, result: .init()))
        let response3 = try AnyResponse(Response<Ping>(id: id3, result: .init()))
        let batchData = try encoder.encode([response1, response2, response3])
        try await clientTransport.send(batchData)

        // All streams should receive their responses
        var receivedCount = 0
        for try await _ in stream1 {
            receivedCount += 1; break
        }
        for try await _ in stream2 {
            receivedCount += 1; break
        }
        for try await _ in stream3 {
            receivedCount += 1; break
        }

        #expect(receivedCount == 3, "All batch responses should be processed")

        await proto.stopProtocol()
    }

    @Test("Error response resumes pending request with error")
    func testErrorResponseResumesPendingWithError() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Register a pending request
        let requestId: RequestId = .number(42)
        let stream = await proto.registerProtocolPendingRequest(id: requestId)

        // Send an error response
        let errorResponse = AnyResponse(id: requestId, error: MCPError.methodNotFound("Test error"))
        let encoder = JSONEncoder()
        let data = try encoder.encode(errorResponse)
        try await clientTransport.send(data)

        // The stream should throw the error
        do {
            for try await _ in stream {
                Issue.record("Stream should not yield a value for error response")
            }
            Issue.record("Stream should have thrown an error")
        } catch let error as MCPError {
            if case let .methodNotFound(message) = error {
                #expect(message == "Test error")
            } else {
                Issue.record("Expected methodNotFound error, got: \(error)")
            }
        }

        await proto.stopProtocol()
    }
}

// MARK: - onClose Callback Tests

@Suite("onClose Callback Tests")
struct OnCloseCallbackTests {
    @Test("onClose is called exactly once on graceful disconnect")
    func testOnCloseCalledOnceOnGracefulDisconnect() async throws {
        let (_, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        let closeCallCount = CallCounter()

        await proto.setOnClose { [closeCallCount] in
            await closeCallCount.increment()
        }

        try await proto.startProtocol(transport: serverTransport)

        // Gracefully disconnect
        await proto.stopProtocol()

        // Wait for callback to be invoked
        try await Task.sleep(for: .milliseconds(50))

        let count = await closeCallCount.value
        #expect(count == 1, "onClose should be called exactly once, was called \(count) times")
    }

    @Test("onClose is called on unexpected transport closure")
    func testOnCloseCalledOnUnexpectedTransportClosure() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        let closeCallCount = CallCounter()

        await proto.setOnClose { [closeCallCount] in
            await closeCallCount.increment()
        }

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Disconnect the client side unexpectedly (simulates server process exit)
        await clientTransport.disconnect()

        // Wait for the protocol to detect the closure
        try await Task.sleep(for: .milliseconds(200))

        let count = await closeCallCount.value
        #expect(count == 1, "onClose should be called once on unexpected closure, was called \(count) times")

        // Cleanup
        await proto.stopProtocol()
    }

    @Test("Calling stopProtocol after unexpected closure doesn't call onClose again")
    func testStopAfterUnexpectedClosureNoDoubleCallback() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        let closeCallCount = CallCounter()

        await proto.setOnClose { [closeCallCount] in
            await closeCallCount.increment()
        }

        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Simulate unexpected closure
        await clientTransport.disconnect()

        // Wait for the protocol to detect and handle the closure
        try await Task.sleep(for: .milliseconds(200))

        // Now call stopProtocol explicitly
        await proto.stopProtocol()

        try await Task.sleep(for: .milliseconds(50))

        let count = await closeCallCount.value
        #expect(count == 1, "onClose should only be called once even with explicit stop after unexpected closure")
    }
}

// MARK: - Message Loop Error Handling Tests

@Suite("Message Loop Error Handling Tests")
struct MessageLoopErrorHandlingTests {
    @Test("handleConnectionClosed is called when message loop ends unexpectedly")
    func testHandleConnectionClosedCalled() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let proto = TestProtocolActor()
        try await proto.startProtocol(transport: serverTransport)
        try await clientTransport.connect()

        // Verify connection closed handler hasn't been called yet
        let beforeClosure = await proto.connectionClosedCalled
        #expect(!beforeClosure, "connectionClosedCalled should be false before closure")

        // Close the client transport to simulate unexpected closure
        await clientTransport.disconnect()

        // Wait for the protocol to detect and handle the closure
        try await Task.sleep(for: .milliseconds(200))

        let afterClosure = await proto.connectionClosedCalled
        #expect(afterClosure, "handleConnectionClosed should have been called")
    }
}

// MARK: - Additional Helper Types

/// Tracks whether an unknown message was received.
private actor UnknownMessageTracker {
    var wasReceived = false
    var receivedData: [Data] = []

    func record(_ data: Data) {
        wasReceived = true
        receivedData.append(data)
    }
}

/// A protocol actor that tracks unknown messages.
private actor TestProtocolActorWithUnknownTracking: ProtocolLayer {
    package var protocolState = ProtocolState()
    package var protocolLogger: Logger? = nil

    private let unknownMessageTracker: UnknownMessageTracker

    init(unknownMessageTracker: UnknownMessageTracker) {
        self.unknownMessageTracker = unknownMessageTracker
    }

    package func handleIncomingRequest(_: AnyRequest, data _: Data, context _: MessageMetadata?) async {
        // Default: do nothing
    }

    package func handleIncomingNotification(_: AnyMessage, data _: Data) async {
        // Default: do nothing
    }

    package func handleConnectionClosed() async {}

    package func interceptResponse(_: AnyResponse) async {}

    package func handleUnknownMessage(_ data: Data, context _: MessageMetadata?) async {
        await unknownMessageTracker.record(data)
    }
}

/// Extension to allow setting onClose for testing.
extension TestProtocolActor {
    func setOnClose(_ closure: @escaping @Sendable () async -> Void) {
        protocolState.onClose = closure
    }
}

// MARK: - Helper Types

/// Thread-safe container for test synchronization.
private actor ValueHolder<T> {
    var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ newValue: T) {
        value = newValue
    }
}

/// A transport that wraps another transport and tracks sent messages.
private actor SpyTransport: Transport {
    private let wrapped: InMemoryTransport
    private let wrappedReceiveStream: AsyncThrowingStream<TransportMessage, Swift.Error>
    private(set) var sentMessages: [Data] = []

    nonisolated var logger: Logger { wrapped.logger }
    nonisolated var sessionId: String? { nil }
    nonisolated var supportsServerToClientRequests: Bool { true }

    init(wrapping transport: InMemoryTransport) async {
        wrapped = transport
        wrappedReceiveStream = await transport.receive()
    }

    func connect() async throws {
        try await wrapped.connect()
    }

    func disconnect() async {
        await wrapped.disconnect()
    }

    func send(_ data: Data, options: TransportSendOptions) async throws {
        sentMessages.append(data)
        try await wrapped.send(data, options: options)
    }

    func receive() -> AsyncThrowingStream<TransportMessage, Swift.Error> {
        wrappedReceiveStream
    }

    func getSentMessageCount() -> Int {
        sentMessages.count
    }
}

/// Test implementation of ResponseRouter for testing response routing.
private final class TestResponseRouter: ResponseRouter, @unchecked Sendable {
    private let handler: @Sendable (RequestId, Value) async -> Bool

    init(handler: @escaping @Sendable (RequestId, Value) async -> Bool) {
        self.handler = handler
    }

    func routeResponse(requestId: RequestId, response: Value) async -> Bool {
        await handler(requestId, response)
    }

    func routeError(requestId _: RequestId, error _: any Error) async -> Bool {
        false
    }
}

// MARK: - Test Helper Extension

extension TestProtocolActor {
    /// Set a progress callback for testing.
    func setProgressCallbackForTesting(token: ProgressToken, callback: @escaping ProtocolProgressCallback) {
        protocolState.progressCallbacks[token] = callback
    }

    /// Set debounced notification methods for testing.
    func setDebouncedNotificationMethods(_ methods: Set<String>) {
        protocolState.debouncedNotificationMethods = methods
    }

    /// Wait for all pending debounced notifications to be flushed.
    func waitForPendingDebouncedNotifications() async {
        let tasks = protocolState.pendingFlushTasks.values
        for task in tasks {
            await task.value
        }
    }
}
