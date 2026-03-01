// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Token Refresh

/// Refreshes an OAuth 2.0 access token using a refresh token grant.
///
/// Sends a `grant_type=refresh_token` request to the token endpoint with
/// appropriate client authentication.
///
/// - Parameters:
///   - refreshToken: The refresh token to use
///   - clientId: The client identifier
///   - clientSecret: The client secret (if the client is confidential)
///   - clientAuthMethod: How to authenticate the client at the token endpoint
///   - tokenEndpoint: The authorization server's token endpoint URL
///   - resource: The resource indicator URL (RFC 8707), if applicable
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The new tokens from the token endpoint
/// - Throws: ``OAuthError`` if the refresh fails
public func refreshAccessToken(
    refreshToken: String,
    clientId: String,
    clientSecret: String?,
    clientAuthMethod: ClientAuthenticationMethod,
    tokenEndpoint: URL,
    resource: URL? = nil,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async throws -> OAuthTokens {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var body: [String: String] = [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
    ]

    if let resource {
        body["resource"] = resource.absoluteString
    }

    try applyClientAuthentication(
        to: &request,
        body: &body,
        clientId: clientId,
        clientSecret: clientSecret,
        method: clientAuthMethod
    )

    request.httpBody = formURLEncodedBody(body)

    let (data, response) = try await httpClient(request)

    guard response.statusCode == 200 else {
        // Try to parse an OAuth error response
        if let errorResponse = try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data) {
            throw OAuthError(from: errorResponse)
        }
        throw OAuthError.tokenRefreshFailed(
            "Token endpoint returned HTTP \(response.statusCode)")
    }

    do {
        var tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        // Preserve the original refresh token if the server didn't return a new one
        if tokens.refreshToken == nil {
            tokens = OAuthTokens(
                accessToken: tokens.accessToken,
                tokenType: tokens.tokenType,
                expiresIn: tokens.expiresIn,
                scope: tokens.scope,
                refreshToken: refreshToken
            )
        }
        return tokens
    } catch {
        throw OAuthError.tokenRefreshFailed("Invalid token response: \(error.localizedDescription)")
    }
}
