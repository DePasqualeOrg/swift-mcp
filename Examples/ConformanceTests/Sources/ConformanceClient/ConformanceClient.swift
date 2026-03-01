// Copyright © Anthony DePasquale

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

import CryptoKit
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
            case "auth/client-credentials-jwt":
                try await runClientCredentialsJWTScenario(serverURL: serverURL)
            case "auth/client-credentials-basic":
                try await runClientCredentialsBasicScenario(serverURL: serverURL)
            default:
                if scenario.hasPrefix("auth/") {
                    try await runAuthCodeScenario(serverURL: serverURL)
                } else {
                    logger.error("Unknown scenario: \(scenario)")
                    exit(1)
                }
        }

        logger.info("Scenario completed successfully")
    }

    // MARK: - Non-Auth Scenarios

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
    static func runElicitationScenario(serverURL: URL) async throws {
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: true)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        await client.withElicitationHandler(
            formMode: .enabled(applyDefaults: true),
            urlMode: .enabled
        ) { params, _ in
            switch params {
                case let .form(formParams):
                    logger.info("Received elicitation request: \(formParams.message)")

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
    static func runSSERetryScenario(serverURL: URL) async throws {
        let transport = HTTPClientTransport(endpoint: serverURL, streaming: true)
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        logger.info("Connecting to server with streaming...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        if tools.tools.contains(where: { $0.name == "test_reconnection" }) {
            logger.info("Calling test_reconnection tool (triggers stream closure)...")
            do {
                let result = try await client.callTool(name: "test_reconnection", arguments: [:])
                logger.info("Tool result: \(result.content)")
            } catch {
                logger.debug("Tool completed with error (expected during stream closure): \(error)")
            }
        }

        logger.info("Waiting for automatic reconnection...")
        try await Task.sleep(for: .seconds(3))

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }

    // MARK: - Auth Scenarios

    /// Authorization code flow (default handler for all auth/* scenarios that don't
    /// have a specific handler).
    static func runAuthCodeScenario(serverURL: URL) async throws {
        let callbackHandler = ConformanceOAuthCallbackHandler()
        let storage = InMemoryTokenStorage()

        // Pre-load client credentials from MCP_CONFORMANCE_CONTEXT if provided
        // (used by auth/pre-registration and similar scenarios)
        if let context = loadConformanceContext() {
            if let clientId = context["client_id"] as? String {
                let clientSecret = context["client_secret"] as? String
                let authMethod = if clientSecret != nil {
                    "client_secret_basic"
                } else {
                    "none"
                }
                try await storage.setClientInfo(OAuthClientInformation(
                    clientId: clientId,
                    clientSecret: clientSecret
                ))
                logger.info("Pre-loaded client credentials: client_id=\(clientId), auth_method=\(authMethod)")
            }
        }

        let provider = DefaultOAuthProvider(
            serverURL: serverURL,
            clientMetadata: OAuthClientMetadata(
                redirectURIs: [URL(string: "http://localhost:3000/callback")!],
                grantTypes: ["authorization_code", "refresh_token"],
                responseTypes: ["code"],
                clientName: "conformance-client"
            ),
            storage: storage,
            redirectHandler: { url in
                try await callbackHandler.handleRedirect(authorizationURL: url)
            },
            callbackHandler: {
                try await callbackHandler.handleCallback()
            },
            clientMetadataURL: URL(string: "https://conformance-test.local/client-metadata.json")
        )

        try await runAuthSession(serverURL: serverURL, authProvider: provider)
    }

    /// Client credentials flow with client_secret_basic authentication.
    static func runClientCredentialsBasicScenario(serverURL: URL) async throws {
        let context = try requireConformanceContext()

        guard let clientId = context["client_id"] as? String else {
            throw ConformanceError.missingContextField("client_id")
        }
        guard let clientSecret = context["client_secret"] as? String else {
            throw ConformanceError.missingContextField("client_secret")
        }

        let provider = ClientCredentialsProvider(
            serverURL: serverURL,
            clientId: clientId,
            clientSecret: clientSecret,
            storage: InMemoryTokenStorage()
        )

        try await runAuthSession(serverURL: serverURL, authProvider: provider)
    }

    /// Client credentials flow with private_key_jwt authentication (ES256).
    static func runClientCredentialsJWTScenario(serverURL: URL) async throws {
        let context = try requireConformanceContext()

        guard let clientId = context["client_id"] as? String else {
            throw ConformanceError.missingContextField("client_id")
        }
        guard let privateKeyPEM = context["private_key_pem"] as? String else {
            throw ConformanceError.missingContextField("private_key_pem")
        }

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)

        let provider = PrivateKeyJWTProvider(
            serverURL: serverURL,
            clientId: clientId,
            storage: InMemoryTokenStorage(),
            assertionProvider: { audience in
                try signES256JWT(clientId: clientId, audience: audience, privateKey: privateKey)
            }
        )

        try await runAuthSession(serverURL: serverURL, authProvider: provider)
    }

    /// Common session logic for all OAuth flows.
    static func runAuthSession(serverURL: URL, authProvider: some OAuthClientProvider) async throws {
        let transport = HTTPClientTransport(
            endpoint: serverURL,
            streaming: false,
            authProvider: authProvider
        )
        let client = Client(name: "swift-conformance-client", version: "1.0.0")

        logger.info("Connecting with OAuth...")
        try await client.connect(transport: transport)
        logger.info("Connected successfully")

        logger.info("Listing tools...")
        let tools = try await client.listTools()
        logger.info("Found \(tools.tools.count) tools")

        // Call the first available tool (different test servers expose different tools)
        if let tool = tools.tools.first {
            logger.info("Calling tool: \(tool.name)...")
            do {
                let result = try await client.callTool(name: tool.name, arguments: [:])
                logger.info("Tool result: \(result.content)")
            } catch {
                logger.debug("Tool call error: \(error)")
            }
        }

        logger.info("Disconnecting...")
        await transport.disconnect()
        logger.info("Disconnected")
    }

    // MARK: - Conformance Context

    /// Loads the `MCP_CONFORMANCE_CONTEXT` environment variable as a JSON dictionary.
    static func loadConformanceContext() -> [String: Any]? {
        guard let json = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_CONTEXT"],
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    /// Loads the conformance context, throwing if it's missing or invalid.
    static func requireConformanceContext() throws -> [String: Any] {
        guard let context = loadConformanceContext() else {
            throw ConformanceError.missingContext
        }
        return context
    }
}

// MARK: - OAuth Callback Handler

/// Handles the OAuth authorization code flow automatically for conformance testing.
///
/// The conformance test runner's auth server returns a 302 redirect with `code` and `state`
/// query parameters. This handler fetches the authorization URL without following the
/// redirect, then extracts the code and state from the `Location` header.
final class ConformanceOAuthCallbackHandler: Sendable {
    private let state = CallbackState()

    /// Fetches the authorization URL and captures the redirect with auth code.
    func handleRedirect(authorizationURL: URL) async throws {
        ConformanceClient.logger.debug("Fetching authorization URL: \(authorizationURL)")

        // Use a session that doesn't follow redirects
        let session = URLSession(
            configuration: .ephemeral,
            delegate: NoRedirectDelegate.shared,
            delegateQueue: nil
        )

        let request = URLRequest(url: authorizationURL)
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConformanceError.unexpectedResponse("Not an HTTP response")
        }

        guard (301 ... 308).contains(httpResponse.statusCode) else {
            throw ConformanceError.unexpectedResponse(
                "Expected redirect, got \(httpResponse.statusCode)"
            )
        }

        guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
            throw ConformanceError.unexpectedResponse("No Location header in redirect")
        }

        guard let components = URLComponents(string: location) else {
            throw ConformanceError.unexpectedResponse("Invalid Location URL: \(location)")
        }

        let queryItems = components.queryItems ?? []
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw ConformanceError.unexpectedResponse("No code in redirect URL: \(location)")
        }

        let returnedState = queryItems.first(where: { $0.name == "state" })?.value

        ConformanceClient.logger.debug("Got auth code from redirect: \(String(code.prefix(10)))...")

        await state.store(code: code, state: returnedState)
    }

    /// Returns the captured auth code and state.
    func handleCallback() async throws -> (code: String, state: String?) {
        guard let result = await state.load() else {
            throw ConformanceError.unexpectedResponse(
                "No authorization code available – was handleRedirect called?"
            )
        }
        return result
    }
}

