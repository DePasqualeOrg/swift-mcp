// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

// MARK: - Client Capabilities Encoding Tests

@Suite("Client Capabilities Encoding Tests")
struct ClientCapabilitiesEncodingTests {
    @Test("Empty client capabilities encodes correctly")
    func testEmptyClientCapabilities() throws {
        let capabilities = Client.Capabilities()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Empty capabilities should encode to empty object
        #expect(json == "{}")

        // Verify roundtrip
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling == nil)
        #expect(decoded.elicitation == nil)
        #expect(decoded.roots == nil)
        #expect(decoded.experimental == nil)
        #expect(decoded.tasks == nil)
    }

    @Test("Client capabilities with roots encodes correctly")
    func testClientCapabilitiesWithRoots() throws {
        let capabilities = Client.Capabilities(
            roots: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"roots\""))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.roots?.listChanged == true)
    }

    @Test("Client capabilities with experimental encodes correctly")
    func testClientCapabilitiesWithExperimental() throws {
        let capabilities = Client.Capabilities(
            experimental: [
                "feature": [
                    "enabled": .bool(true),
                    "count": .int(42),
                ],
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"experimental\""))
        #expect(json.contains("\"feature\""))
        #expect(json.contains("\"enabled\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.experimental?["feature"]?["enabled"] == .bool(true))
        #expect(decoded.experimental?["feature"]?["count"] == .int(42))
    }

    @Test("Client capabilities all fields roundtrip")
    func testClientCapabilitiesAllFieldsRoundtrip() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(context: .init(), tools: .init()),
            elicitation: .init(form: .init(applyDefaults: true), url: .init()),
            experimental: ["test": ["value": .string("data")]],
            roots: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)

        #expect(decoded.sampling?.context != nil)
        #expect(decoded.sampling?.tools != nil)
        #expect(decoded.elicitation?.form?.applyDefaults == true)
        #expect(decoded.elicitation?.url != nil)
        #expect(decoded.experimental?["test"]?["value"] == .string("data"))
        #expect(decoded.roots?.listChanged == true)
    }
}

// MARK: - Server Capabilities Encoding Tests

@Suite("Server Capabilities Encoding Tests")
struct ServerCapabilitiesEncodingTests {
    @Test("Empty server capabilities encodes correctly")
    func testEmptyServerCapabilities() throws {
        let capabilities = Server.Capabilities()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Empty capabilities should encode to empty object
        #expect(json == "{}")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.logging == nil)
        #expect(decoded.prompts == nil)
        #expect(decoded.resources == nil)
        #expect(decoded.tools == nil)
        #expect(decoded.completions == nil)
        #expect(decoded.experimental == nil)
    }

    @Test("Server capabilities with logging encodes correctly")
    func testServerCapabilitiesWithLogging() throws {
        let capabilities = Server.Capabilities(
            logging: .init()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"logging\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.logging != nil)
    }

    @Test("Server capabilities with prompts listChanged true")
    func testServerCapabilitiesWithPromptsListChangedTrue() throws {
        let capabilities = Server.Capabilities(
            prompts: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"prompts\""))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.prompts?.listChanged == true)
    }

    @Test("Server capabilities with prompts listChanged false")
    func testServerCapabilitiesWithPromptsListChangedFalse() throws {
        let capabilities = Server.Capabilities(
            prompts: .init(listChanged: false)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.prompts?.listChanged == false)
    }

    @Test("Server capabilities with resources encodes correctly")
    func testServerCapabilitiesWithResources() throws {
        let capabilities = Server.Capabilities(
            resources: .init(subscribe: true, listChanged: true)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"resources\""))
        #expect(json.contains("\"subscribe\":true"))
        #expect(json.contains("\"listChanged\":true"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.resources?.subscribe == true)
        #expect(decoded.resources?.listChanged == true)
    }

    @Test("Server capabilities with tools listChanged")
    func testServerCapabilitiesWithToolsListChanged() throws {
        let capabilities = Server.Capabilities(
            tools: .init(listChanged: true)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.tools?.listChanged == true)
    }

    @Test("Server capabilities with completions encodes correctly")
    func testServerCapabilitiesWithCompletions() throws {
        let capabilities = Server.Capabilities(
            completions: .init()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"completions\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.completions != nil)
    }

    @Test("Server capabilities with experimental encodes correctly")
    func testServerCapabilitiesWithExperimental() throws {
        let capabilities = Server.Capabilities(
            experimental: [
                "customFeature": [
                    "supported": .bool(true),
                ],
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"experimental\""))
        #expect(json.contains("\"customFeature\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.experimental?["customFeature"]?["supported"] == .bool(true))
    }

    @Test("Server capabilities all fields roundtrip")
    func testServerCapabilitiesAllFieldsRoundtrip() throws {
        let capabilities = Server.Capabilities(
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: false),
            completions: .init(),
            experimental: ["test": ["enabled": .bool(true)]]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(capabilities)
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)

        #expect(decoded.logging != nil)
        #expect(decoded.prompts?.listChanged == true)
        #expect(decoded.resources?.subscribe == true)
        #expect(decoded.resources?.listChanged == true)
        #expect(decoded.tools?.listChanged == false)
        #expect(decoded.completions != nil)
        #expect(decoded.experimental?["test"]?["enabled"] == .bool(true))
    }
}

