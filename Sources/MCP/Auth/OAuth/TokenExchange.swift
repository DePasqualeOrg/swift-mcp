// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exchanges an authorization code for OAuth tokens at the token endpoint.
///
/// Sends a `grant_type=authorization_code` request with PKCE verification
/// and appropriate client authentication.
///
/// - Parameters:
///   - code: The authorization code received from the callback
///   - codeVerifier: The PKCE code verifier that corresponds to the challenge
///     sent in the authorization request
///   - redirectURI: The redirect URI used in the authorization request
///   - clientId: The client identifier
///   - clientSecret: The client secret (if the client is confidential)
///   - clientAuthMethod: How to authenticate the client at the token endpoint
///   - tokenEndpoint: The authorization server's token endpoint URL
///   - resource: The resource indicator URL (RFC 8707), if applicable
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The tokens from the token endpoint
/// - Throws: ``OAuthError`` if the exchange fails
public func exchangeAuthorizationCode(
    code: String,
    codeVerifier: String,
    redirectURI: URL,
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
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirectURI.absoluteString,
        "code_verifier": codeVerifier,
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

    guard response.statusCode == 200 || response.statusCode == 201 else {
        if let errorResponse = try? JSONDecoder().decode(OAuthTokenErrorResponse.self, from: data) {
            throw OAuthError(from: errorResponse)
        }
        throw OAuthError.authorizationFailed(
            "Token endpoint returned HTTP \(response.statusCode)")
    }

    do {
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    } catch {
        throw OAuthError.authorizationFailed(
            "Invalid token response: \(error.localizedDescription)")
    }
}

/// Returns the token endpoint URL from AS metadata, or falls back to
/// `/token` on the authorization server's origin.
///
/// - Parameters:
///   - metadata: The authorization server's metadata, if available
///   - authServerURL: The authorization server's base URL
/// - Returns: The token endpoint URL
public func tokenEndpoint(
    from metadata: OAuthMetadata?,
    authServerURL: URL
) -> URL {
    if let endpoint = metadata?.tokenEndpoint {
        return endpoint
    }
    return rootRelativeURL("/token", on: authServerURL)
}

/// Returns the authorization endpoint URL from AS metadata, or falls back
/// to `/authorize` on the authorization server's origin.
///
/// - Parameters:
///   - metadata: The authorization server's metadata, if available
///   - authServerURL: The authorization server's base URL
/// - Returns: The authorization endpoint URL
public func authorizationEndpoint(
    from metadata: OAuthMetadata?,
    authServerURL: URL
) -> URL {
    if let endpoint = metadata?.authorizationEndpoint {
        return endpoint
    }
    return rootRelativeURL("/authorize", on: authServerURL)
}

/// Constructs a root-relative URL on the given base URL's origin.
///
/// For example, `rootRelativeURL("/token", on: "https://auth.example.com/v1")`
/// returns `https://auth.example.com/token`, not `https://auth.example.com/v1/token`.
/// This matches the conventional behavior of OAuth authorization servers.
func rootRelativeURL(_ path: String, on baseURL: URL) -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
        return baseURL
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url ?? baseURL
}