/// Actor to safely store the captured auth code and state between redirect and callback.
private actor CallbackState {
    private var code: String?
    private var state: String?

    func store(code: String, state: String?) {
        self.code = code
        self.state = state
    }

    func load() -> (code: String, state: String?)? {
        guard let code else { return nil }
        let result = (code: code, state: state)
        self.code = nil
        state = nil
        return result
    }
}

/// URLSession delegate that prevents following HTTP redirects.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - ES256 JWT Signing

/// Signs a JWT with ES256 (ECDSA P-256) using CryptoKit.
///
/// This is used by the conformance client for the `auth/client-credentials-jwt` scenario.
/// The SDK itself uses a callback pattern for JWT signing to avoid dependencies; this
/// function provides a concrete implementation for testing.
func signES256JWT(
    clientId: String,
    audience: String,
    privateKey: P256.Signing.PrivateKey
) throws -> String {
    let now = Int(Date().timeIntervalSince1970)

    // Header
    let headerJSON = #"{"alg":"ES256","typ":"JWT"}"#
    let header = base64URLEncode(Data(headerJSON.utf8))

    // Payload
    let payloadDict: [String: Any] = [
        "iss": clientId,
        "sub": clientId,
        "aud": audience,
        "exp": now + 300,
        "iat": now,
        "jti": UUID().uuidString,
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payloadDict)
    let payload = base64URLEncode(payloadData)

    // Signing input
    let signingInput = "\(header).\(payload)"

    // Sign with P-256
    let signature = try privateKey.signature(for: Data(signingInput.utf8))
    let sig = base64URLEncode(signature.rawRepresentation)

    return "\(signingInput).\(sig)"
}

/// Base64url encoding without padding (RFC 4648 §5).
private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - Errors

enum ConformanceError: Error, LocalizedError {
    case missingContext
    case missingContextField(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
            case .missingContext:
                "MCP_CONFORMANCE_CONTEXT environment variable not set"
            case let .missingContextField(field):
                "MCP_CONFORMANCE_CONTEXT missing required field: \(field)"
            case let .unexpectedResponse(detail):
                "Unexpected response: \(detail)"
        }
    }
}