// MARK: - Initialize Request Encoding Tests

@Suite("Initialize Request Encoding Tests")
struct InitializeRequestEncodingTests {
    @Test("Initialize parameters encodes with capabilities")
    func testInitializeParametersEncoding() throws {
        let params = Initialize.Parameters(
            protocolVersion: Version.latest,
            capabilities: Client.Capabilities(
                sampling: .init(tools: .init()),
                roots: .init(listChanged: true)
            ),
            clientInfo: Client.Info(name: "TestClient", version: "1.0.0")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(params)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"protocolVersion\":\"\(Version.latest)\""))
        #expect(json.contains("\"clientInfo\""))
        #expect(json.contains("\"name\":\"TestClient\""))
        #expect(json.contains("\"capabilities\""))
        #expect(json.contains("\"sampling\""))
        #expect(json.contains("\"roots\""))
    }

    @Test("Initialize parameters decodes correctly")
    func testInitializeParametersDecoding() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "sampling": {"tools": {}},
                "roots": {"listChanged": true}
            },
            "clientInfo": {
                "name": "TestClient",
                "version": "1.0.0"
            }
        }
        """

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: json.data(using: .utf8)!)

        #expect(params.protocolVersion == Version.v2025_11_25)
        #expect(params.capabilities.sampling?.tools != nil)
        #expect(params.capabilities.roots?.listChanged == true)
        #expect(params.clientInfo.name == "TestClient")
        #expect(params.clientInfo.version == "1.0.0")
    }

    @Test("Initialize parameters defaults when fields missing")
    func testInitializeParametersDefaults() throws {
        let json = "{}"

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: json.data(using: .utf8)!)

        // Should use defaults
        #expect(params.protocolVersion == Version.latest)
        #expect(params.clientInfo.name == "unknown")
        #expect(params.clientInfo.version == "0.0.0")
    }

    @Test("Initialize result encodes with server capabilities")
    func testInitializeResultEncoding() throws {
        let result = Initialize.Result(
            protocolVersion: Version.latest,
            capabilities: Server.Capabilities(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: false)
            ),
            serverInfo: Server.Info(name: "TestServer", version: "2.0.0"),
            instructions: "Server instructions."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(result)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"protocolVersion\":\"\(Version.latest)\""))
        #expect(json.contains("\"serverInfo\""))
        #expect(json.contains("\"name\":\"TestServer\""))
        #expect(json.contains("\"instructions\":\"Server instructions.\""))
        #expect(json.contains("\"capabilities\""))
        #expect(json.contains("\"logging\""))
        #expect(json.contains("\"prompts\""))
        #expect(json.contains("\"resources\""))
        #expect(json.contains("\"tools\""))
    }

    @Test("Initialize result decodes correctly")
    func testInitializeResultDecoding() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "logging": {},
                "prompts": {"listChanged": true},
                "resources": {"subscribe": true, "listChanged": true},
                "tools": {"listChanged": false}
            },
            "serverInfo": {
                "name": "TestServer",
                "version": "2.0.0"
            },
            "instructions": "Server instructions."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: json.data(using: .utf8)!)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(result.capabilities.logging != nil)
        #expect(result.capabilities.prompts?.listChanged == true)
        #expect(result.capabilities.resources?.subscribe == true)
        #expect(result.capabilities.resources?.listChanged == true)
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.serverInfo.name == "TestServer")
        #expect(result.serverInfo.version == "2.0.0")
        #expect(result.instructions == "Server instructions.")
    }

    @Test("Initialize result roundtrip")
    func testInitializeResultRoundtrip() throws {
        let original = Initialize.Result(
            protocolVersion: Version.latest,
            capabilities: Server.Capabilities(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: false),
                completions: .init()
            ),
            serverInfo: Server.Info(
                name: "TestServer",
                version: "2.0.0",
                title: "Test Server Title",
                description: "A test server"
            ),
            instructions: "Follow these instructions."
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Initialize.Result.self, from: data)

        #expect(decoded.protocolVersion == original.protocolVersion)
        #expect(decoded.capabilities.logging != nil)
        #expect(decoded.capabilities.prompts?.listChanged == true)
        #expect(decoded.capabilities.resources?.subscribe == true)
        #expect(decoded.capabilities.tools?.listChanged == false)
        #expect(decoded.capabilities.completions != nil)
        #expect(decoded.serverInfo.name == original.serverInfo.name)
        #expect(decoded.serverInfo.version == original.serverInfo.version)
        #expect(decoded.serverInfo.title == original.serverInfo.title)
        #expect(decoded.serverInfo.description == original.serverInfo.description)
        #expect(decoded.instructions == original.instructions)
    }
}

// MARK: - Capability Negotiation Integration Tests

@Suite("Capability Negotiation Integration Tests")
struct CapabilityNegotiationTests {
    @Test("Client sends capabilities to server during initialization")
    func testClientSendsCapabilitiesToServer() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with specific capabilities
        let server = Server(
            name: "CapabilityTestServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                tools: .init()
            )
        )

        // Register a tools handler
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Set up client with specific capabilities
        let client = Client(
            name: "CapabilityTestClient",
            version: "1.0.0"
        )

        // Set capabilities via handlers before connecting
        await client.withSamplingHandler(supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(
                model: "test",
                stopReason: .endTurn,
                role: .assistant,
                content: []
            )
        }
        await client.withRootsHandler(listChanged: true) { _ in [] }

        // Connect and verify
        try await client.connect(transport: clientTransport)

        // Verify the server is running correctly
        let tools = try await client.listTools()
        // Just verify the connection works - server has no tools registered
        #expect(tools.tools.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server responds with its capabilities")
    func testServerRespondsWithCapabilities() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with all capabilities
        let server = Server(
            name: "FullCapabilityServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true),
                completions: .init()
            )
        )

        // Register handlers for capabilities that require them
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [])
        }
        await server.withRequestHandler(ListResources.self) { _, _ in
            ListResources.Result(resources: [])
        }
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Set up client
        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        try await client.connect(transport: clientTransport)

        // Verify we can use the capabilities
        let prompts = try await client.listPrompts()
        #expect(prompts.prompts.isEmpty)

        let resources = try await client.listResources()
        #expect(resources.resources.isEmpty)

        let tools = try await client.listTools()
        #expect(tools.tools.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client in strict mode fails on missing capability")
    func testStrictModeFailsOnMissingCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server without completions capability
        let server = Server(
            name: "LimitedServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client in strict mode
        let client = Client(
            name: "StrictClient",
            version: "1.0.0",
            configuration: .strict
        )

        try await client.connect(transport: clientTransport)

        // Attempting to use completions should fail
        do {
            _ = try await client.complete(
                ref: .prompt(PromptReference(name: "test")),
                argument: CompletionArgument(name: "arg", value: "val")
            )
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected to fail
            #expect(error is MCPError)
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("serverCapabilities returns nil before connect")
    func testServerCapabilitiesReturnsNilBeforeConnect() async throws {
        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        // Before connecting, server capabilities should be nil
        let capabilities = await client.serverCapabilities
        #expect(capabilities == nil)
    }

    @Test("serverCapabilities returns capabilities after connect")
    func testServerCapabilitiesReturnsCapabilitiesAfterConnect() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Set up server with specific capabilities
        let server = Server(
            name: "CapabilityServer",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: true)
            )
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(
            name: "TestClient",
            version: "1.0.0"
        )

        // Before connecting
        let beforeCapabilities = await client.serverCapabilities
        #expect(beforeCapabilities == nil)

        // Connect
        try await client.connect(transport: clientTransport)

        // After connecting, should have server capabilities
        let afterCapabilities = await client.serverCapabilities
        #expect(afterCapabilities != nil)
        #expect(afterCapabilities?.logging != nil)
        #expect(afterCapabilities?.prompts?.listChanged == true)
        #expect(afterCapabilities?.resources?.subscribe == true)
        #expect(afterCapabilities?.resources?.listChanged == false)
        #expect(afterCapabilities?.tools?.listChanged == true)

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - JSON Format Compatibility Tests

@Suite("Capability JSON Format Compatibility Tests")
struct CapabilityJSONCompatibilityTests {
    @Test("Client capabilities matches TypeScript format")
    func testClientCapabilitiesMatchesTypeScriptFormat() throws {
        // TypeScript format: { "sampling": {}, "roots": { "listChanged": true } }
        let typeScriptJSON = """
        {"sampling":{},"roots":{"listChanged":true}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.sampling != nil)
        #expect(capabilities.roots?.listChanged == true)

        // Encode and verify format
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Should match the TypeScript format
        #expect(json.contains("\"sampling\":{}"))
        #expect(json.contains("\"roots\":{\"listChanged\":true}"))
    }

    @Test("Server capabilities matches TypeScript format")
    func testServerCapabilitiesMatchesTypeScriptFormat() throws {
        // TypeScript format from protocol.test.ts
        let typeScriptJSON = """
        {"logging":{},"prompts":{"listChanged":true},"resources":{"subscribe":true},"tools":{"listChanged":false}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Server.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.logging != nil)
        #expect(capabilities.prompts?.listChanged == true)
        #expect(capabilities.resources?.subscribe == true)
        #expect(capabilities.tools?.listChanged == false)
    }

    @Test("Client elicitation capability with form matches TypeScript format")
    func testClientElicitationFormMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": {} } }
        let typeScriptJSON = """
        {"elicitation":{"form":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.elicitation?.form != nil)
        #expect(capabilities.elicitation?.url == nil)
    }

    @Test("Client elicitation capability with form applyDefaults matches TypeScript format")
    func testClientElicitationFormApplyDefaultsMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": { "applyDefaults": true } } }
        let typeScriptJSON = """
        {"elicitation":{"form":{"applyDefaults":true}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.elicitation?.form?.applyDefaults == true)
    }

    @Test("Client elicitation capability with url matches TypeScript format")
    func testClientElicitationURLMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "url": {} } }
        let typeScriptJSON = """
        {"elicitation":{"url":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.elicitation?.form == nil)
        #expect(capabilities.elicitation?.url != nil)
    }

    @Test("Client elicitation capability with both form and url matches TypeScript format")
    func testClientElicitationBothMatchesTypeScriptFormat() throws {
        // TypeScript format: { "elicitation": { "form": {}, "url": {} } }
        let typeScriptJSON = """
        {"elicitation":{"form":{},"url":{}}}
        """

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            Client.Capabilities.self, from: typeScriptJSON.data(using: .utf8)!
        )

        #expect(capabilities.elicitation?.form != nil)
        #expect(capabilities.elicitation?.url != nil)
    }

    @Test("Initialize request matches Python format")
    func testInitializeRequestMatchesPythonFormat() throws {
        // Python format from test_session.py
        let pythonJSON = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "sampling": {}
            },
            "clientInfo": {
                "name": "mcp-client",
                "version": "0.1.0"
            }
        }
        """

        let decoder = JSONDecoder()
        let params = try decoder.decode(Initialize.Parameters.self, from: pythonJSON.data(using: .utf8)!)

        #expect(params.protocolVersion == Version.v2025_11_25)
        #expect(params.capabilities.sampling != nil)
        #expect(params.clientInfo.name == "mcp-client")
        #expect(params.clientInfo.version == "0.1.0")
    }

    @Test("Initialize result matches Python format")
    func testInitializeResultMatchesPythonFormat() throws {
        // Python format from test_session.py
        let pythonJSON = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {
                "logging": {},
                "prompts": {"listChanged": true},
                "resources": {"subscribe": true, "listChanged": true},
                "tools": {"listChanged": false}
            },
            "serverInfo": {
                "name": "mock-server",
                "version": "0.1.0"
            },
            "instructions": "The server instructions."
        }
        """

        let decoder = JSONDecoder()
        let result = try decoder.decode(Initialize.Result.self, from: pythonJSON.data(using: .utf8)!)

        #expect(result.protocolVersion == Version.v2025_11_25)
        #expect(result.capabilities.logging != nil)
        #expect(result.capabilities.prompts?.listChanged == true)
        #expect(result.capabilities.resources?.subscribe == true)
        #expect(result.capabilities.resources?.listChanged == true)
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.serverInfo.name == "mock-server")
        #expect(result.serverInfo.version == "0.1.0")
        #expect(result.instructions == "The server instructions.")
    }
}

