// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation
import Logging
@testable import MCP
import Testing

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

struct RoundtripTests {
    @Test(
        .timeLimit(.minutes(1)),
    )
    func roundtrip() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(
            label: "mcp.test.initialize",
            factory: { StreamLogHandler.standardError(label: $0) },
        )
        logger.logLevel = .debug

        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: logger,
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: logger,
        )

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(),
                resources: .init(),
                tools: .init(),
            ),
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(
                    name: "add",
                    description: "Adds two numbers together",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "a": ["type": "integer", "description": "The first number"],
                            "b": ["type": "integer", "description": "The second number"],
                        ],
                        "required": ["a", "b"],
                    ],
                ),
            ])
        }
        await server.withRequestHandler(CallTool.self) { request, _ in
            guard request.name == "add" else {
                return CallTool.Result(content: [.text("Invalid tool name")], isError: true)
            }

            guard let a = request.arguments?["a"]?.intValue,
                  let b = request.arguments?["b"]?.intValue
            else {
                return CallTool.Result(
                    content: [.text("Did not receive valid arguments")], isError: true,
                )
            }

            return CallTool.Result(content: [.text("\(a + b)")])
        }

        // Add resource handlers to server
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [
                Resource(
                    name: "Example Text",
                    uri: "test://example.txt",
                    description: "A test resource",
                    mimeType: "text/plain",
                ),
                Resource(
                    name: "Test Data",
                    uri: "test://data.json",
                    description: "JSON test data",
                    mimeType: "application/json",
                ),
            ])
        }

        await server.withRequestHandler(ReadResource.self) { request, _ in
            guard request.uri == "test://example.txt" else {
                throw MCPError.resourceNotFound(uri: request.uri)
            }
            return ReadResource.Result(contents: [.text("Hello, World!", uri: request.uri)])
        }

        let client = Client(name: "TestClient", version: "1.0")

        try await server.start(transport: serverTransport)

        // Test client connection
        let initResult = try await client.connect(transport: clientTransport)
        #expect(initResult.serverInfo.name == "TestServer")
        #expect(initResult.serverInfo.version == "1.0.0")
        #expect(initResult.capabilities.prompts != nil)
        #expect(initResult.capabilities.tools != nil)
        #expect(initResult.protocolVersion == Version.latest)

        // Test ping
        try await client.ping()

        // Test listing and calling tools
        let listToolsResult = try await client.listTools()
        #expect(listToolsResult.tools.count == 1)
        #expect(listToolsResult.tools[0].name == "add")

        let callToolResult = try await client.callTool(name: "add", arguments: ["a": 1, "b": 2])
        #expect(callToolResult.isError == nil)
        #expect(callToolResult.content == [.text("3")])

        // Test listing resources
        let listResourcesResult = try await client.listResources()
        #expect(listResourcesResult.resources.count == 2)
        #expect(listResourcesResult.resources[0].uri == "test://example.txt")
        #expect(listResourcesResult.resources[0].name == "Example Text")
        #expect(listResourcesResult.resources[1].uri == "test://data.json")
        #expect(listResourcesResult.resources[1].name == "Test Data")

        // Test reading a resource
        let readResourceResult = try await client.readResource(uri: "test://example.txt")
        #expect(readResourceResult.contents.count == 1)
        #expect(readResourceResult.contents[0] == .text("Hello, World!", uri: "test://example.txt"))

        await server.stop()
        await client.disconnect()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }
}
