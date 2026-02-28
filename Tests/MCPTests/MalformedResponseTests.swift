// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

/// Tests that the client fails pending requests when receiving malformed/unparseable messages,
/// rather than hanging indefinitely.
@Suite("Malformed Response Tests")
struct MalformedResponseTests {
    /// Set up a connected client-server pair and return the client plus the raw
    /// server-side transport for injecting malformed data.
    private func makeConnectedClient() async throws -> (Client, InMemoryTransport) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(name: "TestServer", version: "1.0")
        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        return (client, serverTransport)
    }

    @Test(
        "Invalid JSON fails pending request with parse error",
        .timeLimit(.minutes(1))
    )
    func invalidJsonFailsPendingRequest() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        // Register a pending request on the client
        let requestId: RequestId = .string("test-req-1")
        let stream = await client.registerProtocolPendingRequest(id: requestId)

        // Send invalid JSON from the server side. No ID can be extracted
        // because the entire string is not parseable JSON, so the client
        // fails all pending requests.
        let garbage = "this is not json at all"
        try await serverTransport.send(garbage.data(using: .utf8)!)

        // The pending request should fail with a parse error
        do {
            for try await _ in stream {
                Issue.record("Stream should not yield a value for invalid JSON")
            }
            Issue.record("Stream should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        await client.disconnect()
    }

    @Test(
        "Valid JSON but not JSON-RPC fails pending request",
        .timeLimit(.minutes(1))
    )
    func validJsonNotJsonRpcFailsPendingRequest() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        let requestId: RequestId = .string("test-req-2")
        let stream = await client.registerProtocolPendingRequest(id: requestId)

        // Send valid JSON that is not a JSON-RPC message but contains an extractable id
        let notJsonRpc = """
        {"id":"test-req-2","foo":"bar"}
        """
        try await serverTransport.send(notJsonRpc.data(using: .utf8)!)

        do {
            for try await _ in stream {
                Issue.record("Stream should not yield a value for non-JSON-RPC message")
            }
            Issue.record("Stream should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        await client.disconnect()
    }

    @Test(
        "Completely unparseable data fails all pending requests",
        .timeLimit(.minutes(1))
    )
    func unparseableDataFailsAllPendingRequests() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        // Register two pending requests
        let stream1 = await client.registerProtocolPendingRequest(id: .string("req-a"))
        let stream2 = await client.registerProtocolPendingRequest(id: .string("req-b"))

        // Send binary garbage with no extractable request ID
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        try await serverTransport.send(garbage)

        // Both pending requests should fail
        do {
            for try await _ in stream1 {
                Issue.record("Stream 1 should not yield a value")
            }
            Issue.record("Stream 1 should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        do {
            for try await _ in stream2 {
                Issue.record("Stream 2 should not yield a value")
            }
            Issue.record("Stream 2 should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        await client.disconnect()
    }

    @Test(
        "Malformed response with numeric ID fails pending request",
        .timeLimit(.minutes(1))
    )
    func numericIdFailsPendingRequest() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        let requestId: RequestId = .number(42)
        let stream = await client.registerProtocolPendingRequest(id: requestId)

        // Send malformed JSON-RPC with a numeric id
        let malformed = """
        {"id":42,"not_a_response":true}
        """
        try await serverTransport.send(malformed.data(using: .utf8)!)

        do {
            for try await _ in stream {
                Issue.record("Stream should not yield a value for malformed response")
            }
            Issue.record("Stream should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        await client.disconnect()
    }

    @Test(
        "Malformed response with non-matching ID fails all pending requests",
        .timeLimit(.minutes(1))
    )
    func nonMatchingIdFailsAllPendingRequests() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        let stream1 = await client.registerProtocolPendingRequest(id: .string("req-a"))
        let stream2 = await client.registerProtocolPendingRequest(id: .string("req-b"))

        // Send valid JSON with an ID that doesn't match either pending request
        let malformed = """
        {"id":"unknown-req","foo":"bar"}
        """
        try await serverTransport.send(malformed.data(using: .utf8)!)

        // Both should fail since the non-matching ID triggers fail-all
        do {
            for try await _ in stream1 {
                Issue.record("Stream 1 should not yield a value")
            }
            Issue.record("Stream 1 should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        do {
            for try await _ in stream2 {
                Issue.record("Stream 2 should not yield a value")
            }
            Issue.record("Stream 2 should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        await client.disconnect()
    }

    @Test(
        "Malformed response with extractable ID only fails that specific request",
        .timeLimit(.minutes(1))
    )
    func malformedResponseFailsOnlyMatchingRequest() async throws {
        let (client, serverTransport) = try await makeConnectedClient()

        // Register two pending requests
        let requestId1: RequestId = .string("req-1")
        let requestId2: RequestId = .string("req-2")
        let stream1 = await client.registerProtocolPendingRequest(id: requestId1)
        let stream2 = await client.registerProtocolPendingRequest(id: requestId2)

        // Send malformed data that contains req-1's ID but isn't valid JSON-RPC
        let malformed = """
        {"id":"req-1","not_a_response":true}
        """
        try await serverTransport.send(malformed.data(using: .utf8)!)

        // req-1 should fail
        do {
            for try await _ in stream1 {
                Issue.record("Stream 1 should not yield a value")
            }
            Issue.record("Stream 1 should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.parseError)
        }

        // req-2 should still be pending
        let hasPending = await client.hasProtocolPendingRequest(id: requestId2)
        #expect(hasPending, "req-2 should still be pending")

        // Clean up: cancel req-2 by disconnecting
        await client.disconnect()

        // Drain stream2 to avoid leaks
        do {
            for try await _ in stream2 {}
        } catch {
            // Expected - disconnect fails remaining requests
        }
    }
}
