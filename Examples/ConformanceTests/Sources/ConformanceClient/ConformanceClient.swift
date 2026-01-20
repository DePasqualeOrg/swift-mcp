/// MCP Conformance Test Client
///
/// A client executable designed to be invoked by the MCP conformance test runner.
/// It reads the scenario name from the `MCP_CONFORMANCE_SCENARIO` environment variable
/// and the server URL from command-line arguments.
///
/// ## Usage
///
/// ```bash
/// # Run via conformance test suite
/// npx @modelcontextprotocol/conformance client \
///   --command "swift run --package-path /path/to/ConformanceTests ConformanceClient" \
///   --scenario initialize
///
/// # Direct invocation (for testing)
/// MCP_CONFORMANCE_SCENARIO=initialize swift run ConformanceClient http://localhost:3000
/// ```

import Foundation
import Logging
import MCP

@main
struct ConformanceClient {
    static let logger = Logger(label: "mcp.conformance.client")

    static func main() async {
        do {
            try await run()
        } catch {
            logger.error("Error: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        // Parse command line arguments
        guard CommandLine.arguments.count >= 2,
              let serverURL = URL(string: CommandLine.arguments[1])
        else {
            logger.error("Usage: ConformanceClient <server-url>")
            logger.info("The MCP_CONFORMANCE_SCENARIO env var is set by the conformance runner.")
            exit(1)
        }

        let scenario = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SCENARIO"] ?? "initialize"

        logger.info("Running scenario: \(scenario)")
        logger.info("Server URL: \(serverURL)")

        switch scenario {
            case "initialize":
                try await runInitializeScenario(serverURL: serverURL)
            case "tools_call":
                try await runToolsCallScenario(serverURL: serverURL)
            case "elicitation-sep1034-client-defaults":
                try await runElicitationScenario(serverURL: serverURL)
            case "sse-retry":
                try await runSSERetryScenario(serverURL: serverURL)
            default:
                logger.error("Unknown scenario: \(scenario)")
                logger.info("Supported scenarios: initialize, tools_call, elicitation-sep1034-client-defaults, sse-retry")
                logger.info("Not implemented: auth/* (requires OAuth support)")
                exit(1)
        }

        logger.info("Scenario completed successfully")
    }

    // MARK: - Scenarios

    /// Initialize scenario: connect, initialize, list tools, disconnect
    static func runInitializeScenario(serverURL: URL) async throws {
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: false)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        logger.info("Connecting to server...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }

    /// Tools call scenario: connect, list tools, call add_numbers tool, disconnect
    static func runToolsCallScenario(serverURL: URL) async throws {
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: false)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        logger.info("Connecting to server...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        // Find and call the add_numbers tool (provided by conformance runner's server)
        if tools.tools.contains(where: { $0.name == "add_numbers" }) {
            logger.info("Calling add_numbers tool...")
            let result = try await client.callTool(
                name: "add_numbers",
                arguments: ["a": 5, "b": 3]
            )
            logger.info("Tool result: \(result.content)")
        } else {
            logger.warning("add_numbers tool not found")
        }

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }

    /// Elicitation scenario: tests client handling of elicitation requests
    ///
    /// This requires the client to respond to server-initiated elicitation during tool calls.
    /// Uses streaming mode for bidirectional communication.
    static func runElicitationScenario(serverURL: URL) async throws {
        // Streaming mode is required for bidirectional communication - server needs
        // a channel to send elicitation requests back to client during tool execution
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: true)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        // Set up elicitation handler before connecting
        // When applyDefaults: true, client must fill in default values from schema
        await client.withElicitationHandler(
            formMode: .enabled(applyDefaults: true),
            urlMode: .enabled
        ) { params, _ in
            switch params {
                case let .form(formParams):
                    logger.info("Received elicitation request: \(formParams.message)")

                    // Extract defaults from schema - this is what applyDefaults: true means
                    var content: [String: ElicitValue] = [:]
                    for (fieldName, fieldSchema) in formParams.requestedSchema.properties {
                        if let defaultValue = fieldSchema.default {
                            content[fieldName] = defaultValue
                            logger.debug("Applying default for \(fieldName): \(defaultValue)")
                        }
                    }

                    return ElicitResult(action: .accept, content: content)

                case let .url(urlParams):
                    logger.info("Received URL elicitation request: \(urlParams.message)")
                    return ElicitResult(action: .accept, content: nil)
            }
        }

        logger.info("Connecting to server...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        // Call each elicitation test tool
        for tool in tools.tools where tool.name.contains("elicit") {
            logger.info("Calling tool: \(tool.name)...")
            do {
                let result = try await client.callTool(name: tool.name, arguments: [:])
                logger.info("Tool result: \(result.content)")
            } catch {
                logger.error("Tool error: \(error)")
            }
        }

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }

    /// SSE retry scenario: tests client reconnection behavior with Last-Event-ID
    ///
    /// The client should automatically reconnect when the server closes the SSE stream,
    /// sending the Last-Event-ID header to enable resumability.
    static func runSSERetryScenario(serverURL: URL) async throws {
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: true)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        logger.info("Connecting to server with streaming...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        // Call the test_reconnection tool which triggers the server to close the SSE stream
        // The client should automatically reconnect with Last-Event-ID header
        if tools.tools.contains(where: { $0.name == "test_reconnection" }) {
            logger.info("Calling test_reconnection tool (triggers stream closure)...")
            do {
                let result = try await client.callTool(name: "test_reconnection", arguments: [:])
                logger.info("Tool result: \(result.content)")
            } catch {
                // Stream closure during tool call may cause an error - this is expected
                logger.debug("Tool completed with error (expected during stream closure): \(error)")
            }
        }

        // Wait for automatic reconnection (server sends retry: 500ms)
        logger.info("Waiting for automatic reconnection...")
        try await Task.sleep(for: .seconds(3))

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }
}
