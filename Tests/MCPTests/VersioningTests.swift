// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Testing

@testable import MCP

@Suite("Version Tests")
struct VersioningTests {
    @Test("Supported versions is non-empty and ordered latest-first")
    func supportedVersionsOrdering() {
        #expect(!Version.supported.isEmpty)
        // Verify descending chronological order (version strings are YYYY-MM-DD, so
        // lexicographic ordering matches chronological ordering)
        for i in 0 ..< (Version.supported.count - 1) {
            #expect(
                Version.supported[i] > Version.supported[i + 1],
                "Expected \(Version.supported[i]) > \(Version.supported[i + 1])"
            )
        }
    }

    @Test("No duplicate versions in supported list")
    func noDuplicateVersions() {
        #expect(Set(Version.supported).count == Version.supported.count)
    }

    @Test("Latest version equals first supported version")
    func latestIsFirstSupported() {
        #expect(Version.latest == Version.supported[0])
    }

    @Test("Default negotiated version is in supported list")
    func defaultNegotiatedIsSupported() {
        #expect(Version.supported.contains(Version.defaultNegotiated))
    }
}

@Suite("Configurable Protocol Versions Tests")
struct ConfigurableProtocolVersionsTests {
    @Test("Client configuration defaults to Version.supported")
    func clientConfigDefaults() {
        let config = Client.Configuration()
        #expect(config.supportedProtocolVersions == Version.supported)
    }

    @Test("Server configuration defaults to Version.supported")
    func serverConfigDefaults() {
        let config = Server.Configuration()
        #expect(config.supportedProtocolVersions == Version.supported)
    }

    @Test("Client configuration accepts custom versions")
    func clientConfigCustomVersions() {
        let custom = ["2099-01-01", Version.latest]
        let config = Client.Configuration(supportedProtocolVersions: custom)
        #expect(config.supportedProtocolVersions == custom)
    }

    @Test("Server configuration accepts custom versions")
    func serverConfigCustomVersions() {
        let custom = ["2099-01-01", Version.latest]
        let config = Server.Configuration(supportedProtocolVersions: custom)
        #expect(config.supportedProtocolVersions == custom)
    }

    @Test("Negotiation uses configured versions, not global defaults", .timeLimit(.minutes(1)))
    func negotiationUsesConfiguredVersions() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Both sides configured with a restricted set – only older versions
        let sharedVersions = [Version.v2025_03_26, Version.v2024_11_05]

        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(supportedProtocolVersions: sharedVersions)
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }
        try await server.start(transport: serverTransport)

        let client = Client(
            name: "TestClient",
            version: "1.0",
            configuration: .init(supportedProtocolVersions: sharedVersions)
        )
        let result = try await client.connect(transport: clientTransport)

        // Client sends its first (preferred) version, server supports it
        #expect(result.protocolVersion == Version.v2025_03_26)

        await client.disconnect()
        await server.stop()
    }

    @Test("Server falls back to its preferred version for unsupported client version", .timeLimit(.minutes(1)))
    func serverFallsBackToPreferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server only supports a custom version the client doesn't send
        let customVersion = "2099-01-01"
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(supportedProtocolVersions: [customVersion])
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }
        try await server.start(transport: serverTransport)

        // Client supports the custom version too, so it accepts the server's fallback
        let client = Client(
            name: "TestClient",
            version: "1.0",
            configuration: .init(supportedProtocolVersions: [customVersion])
        )
        let result = try await client.connect(transport: clientTransport)

        #expect(result.protocolVersion == customVersion)

        await client.disconnect()
        await server.stop()
    }

    @Test("Client rejects version not in its configured list", .timeLimit(.minutes(1)))
    func clientRejectsUnsupportedVersion() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server only supports a version the client doesn't know about
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(supportedProtocolVersions: ["2099-01-01"])
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }
        try await server.start(transport: serverTransport)

        // Client only supports the standard versions – server's fallback isn't in its list
        let client = Client(name: "TestClient", version: "1.0")

        await #expect(throws: MCPError.self) {
            _ = try await client.connect(transport: clientTransport)
        }

        await server.stop()
    }

    @Test("Client sends its first configured version as preferred", .timeLimit(.minutes(1)))
    func clientSendsFirstVersionAsPreferred() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Server supports everything
        let server = Server(
            name: "TestServer",
            version: "1.0",
            capabilities: .init(tools: .init())
        )
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [])
        }
        try await server.start(transport: serverTransport)

        // Client prefers an older version
        let client = Client(
            name: "TestClient",
            version: "1.0",
            configuration: .init(supportedProtocolVersions: [Version.v2024_11_05, Version.v2025_11_25])
        )
        let result = try await client.connect(transport: clientTransport)

        // Server supports the client's preferred version, so it's accepted
        #expect(result.protocolVersion == Version.v2024_11_05)

        await client.disconnect()
        await server.stop()
    }
}
