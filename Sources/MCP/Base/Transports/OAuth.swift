// Copyright © Anthony DePasquale

import Foundation

// MARK: - OAuth Support

// This file provides the foundational types for OAuth 2.0 support in HTTP transports.
// Additional OAuth components (discovery, PKCE, token exchange, client authentication)
// are in the Auth/ directory.

// MARK: - OAuth Types

/// OAuth 2.0 tokens for authenticated requests.
///
/// This struct holds the tokens obtained through an OAuth 2.0 authorization flow,
/// matching the token response format defined in RFC 6749 Section 5.1.
public struct OAuthTokens: Sendable, Codable, Equatable {
    /// The access token to use for Bearer authentication.
    public let accessToken: String

    /// The type of token issued. Per RFC 6749, this is case-insensitive.
    /// For MCP, this is always "Bearer".
    public let tokenType: String

    /// The lifetime in seconds of the access token from when it was issued.
    public let expiresIn: Int?

    /// The scope of the access token as a space-delimited string.
    public let scope: String?

    /// The refresh token for obtaining new access tokens.
    public let refreshToken: String?

    /// The ID token, if the authorization server is also an OpenID Connect provider.
    public let idToken: String?

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int? = nil,
        scope: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
        self.refreshToken = refreshToken
        self.idToken = idToken
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        let rawTokenType = try container.decode(String.self, forKey: .tokenType)
        // Normalize per RFC 6750 §4 (case-insensitive)
        guard rawTokenType.lowercased() == "bearer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tokenType, in: container,
                debugDescription: "Unsupported token_type \"\(rawTokenType)\"; expected \"Bearer\""
            )
        }
        tokenType = "Bearer"
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
    }
}

/// Context provided when the server returns a 401 Unauthorized response.
///
/// Contains information extracted from the `WWW-Authenticate` header
/// that guides the OAuth authorization flow.
public struct UnauthorizedContext: Sendable {
    /// The URL to the Protected Resource Metadata (RFC 9728).
    public let resourceMetadataURL: URL?

    /// The scope requested by the server.
    public let scope: String?

    /// The full `WWW-Authenticate` header value for custom parsing.
    public let wwwAuthenticate: String?

    public init(
        resourceMetadataURL: URL? = nil,
        scope: String? = nil,
        wwwAuthenticate: String? = nil
    ) {
        self.resourceMetadataURL = resourceMetadataURL
        self.scope = scope
        self.wwwAuthenticate = wwwAuthenticate
    }
}

// MARK: - OAuth Provider Protocol

/// A provider for OAuth 2.0 authentication in HTTP client transports.
///
/// The transport calls this protocol's methods to obtain Bearer tokens
/// and handle authorization failures. Implementations manage their own
/// token storage and refresh logic.
///
/// ## Transport Integration
///
/// When the transport has an `authProvider`:
/// 1. Before each request: calls `tokens()` to get the access token
/// 2. On 401 response: calls `handleUnauthorized(context:)` to re-authenticate
/// 3. Retries the request with the new token
///
/// ## SDK-Provided Implementations
///
/// The SDK will provide implementations for common flows:
/// - Authorization code flow with PKCE (interactive)
/// - Client credentials flow (machine-to-machine)
/// - Private key JWT authentication
///
/// Custom implementations can be created for specialized needs.
public protocol OAuthClientProvider: Sendable {
    /// Returns the current OAuth tokens, refreshing if necessary.
    ///
    /// Implementations should:
    /// - Return cached tokens if still valid
    /// - Refresh expired tokens using the refresh token
    /// - Return `nil` if not authenticated (triggers `handleUnauthorized`)
    func tokens() async throws -> OAuthTokens?

    /// Handles a 401 Unauthorized response by performing authorization.
    ///
    /// Called when the server rejects the request. The context contains
    /// information from the `WWW-Authenticate` header to guide the flow.
    ///
    /// - Parameter context: Information from the 401 response
    /// - Returns: New tokens after successful authorization
    func handleUnauthorized(context: UnauthorizedContext) async throws -> OAuthTokens
}