// MARK: - Sampling Capability Tests (additional coverage)

@Suite("Sampling Capability Encoding Tests")
struct SamplingCapabilityEncodingTests {
    @Test("Client sampling with no sub-capabilities encodes correctly")
    func testClientSamplingBasic() throws {
        let capabilities = Client.Capabilities(
            sampling: .init()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        // Should have empty sampling object
        #expect(json == "{\"sampling\":{}}")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.sampling != nil)
        #expect(decoded.sampling?.tools == nil)
        #expect(decoded.sampling?.context == nil)
    }
}

// MARK: - Tasks Capability Tests

@Suite("Tasks Capability Encoding Tests")
struct TasksCapabilityEncodingTests {
    @Test("Server tasks capability encodes correctly")
    func testServerTasksCapability() throws {
        let capabilities = Server.Capabilities(
            tasks: .init(
                list: .init(),
                cancel: .init(),
                requests: .init(tools: .init(call: .init()))
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"cancel\""))
        #expect(json.contains("\"requests\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Server.Capabilities.self, from: data)
        #expect(decoded.tasks != nil)
        #expect(decoded.tasks?.list != nil)
        #expect(decoded.tasks?.cancel != nil)
        #expect(decoded.tasks?.requests?.tools?.call != nil)
    }

    @Test("Client tasks capability encodes correctly")
    func testClientTasksCapability() throws {
        let capabilities = Client.Capabilities(
            tasks: .init(
                list: .init(),
                cancel: .init()
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(capabilities)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"cancel\""))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Client.Capabilities.self, from: data)
        #expect(decoded.tasks != nil)
        #expect(decoded.tasks?.list != nil)
        #expect(decoded.tasks?.cancel != nil)
    }
}

