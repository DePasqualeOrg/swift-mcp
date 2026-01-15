import Foundation
import Testing

@testable import MCP

@Suite("Stateless Mode Tests")
struct StatelessModeTests {

    // MARK: - Transport Property Tests

    @Test("MockTransport defaults to supporting server-to-client requests")
    func mockTransportDefaultsToSupportingRequests() async throws {
        let transport = MockTransport()
        let supports = await transport.supportsServerToClientRequests
        #expect(supports == true)
    }

    @Test("MockTransport can be configured to not support server-to-client requests")
    func mockTransportCanBeConfiguredToNotSupportRequests() async throws {
        let transport = MockTransport()
        await transport.setSupportsServerToClientRequests(false)
        let supports = await transport.supportsServerToClientRequests
        #expect(supports == false)
    }

    // MARK: - Server-to-Client Request Rejection

    @Test("listRoots fails immediately when transport does not support server-to-client requests",
          .timeLimit(.minutes(1)))
    func listRootsFailsInStatelessMode() async throws {
        let transport = MockTransport()
        await transport.setSupportsServerToClientRequests(false)

        let server = Server(name: "TestServer", version: "1.0")

        // Start server and initialize
        try await server.start(transport: transport)

        // Queue initialize request with roots capability
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(roots: .init(listChanged: true)),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        // Wait for server to process and respond
        _ = await transport.waitForSentMessageCount(1, timeout: .seconds(5))

        // Queue initialized notification
        try await transport.queue(
            notification: InitializedNotification.message(.init())
        )

        // Brief pause to ensure notification is processed
        try await Task.sleep(for: .milliseconds(100))

        // listRoots should fail immediately with stateless error
        do {
            _ = try await server.listRoots()
            Issue.record("Expected listRoots to throw in stateless mode")
        } catch let error as MCPError {
            // Verify it's the stateless mode error, not a capability error
            let errorDescription = String(describing: error)
            #expect(
                errorDescription.contains("stateless") || errorDescription.contains("server-to-client"),
                "Expected stateless mode error, got: \(errorDescription)"
            )
        }

        await server.stop()
    }

    @Test("createMessage fails immediately when transport does not support server-to-client requests",
          .timeLimit(.minutes(1)))
    func createMessageFailsInStatelessMode() async throws {
        let transport = MockTransport()
        await transport.setSupportsServerToClientRequests(false)

        let server = Server(name: "TestServer", version: "1.0")
        try await server.start(transport: transport)

        // Queue initialize request with sampling capability
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(sampling: .init()),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        _ = await transport.waitForSentMessageCount(1, timeout: .seconds(5))

        try await transport.queue(
            notification: InitializedNotification.message(.init())
        )

        try await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await server.createMessage(
                CreateSamplingMessage.Parameters(
                    messages: [Sampling.Message(role: .user, content: .text("Hello"))],
                    maxTokens: 100
                )
            )
            Issue.record("Expected createMessage to throw in stateless mode")
        } catch let error as MCPError {
            let errorDescription = String(describing: error)
            #expect(
                errorDescription.contains("stateless") || errorDescription.contains("server-to-client"),
                "Expected stateless mode error, got: \(errorDescription)"
            )
        }

        await server.stop()
    }

    @Test("elicit fails immediately when transport does not support server-to-client requests",
          .timeLimit(.minutes(1)))
    func elicitFailsInStatelessMode() async throws {
        let transport = MockTransport()
        await transport.setSupportsServerToClientRequests(false)

        let server = Server(name: "TestServer", version: "1.0")
        try await server.start(transport: transport)

        // Queue initialize request with elicitation capability
        try await transport.queue(
            request: Initialize.request(
                .init(
                    protocolVersion: Version.latest,
                    capabilities: .init(elicitation: .init(form: .init())),
                    clientInfo: .init(name: "TestClient", version: "1.0")
                )
            ))

        _ = await transport.waitForSentMessageCount(1, timeout: .seconds(5))

        try await transport.queue(
            notification: InitializedNotification.message(.init())
        )

        try await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await server.elicit(
                .form(ElicitRequestFormParams(
                    message: "Please provide input",
                    requestedSchema: ElicitationSchema(properties: [:])
                ))
            )
            Issue.record("Expected elicit to throw in stateless mode")
        } catch let error as MCPError {
            let errorDescription = String(describing: error)
            #expect(
                errorDescription.contains("stateless") || errorDescription.contains("server-to-client"),
                "Expected stateless mode error, got: \(errorDescription)"
            )
        }

        await server.stop()
    }
}
