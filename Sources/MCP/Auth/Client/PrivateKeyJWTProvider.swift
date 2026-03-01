// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An ``OAuthClientProvider`` that authenticates using JWT assertions
/// (RFC 7523) with the client credentials grant.
///
/// This is the **recommended** authentication method for machine-to-machine
/// flows per SEP-1046. The JWT assertion carries the client's identity,
/// so no client secret is transmitted.
///
/// The provider delegates JWT creation to an `assertionProvider` callback,
/// which receives the audience URL (the authorization server) and returns
/// a signed JWT string. This keeps the SDK dependency-free – you can use
/// any JWT library (jwt-kit, CryptoKit, etc.) or return a pre-built JWT
/// from a cloud identity provider.
///
/// ## Usage
///
/// ```swift
/// // Custom JWT signing
/// let provider = PrivateKeyJWTProvider(
///     serverURL: URL(string: "https://api.example.com/mcp")!,
///     clientId: "enterprise-client",
///     storage: InMemoryTokenStorage(),
///     assertionProvider: { audience in
///         try signJWT(clientId: "enterprise-client", audience: audience, key: privateKey)
///     },
///     scopes: "mcp:read mcp:write"
/// )
///
/// // Pre-built JWT from a secrets manager or cloud identity
/// let provider = PrivateKeyJWTProvider(
///     serverURL: URL(string: "https://api.example.com/mcp")!,
///     clientId: "workload-client",
///     storage: InMemoryTokenStorage(),
///     assertionProvider: staticAssertionProvider(prebuiltJWT)
/// )
/// ```
///
/// ## JWT Claims
///
/// The assertion provider should produce a JWT with these claims:
/// - `iss`: The client ID
/// - `sub`: The client ID
/// - `aud`: The audience URL passed to the callback (the AS issuer URL)
/// - `exp`: Expiration time (typically 5 minutes from now)
/// - `iat`: Issued-at time
/// - `jti`: A unique identifier (e.g., UUID) to prevent replay
///
/// ## Concurrency
///
/// Actor isolation serializes token operations, same as
/// ``ClientCredentialsProvider`` and ``DefaultOAuthProvider``.
///
/// - SeeAlso: [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523),
///   [SEP-1046](https://github.com/modelcontextprotocol/specification/blob/main/seps/1046-support-oauth-client-credentials-flow-in-authoriza.md)
public actor PrivateKeyJWTProvider: OAuthClientProvider {
    // MARK: - Configuration

    private let serverURL: URL
    private let clientId: String
    private let storage: any TokenStorage
    private let assertionProvider: @Sendable (String) async throws -> String
    private let scopes: String?
    private let httpClient: HTTPRequestHandler

    // MARK: - Cached State

    private var cachedPRM: ProtectedResourceMetadata?
    private var cachedASMetadata: OAuthMetadata?
    private var cachedAuthServerURL: URL?
    private var tokenExpiresAt: Date?
    private var tokensInvalidated = false

    // MARK: - Init

    /// Creates a new provider using JWT assertion authentication.
    ///
    /// - Parameters:
    ///   - serverURL: The MCP server URL
    ///   - clientId: The client identifier (also used as JWT `iss` and `sub`)
    ///   - storage: Where to cache tokens
    ///   - assertionProvider: A callback that receives the audience URL string
    ///     and returns a signed JWT. Called fresh on every token request.
    ///   - scopes: Space-delimited scope string (optional)
    ///   - httpClient: HTTP request handler, injectable for testing.
    ///     Defaults to `URLSession`.
    public init(
        serverURL: URL,
        clientId: String,
        storage: any TokenStorage,
        assertionProvider: @Sendable @escaping (String) async throws -> String,
        scopes: String? = nil,
        httpClient: HTTPRequestHandler? = nil
    ) {
        self.serverURL = serverURL
        self.clientId = clientId
        self.storage = storage
        self.assertionProvider = assertionProvider
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

        let tokenURL = tokenEndpoint(
            from: cachedASMetadata,
            authServerURL: cachedAuthServerURL ?? serverURL
        )

        let resource = ResourceURL.selectResourceURL(
            serverURL: serverURL,
            protectedResourceMetadata: cachedPRM
        )

        // Use JWT assertion for client auth during refresh, matching the
        // authentication method used for the initial token request. Some
        // authorization servers require consistent client authentication
        // across grant types.
        let audience = cachedASMetadata?.issuer.absoluteString ?? tokenURL.absoluteString
        let assertion = try await assertionProvider(audience)

        do {
            let newTokens = try await refreshAccessTokenWithJWTAssertion(
                refreshToken: refreshToken,
                assertion: assertion,
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

        // 2. Determine JWT audience: AS issuer URL, or token endpoint as fallback
        let tokenURL = tokenEndpoint(
            from: asMetadata,
            authServerURL: cachedAuthServerURL ?? serverURL
        )
        let audience = asMetadata?.issuer.absoluteString ?? tokenURL.absoluteString

        // 3. Get fresh JWT assertion
        let assertion = try await assertionProvider(audience)

        // 4. Resource (always included per MCP spec 2025-11-25)
        let resource = ResourceURL.selectResourceURL(
            serverURL: serverURL,
            protectedResourceMetadata: cachedPRM
        )

        // 5. Scope: use 403 step-up scope if provided, otherwise configured scopes
        let scope = context.scope ?? scopes

        // 6. Token request with JWT assertion
        let tokens = try await requestTokenWithJWTAssertion(
            assertion: assertion,
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

// MARK: - Static Assertion Provider

/// Creates an assertion provider that always returns the same pre-built JWT,
/// regardless of the audience parameter.
///
/// Use this for workload identity federation or pre-signed JWTs from a
/// secrets manager where the JWT is obtained externally.
///
/// - Parameter jwt: The pre-built JWT string
/// - Returns: An assertion provider closure for use with ``PrivateKeyJWTProvider``
public func staticAssertionProvider(_ jwt: String) -> @Sendable (String) async throws -> String {
    { _ in jwt }
}