// MARK: - Server Capability Merge Tests

@Suite("Server Capability Merge Tests")
struct ServerCapabilityMergeTests {
    @Test("Auto-detects tools capability when not provided")
    func autoDetectsTools() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(),
            hasTools: true,
            hasResources: false,
            hasPrompts: false
        )
        #expect(result.tools != nil)
        #expect(result.tools?.listChanged == true)
    }

    @Test("Auto-detects resources capability when not provided")
    func autoDetectsResources() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(),
            hasTools: false,
            hasResources: true,
            hasPrompts: false
        )
        #expect(result.resources != nil)
        #expect(result.resources?.subscribe == false)
        #expect(result.resources?.listChanged == true)
    }

    @Test("Auto-detects prompts capability when not provided")
    func autoDetectsPrompts() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(),
            hasTools: false,
            hasResources: false,
            hasPrompts: true
        )
        #expect(result.prompts != nil)
        #expect(result.prompts?.listChanged == true)
    }

    @Test("Defaults nil listChanged to true for tools")
    func defaultsNilListChangedForTools() {
        // User provides tools capability object but omits listChanged
        let result = ServerCapabilityHelpers.merge(
            base: .init(tools: .init()),
            hasTools: true,
            hasResources: false,
            hasPrompts: false
        )
        #expect(result.tools?.listChanged == true)
    }

    @Test("Defaults nil listChanged to true for resources")
    func defaultsNilListChangedForResources() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(resources: .init()),
            hasTools: false,
            hasResources: true,
            hasPrompts: false
        )
        #expect(result.resources?.listChanged == true)
    }

    @Test("Defaults nil listChanged to true for prompts")
    func defaultsNilListChangedForPrompts() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(prompts: .init()),
            hasTools: false,
            hasResources: false,
            hasPrompts: true
        )
        #expect(result.prompts?.listChanged == true)
    }

    @Test("Preserves explicit listChanged false for tools")
    func preservesExplicitFalseForTools() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(tools: .init(listChanged: false)),
            hasTools: true,
            hasResources: false,
            hasPrompts: false
        )
        #expect(result.tools?.listChanged == false)
    }

    @Test("Preserves explicit listChanged false for resources")
    func preservesExplicitFalseForResources() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(resources: .init(listChanged: false)),
            hasTools: false,
            hasResources: true,
            hasPrompts: false
        )
        #expect(result.resources?.listChanged == false)
    }

    @Test("Preserves explicit listChanged false for prompts")
    func preservesExplicitFalseForPrompts() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(prompts: .init(listChanged: false)),
            hasTools: false,
            hasResources: false,
            hasPrompts: true
        )
        #expect(result.prompts?.listChanged == false)
    }

    @Test("Preserves explicit listChanged true")
    func preservesExplicitTrue() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(
                prompts: .init(listChanged: true),
                tools: .init(listChanged: true)
            ),
            hasTools: true,
            hasResources: false,
            hasPrompts: true
        )
        #expect(result.tools?.listChanged == true)
        #expect(result.prompts?.listChanged == true)
    }

    @Test("Does not create capability objects when feature is absent")
    func doesNotCreateWhenFeatureAbsent() {
        let result = ServerCapabilityHelpers.merge(
            base: .init(),
            hasTools: false,
            hasResources: false,
            hasPrompts: false
        )
        #expect(result.tools == nil)
        #expect(result.resources == nil)
        #expect(result.prompts == nil)
    }

    @Test("Defaults nil listChanged even when feature has no handlers")
    func defaultsListChangedWhenCapabilityProvidedWithoutFeature() {
        // User explicitly provides capability object even though no handlers are registered.
        // The nil-defaulting applies to any existing capability object.
        let result = ServerCapabilityHelpers.merge(
            base: .init(tools: .init()),
            hasTools: false,
            hasResources: false,
            hasPrompts: false
        )
        // Capability object was provided, so it's preserved, and listChanged gets defaulted
        #expect(result.tools != nil)
        #expect(result.tools?.listChanged == true)
    }
}

