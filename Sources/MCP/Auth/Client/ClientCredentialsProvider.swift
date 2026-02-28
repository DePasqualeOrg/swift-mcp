// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An ``OAuthClientProvider`` for the OAuth 2.0 client credentials grant
/// (machine-to-machine authentication).
///
/// This provider is designed for non-interactive flows where no user is
/// present – background services, CI/CD pipelines, server-to-server
/// integrations, and daemon processes. The client authenticates directly
/// with the authorization server using pre-registered credentials.
///
/// ## Usage
///
/// ```swift
/// let provider = ClientCredentialsProvider(
///     serverURL: URL(string: "https://api.example.com/mcp")!,
///     clientId: "service-client",
///     clientSecret: "secret",
///     storage: InMemoryTokenStorage(),
///     scopes: "mcp:read mcp:write"
/// )
///
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     authProvider: provider
/// )
/// ```
///
/// ## Concurrency
///
/// Actor isolation ensures that concurrent requests serialize token
/// operations. When multiple requests see an expired token, only one
/// performs the re-fetch – others await the result.
///
/// - SeeAlso: [RFC 6749 §4.4](https://datatracker.ietf.org/doc/html/rfc6749#section-4.4),
///   [SEP-1046](https://github.com/modelcontextprotocol/specification/blob/main/seps/1046-support-oauth-client-credentials-flow-in-authoriza.md)
public actor ClientCredentialsProvider: OAuthClientProvider {
    // MARK: - Configuration

    private let serverURL: URL
    private let clientId: String
    private let clientSecret: String
    private let storage: any TokenStorage
    private let scopes: String?
    private let httpClient: HTTPRequestHandler

    // MARK: - Cached State

    private var cachedPRM: ProtectedResourceMetadata?
    private var cachedASMetadata: OAuthMetadata?
    private var cachedAuthServerURL: URL?
    private var tokenExpiresAt: Date?
    private var tokensInvalidated = false

    // MARK: - Init

    /// Creates a new provider for the client credentials grant.
    ///
    /// - Parameters:
    ///   - serverURL: The MCP server URL
    ///   - clientId: Pre-registered client identifier
    ///   - clientSecret: Pre-registered client secret
    ///   - storage: Where to cache tokens
    ///   - scopes: Space-delimited scope string (optional)
    ///   - httpClient: HTTP request handler, injectable for testing.
    ///     Defaults to `URLSession`.
    public init(
        serverURL: URL,
        clientId: String,
        clientSecret: String,
        storage: any TokenStorage,
        scopes: String? = nil,
        httpClient: HTTPRequestHandler? = nil
    ) {
        self.serverURL = serverURL
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.storage = storage
        self.scopes = scopes
        self.httpClient = httpClient ?? defaultHTTPRequestHandler
    }

    // MARK: - OAuthClientProvider

    public func tokens() async throws -> OAuthTokens? {
        if tokensInvalidated {
            return nil
        }

        guard let tokens = try await storage.getTokens() else {
            return nil
        }

        // Proactive refresh when near expiry
        if let expiresAt = tokenExpiresAt {
            let refreshWindow: TimeInterval = 60
            if Date().addingTimeInterval(refreshWindow) >= expiresAt {
                return try await attemptRefresh(currentTokens: tokens)
            }
        }

        return tokens
    }

    public func handleUnauthorized(
        context: UnauthorizedContext
    ) async throws -> OAuthTokens {
        do {
            return try await performTokenRequest(context: context)
        } catch let error as OAuthError {
            switch error {
                case .invalidClient, .unauthorizedClient:
                    await invalidateAll()
                    return try await performTokenRequest(context: context)
                case .invalidGrant:
                    await invalidateTokens()
                    return try await performTokenRequest(context: context)
                default:
                    throw error
            }
        }
    }

    // MARK: - Token Refresh

    private func attemptRefresh(currentTokens: OAuthTokens) async throws -> OAuthTokens? {
        guard let refreshToken = currentTokens.refreshToken else {
            return nil
        }

        let authMethod = selectClientAuthenticationMethod(
            serverSupported: cachedASMetadata?.tokenEndpointAuthMethodsSupported,
            clientPreferred: nil,
            hasClientSecret: true
        )

        let tokenURL = tokenEndpoint(
            from: cachedASMetadata,
            authServerURL: cachedAuthServerURL ?? serverURL
        )

        let resource = ResourceURL.selectResourceURL(
            serverURL: serverURL,
            protectedResourceMetadata: cachedPRM
        )

        do {
            let newTokens = try await refreshAccessToken(
                refreshToken: refreshToken,
                clientId: clientId,
                clientSecret: clientSecret,
                clientAuthMethod: authMethod,
                tokenEndpoint: tokenURL,
                resource: resource,
                httpClient: httpClient
            )
            try await storeTokens(newTokens)
            return newTokens
        } catch let error as OAuthError {
            switch error {
                case .invalidGrant:
                    await invalidateTokens()
                    return nil
                case .invalidClient, .unauthorizedClient:
                    await invalidateAll()
                    return nil
                default:
                    throw error
            }
        }
    }

    // MARK: - Token Request

    private func performTokenRequest(
        context: UnauthorizedContext
    ) async throws -> OAuthTokens {
        // 1. Discovery
        let (_, asMetadata) = try await performDiscovery(context: context)

        // 2. Client auth method
        let authMethod = selectClientAuthenticationMethod(
            serverSupported: asMetadata?.tokenEndpointAuthMethodsSupported,
            clientPreferred: nil,
            hasClientSecret: true
        )

        // 3. Token endpoint
        let tokenURL = tokenEndpoint(
            from: asMetadata,
            authServerURL: cachedAuthServerURL ?? serverURL
        )

        // 4. Resource (always included per MCP spec 2025-11-25)
        let resource = ResourceURL.selectResourceURL(
            serverURL: serverURL,
            protectedResourceMetadata: cachedPRM
        )

        // 5. Scope: use 403 step-up scope if provided, otherwise configured scopes
        let scope = context.scope ?? scopes

        // 6. Token request
        let tokens = try await requestClientCredentialsToken(
            clientId: clientId,
            clientSecret: clientSecret,
            clientAuthMethod: authMethod,
            tokenEndpoint: tokenURL,
            scope: scope,
            resource: resource,
            httpClient: httpClient
        )

        // 7. Store tokens
        try await storeTokens(tokens)
        return tokens
    }

    // MARK: - Discovery

    private func performDiscovery(
        context: UnauthorizedContext
    ) async throws -> (URL, OAuthMetadata?) {
        if let authServerURL = cachedAuthServerURL {
            return (authServerURL, cachedASMetadata)
        }

        let prm = await discoverProtectedResourceMetadata(
            serverURL: serverURL,
            wwwAuthenticateResourceMetadataURL: context.resourceMetadataURL,
            httpClient: httpClient
        )
        cachedPRM = prm

        // Validate that PRM's resource matches this server URL
        if let prmResource = prm?.resource {
            let canonical = ResourceURL.canonicalize(serverURL) ?? serverURL
            if !ResourceURL.matches(requested: canonical, configured: prmResource) {
                throw OAuthError.resourceMismatch(expected: canonical, actual: prmResource)
            }
        }

        // Require PRM to provide the authorization server URL. The 2025-03-26
        // spec's origin-based fallback is not supported because it has no
        // authoritative source for the expected issuer, making issuer
        // validation impossible and enabling metadata injection attacks.
        guard let authServerURL = prm?.authorizationServers?.first else {
            throw OAuthError.discoveryFailed(
                "Protected Resource Metadata did not provide an authorization server URL")
        }
        try validateEndpointURL(authServerURL)
        cachedAuthServerURL = authServerURL

        let asMetadata = await discoverAuthorizationServerMetadata(
            authServerURL: authServerURL,
            httpClient: httpClient
        )
        if let asMetadata {
            try validateIssuer(asMetadata, authServerURL: authServerURL)
            try validateASMetadataEndpoints(asMetadata)
        }
        cachedASMetadata = asMetadata

        return (authServerURL, asMetadata)
    }

    // MARK: - Token Storage

    private func storeTokens(_ tokens: OAuthTokens) async throws {
        if let expiresIn = tokens.expiresIn {
            tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            tokenExpiresAt = nil
        }
        tokensInvalidated = false
        try await storage.setTokens(tokens)
    }

    // MARK: - Credential Invalidation

    private func invalidateTokens() async {
        tokenExpiresAt = nil
        tokensInvalidated = true
        try? await storage.removeTokens()
    }

    private func invalidateAll() async {
        await invalidateTokens()
        cachedPRM = nil
        cachedASMetadata = nil
        cachedAuthServerURL = nil
    }
}
