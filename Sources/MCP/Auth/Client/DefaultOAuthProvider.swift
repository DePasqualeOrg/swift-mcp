// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A ready-to-use implementation of ``OAuthClientProvider`` that handles the
/// full OAuth 2.0 authorization code flow with PKCE.
///
/// This actor manages the complete OAuth lifecycle:
/// - Metadata discovery (PRM and AS metadata)
/// - Client registration (CIMD or DCR)
/// - Authorization code flow with PKCE and state verification
/// - Token storage, refresh, and proactive renewal
/// - Error recovery (credential invalidation and retry)
///
/// ## Usage
///
/// ```swift
/// let provider = DefaultOAuthProvider(
///     serverURL: URL(string: "https://api.example.com/mcp")!,
///     clientMetadata: OAuthClientMetadata(
///         redirectURIs: [URL(string: "http://127.0.0.1:3000/callback")!],
///         clientName: "My MCP Client"
///     ),
///     storage: InMemoryTokenStorage(),
///     redirectHandler: { url in await openBrowser(url) },
///     callbackHandler: { try await waitForCallback() }
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
/// Actor isolation ensures that concurrent requests serialize token refresh
/// and authorization operations. When multiple requests see an expired token
/// simultaneously, only one performs the refresh – others await the result.
public actor DefaultOAuthProvider: OAuthClientProvider {
    // MARK: - Configuration

    private let serverURL: URL
    private let clientMetadata: OAuthClientMetadata
    private let redirectURI: URL
    private let storage: any TokenStorage
    private let redirectHandler: @Sendable (URL) async throws -> Void
    private let callbackHandler: @Sendable () async throws -> (code: String, state: String?)
    private let clientMetadataURL: URL?
    private let httpClient: HTTPRequestHandler

    // MARK: - Cached State

    private var cachedPRM: ProtectedResourceMetadata?
    private var cachedASMetadata: OAuthMetadata?
    private var cachedAuthServerURL: URL?
    private var tokenExpiresAt: Date?
    private var tokensInvalidated = false
    private var clientInfoInvalidated = false

    // MARK: - Init

    /// Creates a new OAuth provider for the authorization code flow.
    ///
    /// - Parameters:
    ///   - serverURL: The MCP server URL
    ///   - clientMetadata: The client's OAuth metadata for registration
    ///   - storage: Where to store tokens and client registration info
    ///   - redirectHandler: Opens the authorization URL (e.g., in a browser)
    ///   - callbackHandler: Waits for the OAuth callback and returns the
    ///     authorization code and state parameter
    ///   - clientMetadataURL: URL for Client ID Metadata Documents (SEP-991).
    ///     Must be HTTPS with a non-root path.
    ///   - httpClient: HTTP request handler, injectable for testing.
    ///     Defaults to `URLSession`.
    public init(
        serverURL: URL,
        clientMetadata: OAuthClientMetadata,
        storage: any TokenStorage,
        redirectHandler: @Sendable @escaping (URL) async throws -> Void,
        callbackHandler: @Sendable @escaping () async throws -> (code: String, state: String?),
        clientMetadataURL: URL? = nil,
        httpClient: HTTPRequestHandler? = nil
    ) {
        precondition(
            clientMetadata.redirectURIs?.isEmpty == false,
            "DefaultOAuthProvider requires at least one redirect URI in clientMetadata.redirectURIs"
        )
        self.serverURL = serverURL
        self.clientMetadata = clientMetadata
        redirectURI = clientMetadata.redirectURIs![0]
        self.storage = storage
        self.redirectHandler = redirectHandler
        self.callbackHandler = callbackHandler
        self.clientMetadataURL = clientMetadataURL
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

        // Check if the token is near expiry and should be proactively refreshed
        if let expiresAt = tokenExpiresAt {
            let refreshWindow: TimeInterval = 60
            if Date().addingTimeInterval(refreshWindow) >= expiresAt {
                // Token is expired or will expire within the refresh window
                return try await attemptRefresh(currentTokens: tokens)
            }
        }

        return tokens
    }

    public func handleUnauthorized(
        context: UnauthorizedContext
    ) async throws -> OAuthTokens {
        do {
            return try await performAuthorizationFlow(context: context)
        } catch let error as OAuthError {
            // Error recovery: invalidate credentials and retry once
            switch error {
                case .invalidClient, .unauthorizedClient:
                    await invalidateAll()
                    return try await performAuthorizationFlow(context: context)
                case .invalidGrant:
                    await invalidateTokens()
                    return try await performAuthorizationFlow(context: context)
                default:
                    throw error
            }
        }
    }

    // MARK: - Token Refresh

    private func attemptRefresh(currentTokens: OAuthTokens) async throws -> OAuthTokens? {
        guard let refreshToken = currentTokens.refreshToken else {
            // No refresh token, can't refresh – caller will trigger handleUnauthorized
            return nil
        }

        let clientInfo = try await storage.getClientInfo()

        // If the client secret has expired, re-registration is needed
        if let clientInfo, isClientSecretExpired(clientInfo) {
            await invalidateAll()
            return nil
        }

        let clientId = clientInfo?.clientId ?? ""

        let authMethod = selectClientAuthenticationMethod(
            serverSupported: cachedASMetadata?.tokenEndpointAuthMethodsSupported,
            clientPreferred: clientMetadata.tokenEndpointAuthMethod,
            hasClientSecret: clientInfo?.clientSecret != nil
        )

        let tokenURL = tokenEndpoint(from: cachedASMetadata, authServerURL: cachedAuthServerURL ?? serverURL)

        let resource = ResourceURL.selectResourceURL(serverURL: serverURL, protectedResourceMetadata: cachedPRM)

        do {
            let newTokens = try await refreshAccessToken(
                refreshToken: refreshToken,
                clientId: clientId,
                clientSecret: clientInfo?.clientSecret,
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

    // MARK: - Authorization Flow

    private func performAuthorizationFlow(
        context: UnauthorizedContext
    ) async throws -> OAuthTokens {
        // 1. Discovery
        let (authServerURL, asMetadata) = try await performDiscovery(context: context)

        // 2. PKCE check
        if let asMetadata {
            guard PKCE.isSupported(by: asMetadata) else {
                throw OAuthError.pkceNotSupported
            }
        }

        // 3. Client registration
        let clientInfo = try await performRegistration(asMetadata: asMetadata, authServerURL: authServerURL)

        // 4. Scope selection
        let scope = selectScope(
            wwwAuthenticateScope: context.scope,
            protectedResourceMetadata: cachedPRM,
            authServerMetadata: asMetadata,
            clientMetadataScope: clientMetadata.scope
        )

        // 5. Resource selection (always included per MCP spec 2025-11-25)
        let resource = ResourceURL.selectResourceURL(serverURL: serverURL, protectedResourceMetadata: cachedPRM)

        // 6. Build authorization URL
        let pkce = PKCE.Challenge.generate()
        let state = generateState()

        let authEndpoint = authorizationEndpoint(from: asMetadata, authServerURL: authServerURL)
        let authURL = buildAuthorizationURL(
            authorizationEndpoint: authEndpoint,
            clientId: clientInfo.clientId,
            redirectURI: redirectURI,
            codeChallenge: pkce.challenge,
            state: state,
            scope: scope,
            resource: resource
        )

        // 7. Redirect
        try await redirectHandler(authURL)

        // 8. Callback
        let (code, returnedState) = try await callbackHandler()

        // 9. State verification
        guard verifyState(returned: returnedState, expected: state) else {
            throw OAuthError.invalidState
        }

        // 10. Token exchange
        let authMethod = selectClientAuthenticationMethod(
            serverSupported: asMetadata?.tokenEndpointAuthMethodsSupported,
            clientPreferred: clientMetadata.tokenEndpointAuthMethod,
            hasClientSecret: clientInfo.clientSecret != nil
        )

        let tokenURL = tokenEndpoint(from: asMetadata, authServerURL: authServerURL)

        let tokens = try await exchangeAuthorizationCode(
            code: code,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURI,
            clientId: clientInfo.clientId,
            clientSecret: clientInfo.clientSecret,
            clientAuthMethod: authMethod,
            tokenEndpoint: tokenURL,
            resource: resource,
            httpClient: httpClient
        )

        // 11. Store tokens
        try await storeTokens(tokens)
        return tokens
    }

    // MARK: - Discovery

    private func performDiscovery(
        context: UnauthorizedContext
    ) async throws -> (URL, OAuthMetadata?) {
        // Use cached discovery state if available
        if let authServerURL = cachedAuthServerURL {
            return (authServerURL, cachedASMetadata)
        }

        // PRM discovery
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

        // AS metadata discovery
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

    // MARK: - Registration

    private func performRegistration(
        asMetadata: OAuthMetadata?,
        authServerURL: URL
    ) async throws -> OAuthClientInformation {
        // Check storage first (unless client info was invalidated or the secret expired)
        if !clientInfoInvalidated, let existing = try await storage.getClientInfo(),
           !isClientSecretExpired(existing)
        {
            return existing
        }

        let clientInfo: OAuthClientInformation

        // CIMD (SEP-991) preferred over DCR
        if let asMetadata,
           let metadataURL = clientMetadataURL,
           shouldUseCIMD(serverMetadata: asMetadata, clientMetadataURL: metadataURL)
        {
            clientInfo = clientInfoFromMetadataURL(metadataURL, redirectURIs: clientMetadata.redirectURIs)
        } else {
            // DCR (RFC 7591)
            let regEndpoint = try registrationEndpoint(from: asMetadata, authServerURL: authServerURL)
            clientInfo = try await registerClient(
                clientMetadata: clientMetadata,
                registrationEndpoint: regEndpoint,
                httpClient: httpClient
            )
        }

        clientInfoInvalidated = false
        try await storage.setClientInfo(clientInfo)
        return clientInfo
    }

    // MARK: - Authorization URL

    private func buildAuthorizationURL(
        authorizationEndpoint: URL,
        clientId: String,
        redirectURI: URL,
        codeChallenge: String,
        state: String,
        scope: String?,
        resource: URL?
    ) -> URL {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: true)
        else {
            return authorizationEndpoint
        }

        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let scope {
            queryItems.append(URLQueryItem(name: "scope", value: scope))

            // OIDC: request consent prompt for offline_access
            if scope.contains("offline_access") {
                queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
            }
        }

        if let resource {
            queryItems.append(URLQueryItem(name: "resource", value: resource.absoluteString))
        }

        components.queryItems = queryItems
        return components.url ?? authorizationEndpoint
    }

    // MARK: - Token Storage Helpers

    private func storeTokens(_ tokens: OAuthTokens) async throws {
        // Compute absolute expiry from relative expires_in
        if let expiresIn = tokens.expiresIn {
            tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            tokenExpiresAt = nil
        }
        tokensInvalidated = false
        try await storage.setTokens(tokens)
    }

    // MARK: - Client Secret Expiry

    /// Whether the client secret from DCR has expired (RFC 7591 §3.2.1).
    /// A value of 0 means the secret does not expire.
    private func isClientSecretExpired(_ clientInfo: OAuthClientInformation) -> Bool {
        guard let expiresAt = clientInfo.clientSecretExpiresAt, expiresAt != 0 else {
            return false
        }
        return Date().timeIntervalSince1970 >= TimeInterval(expiresAt)
    }

    // MARK: - Credential Invalidation

    private func invalidateTokens() async {
        tokenExpiresAt = nil
        tokensInvalidated = true
        try? await storage.removeTokens()
    }

    private func invalidateAll() async {
        await invalidateTokens()
        clientInfoInvalidated = true
        try? await storage.removeClientInfo()
        cachedPRM = nil
        cachedASMetadata = nil
        cachedAuthServerURL = nil
    }
}