// MARK: - Notification Capability Validation Tests

@Suite("Notification Capability Validation Tests")
struct NotificationCapabilityValidationTests {
    /// Actor to track errors in a Sendable-compatible way.
    private actor ErrorTracker {
        var capturedError: (any Error)?
        func capture(_ error: any Error) { capturedError = error }
        func getError() -> (any Error)? { capturedError }
    }

    /// Test that sendResourceListChanged throws when resources capability is not declared.
    @Test("sendResourceListChanged throws without resources capability")
    func sendResourceListChangedThrowsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT resources capability
        let server = Server(
            name: "NoResourcesServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        let errorTracker = ErrorTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_notify", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { [errorTracker] _, context in
            do {
                try await context.sendResourceListChanged()
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch {
                await errorTracker.capture(error)
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_notify", arguments: [:])

        let thrownError = await errorTracker.getError()
        #expect(thrownError != nil, "Should have thrown an error")
        if let mcpError = thrownError as? MCPError {
            let description = String(describing: mcpError)
            #expect(description.contains("resources"), "Error should mention resources capability")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Test that sendResourceUpdated throws when resources capability is not declared.
    @Test("sendResourceUpdated throws without resources capability")
    func sendResourceUpdatedThrowsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT resources capability
        let server = Server(
            name: "NoResourcesServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        let errorTracker = ErrorTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_notify", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { [errorTracker] _, context in
            do {
                try await context.sendResourceUpdated(uri: "file:///test.txt")
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch {
                await errorTracker.capture(error)
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_notify", arguments: [:])

        let thrownError = await errorTracker.getError()
        #expect(thrownError != nil, "Should have thrown an error")
        if let mcpError = thrownError as? MCPError {
            let description = String(describing: mcpError)
            #expect(description.contains("resources"), "Error should mention resources capability")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Test that sendToolListChanged throws when tools capability is not declared.
    @Test("sendToolListChanged throws without tools capability")
    func sendToolListChangedThrowsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT tools capability (only prompts)
        let server = Server(
            name: "NoToolsServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init())
        )

        let errorTracker = ErrorTracker()

        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [
                Prompt(name: "test_prompt"),
            ])
        }

        await server.withRequestHandler(GetPrompt.self) { [errorTracker] _, context in
            do {
                try await context.sendToolListChanged()
                return GetPrompt.Result(description: nil, messages: [])
            } catch {
                await errorTracker.capture(error)
                return GetPrompt.Result(description: nil, messages: [])
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        _ = try await client.getPrompt(name: "test_prompt")

        let thrownError = await errorTracker.getError()
        #expect(thrownError != nil, "Should have thrown an error")
        if let mcpError = thrownError as? MCPError {
            let description = String(describing: mcpError)
            #expect(description.contains("tools"), "Error should mention tools capability")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Test that sendPromptListChanged throws when prompts capability is not declared.
    @Test("sendPromptListChanged throws without prompts capability")
    func sendPromptListChangedThrowsWithoutCapability() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server WITHOUT prompts capability
        let server = Server(
            name: "NoPromptsServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        let errorTracker = ErrorTracker()

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "test_notify", inputSchema: ["type": "object"]),
            ])
        }

        await server.withRequestHandler(CallTool.self) { [errorTracker] _, context in
            do {
                try await context.sendPromptListChanged()
                return CallTool.Result(content: [.text("Should not reach here")])
            } catch {
                await errorTracker.capture(error)
                return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
            }
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        _ = try await client.callTool(name: "test_notify", arguments: [:])

        let thrownError = await errorTracker.getError()
        #expect(thrownError != nil, "Should have thrown an error")
        if let mcpError = thrownError as? MCPError {
            let description = String(describing: mcpError)
            #expect(description.contains("prompts"), "Error should mention prompts capability")
        }

        await client.disconnect()
        await server.stop()
    }

    /// Test that Server.sendResourceListChanged throws when resources capability is not declared.
    @Test("Server.sendResourceListChanged throws without resources capability")
    func serverSendResourceListChangedThrowsWithoutCapability() async throws {
        // Server WITHOUT resources capability
        let server = Server(
            name: "NoResourcesServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        do {
            try await server.sendResourceListChanged()
            Issue.record("Should have thrown an error")
        } catch {
            #expect(error is MCPError, "Should throw MCPError")
            let description = String(describing: error)
            #expect(description.contains("resources"), "Error should mention resources capability")
        }
    }

    /// Test that Server.sendResourceUpdated throws when resources capability is not declared.
    @Test("Server.sendResourceUpdated throws without resources capability")
    func serverSendResourceUpdatedThrowsWithoutCapability() async throws {
        // Server WITHOUT resources capability
        let server = Server(
            name: "NoResourcesServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        do {
            try await server.sendResourceUpdated(uri: "file:///test.txt")
            Issue.record("Should have thrown an error")
        } catch {
            #expect(error is MCPError, "Should throw MCPError")
            let description = String(describing: error)
            #expect(description.contains("resources"), "Error should mention resources capability")
        }
    }

    /// Test that Server.sendToolListChanged throws when tools capability is not declared.
    @Test("Server.sendToolListChanged throws without tools capability")
    func serverSendToolListChangedThrowsWithoutCapability() async throws {
        // Server WITHOUT tools capability
        let server = Server(
            name: "NoToolsServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init())
        )

        do {
            try await server.sendToolListChanged()
            Issue.record("Should have thrown an error")
        } catch {
            #expect(error is MCPError, "Should throw MCPError")
            let description = String(describing: error)
            #expect(description.contains("tools"), "Error should mention tools capability")
        }
    }

    /// Test that Server.sendPromptListChanged throws when prompts capability is not declared.
    @Test("Server.sendPromptListChanged throws without prompts capability")
    func serverSendPromptListChangedThrowsWithoutCapability() async throws {
        // Server WITHOUT prompts capability
        let server = Server(
            name: "NoPromptsServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        do {
            try await server.sendPromptListChanged()
            Issue.record("Should have thrown an error")
        } catch {
            #expect(error is MCPError, "Should throw MCPError")
            let description = String(describing: error)
            #expect(description.contains("prompts"), "Error should mention prompts capability")
        }
    }
}

// MARK: - Capability Auto-Inference Tests (Phase 0 Test Audit)

@Suite("Capability Auto-Inference Tests")
struct CapabilityAutoInferenceTests {
    /// Test that registering a sampling handler auto-infers the sampling capability.
    @Test("Sampling capability inferred from handler registration", .timeLimit(.minutes(1)))
    func testSamplingCapabilityInferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client with sampling handler registered (no explicit capabilities)
        let client = Client(name: "InferenceTestClient", version: "1.0")

        await client.withSamplingHandler(supportsContext: true, supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(
                model: "test",
                stopReason: .endTurn,
                role: .assistant,
                content: []
            )
        }

        try await client.connect(transport: clientTransport)

        // Verify capabilities were auto-inferred
        let caps = await client.capabilities
        #expect(caps.sampling != nil, "Sampling capability should be auto-inferred")
        #expect(caps.sampling?.context != nil, "Sampling context capability should be set")
        #expect(caps.sampling?.tools != nil, "Sampling tools capability should be set")

        await client.disconnect()
        await server.stop()
    }

    /// Test that registering a roots handler auto-infers the roots capability.
    @Test("Roots capability inferred from handler registration", .timeLimit(.minutes(1)))
    func testRootsCapabilityInferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client with roots handler registered
        let client = Client(name: "RootsInferenceClient", version: "1.0")

        await client.withRootsHandler(listChanged: true) { _ in
            [Root(uri: "file:///test", name: "Test")]
        }

        try await client.connect(transport: clientTransport)

        // Verify capabilities were auto-inferred
        let caps = await client.capabilities
        #expect(caps.roots != nil, "Roots capability should be auto-inferred")
        #expect(caps.roots?.listChanged == true, "Roots listChanged should be set")

        await client.disconnect()
        await server.stop()
    }

    /// Test that registering an elicitation handler auto-infers the elicitation capability.
    @Test("Elicitation capability inferred from handler registration", .timeLimit(.minutes(1)))
    func testElicitationCapabilityInferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client with elicitation handler (both form and url modes)
        let client = Client(name: "ElicitationInferenceClient", version: "1.0")

        await client.withElicitationHandler(
            formMode: .enabled(applyDefaults: true),
            urlMode: .enabled
        ) { _, _ in
            Elicit.Result(action: .decline)
        }

        try await client.connect(transport: clientTransport)

        // Verify capabilities were auto-inferred
        let caps = await client.capabilities
        #expect(caps.elicitation != nil, "Elicitation capability should be auto-inferred")
        #expect(caps.elicitation?.form != nil, "Elicitation form mode should be set")
        #expect(caps.elicitation?.form?.applyDefaults == true, "Elicitation applyDefaults should be set")
        #expect(caps.elicitation?.url != nil, "Elicitation url mode should be set")

        await client.disconnect()
        await server.stop()
    }

    /// Test that explicit capabilities override auto-inferred capabilities.
    @Test("Explicit capabilities override auto-inferred", .timeLimit(.minutes(1)))
    func testExplicitCapabilitiesOverrideInferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client with explicit capabilities that differ from what handlers would infer
        let client = Client(
            name: "ExplicitCapClient",
            version: "1.0",
            // Explicit: sampling with context only (no tools)
            capabilities: .init(
                sampling: .init(context: .init(), tools: nil)
            )
        )

        // Handler registration suggests tools support, but explicit says no
        await client.withSamplingHandler(supportsContext: true, supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(
                model: "test",
                stopReason: .endTurn,
                role: .assistant,
                content: []
            )
        }

        try await client.connect(transport: clientTransport)

        // Explicit capabilities should win
        let caps = await client.capabilities
        #expect(caps.sampling != nil, "Sampling capability should exist")
        #expect(caps.sampling?.context != nil, "Sampling context should be set (explicit)")
        #expect(caps.sampling?.tools == nil, "Sampling tools should be nil (explicit override)")

        await client.disconnect()
        await server.stop()
    }

    /// Test that multiple handler registrations all contribute to capabilities.
    @Test("Multiple handlers contribute to capabilities", .timeLimit(.minutes(1)))
    func testMultipleHandlersContributeToCapabilities() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }

        try await server.start(transport: serverTransport)

        // Client with multiple handlers
        let client = Client(name: "MultiHandlerClient", version: "1.0")

        await client.withSamplingHandler(supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(
                model: "test",
                stopReason: .endTurn,
                role: .assistant,
                content: []
            )
        }

        await client.withRootsHandler(listChanged: true) { _ in
            [Root(uri: "file:///test", name: "Test")]
        }

        await client.withElicitationHandler(formMode: .enabled()) { _, _ in
            Elicit.Result(action: .decline)
        }

        try await client.connect(transport: clientTransport)

        // All capabilities should be present
        let caps = await client.capabilities
        #expect(caps.sampling != nil, "Sampling capability should be inferred")
        #expect(caps.sampling?.tools != nil, "Sampling tools should be set")
        #expect(caps.roots != nil, "Roots capability should be inferred")
        #expect(caps.roots?.listChanged == true, "Roots listChanged should be true")
        #expect(caps.elicitation != nil, "Elicitation capability should be inferred")
        #expect(caps.elicitation?.form != nil, "Elicitation form mode should be set")

        await client.disconnect()
        await server.stop()
    }

    /// Test that registering handlers in different orders produces the same capabilities.
    @Test("Registration order does not affect capabilities", .timeLimit(.minutes(1)))
    func testRegistrationOrderIndependent() async throws {
        // Test two clients with handlers registered in different orders
        let (clientTransport1, serverTransport1) = await InMemoryTransport.createConnectedPair()
        let (clientTransport2, serverTransport2) = await InMemoryTransport.createConnectedPair()

        // Set up two servers
        let server1 = Server(name: "Server1", version: "1.0", capabilities: .init(tools: .init()))
        let server2 = Server(name: "Server2", version: "1.0", capabilities: .init(tools: .init()))

        await server1.withRequestHandler(ListTools.self) { _, _ in ListTools.Result(tools: []) }
        await server2.withRequestHandler(ListTools.self) { _, _ in ListTools.Result(tools: []) }

        try await server1.start(transport: serverTransport1)
        try await server2.start(transport: serverTransport2)

        // Client 1: Register in order A
        let client1 = Client(name: "Client1", version: "1.0")
        await client1.withSamplingHandler(supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(model: "test", stopReason: .endTurn, role: .assistant, content: [])
        }
        await client1.withRootsHandler(listChanged: true) { _ in [] }

        // Client 2: Register in order B (reversed)
        let client2 = Client(name: "Client2", version: "1.0")
        await client2.withRootsHandler(listChanged: true) { _ in [] }
        await client2.withSamplingHandler(supportsTools: true) { _, _ in
            ClientSamplingRequest.Result(model: "test", stopReason: .endTurn, role: .assistant, content: [])
        }

        try await client1.connect(transport: clientTransport1)
        try await client2.connect(transport: clientTransport2)

        // Both should have identical capabilities
        let caps1 = await client1.capabilities
        let caps2 = await client2.capabilities

        #expect(caps1.sampling?.tools != nil, "Client1 sampling.tools should be set")
        #expect(caps2.sampling?.tools != nil, "Client2 sampling.tools should be set")
        #expect(caps1.roots?.listChanged == true, "Client1 roots.listChanged should be true")
        #expect(caps2.roots?.listChanged == true, "Client2 roots.listChanged should be true")

        // Capabilities should be equal
        #expect(caps1.sampling != nil && caps2.sampling != nil)
        #expect(caps1.roots != nil && caps2.roots != nil)

        await client1.disconnect()
        await client2.disconnect()
        await server1.stop()
        await server2.stop()
    }
}
