// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Client Credentials Grant (RFC 6749 §4.4)

/// Requests an access token using the OAuth 2.0 client credentials grant.
///
/// Sends a `grant_type=client_credentials` request to the token endpoint with
/// client authentication via HTTP Basic, POST body, or no credentials.
///
/// - Parameters:
///   - clientId: The client identifier
///   - clientSecret: The client secret (if the client is confidential)
///   - clientAuthMethod: How to authenticate the client at the token endpoint
///   - tokenEndpoint: The authorization server's token endpoint URL
///   - scope: Space-delimited scope string, if any
///   - resource: The resource indicator URL (RFC 8707), if applicable
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The tokens from the token endpoint
/// - Throws: ``OAuthError`` if the request fails
public func requestClientCredentialsToken(
    clientId: String,
    clientSecret: String?,
    clientAuthMethod: ClientAuthenticationMethod,
    tokenEndpoint: URL,
    scope: String? = nil,
    resource: URL? = nil,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async throws -> OAuthTokens {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var body = [
        "grant_type": "client_credentials",
    ]

    if let scope {
        body["scope"] = scope
    }

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

// MARK: - JWT Assertion Client Authentication (RFC 7523)

/// The `client_assertion_type` value for JWT Bearer assertions.
public let jwtBearerAssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

/// Requests an access token using the client credentials grant with a JWT
/// assertion for client authentication (RFC 7523).
///
/// The JWT assertion carries the client's identity in its `iss` and `sub`
/// claims, so `client_id` is not included in the request body.
///
/// - Parameters:
///   - assertion: The signed JWT assertion string
///   - tokenEndpoint: The authorization server's token endpoint URL
///   - scope: Space-delimited scope string, if any
///   - resource: The resource indicator URL (RFC 8707), if applicable
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The tokens from the token endpoint
/// - Throws: ``OAuthError`` if the request fails
public func requestTokenWithJWTAssertion(
    assertion: String,
    tokenEndpoint: URL,
    scope: String? = nil,
    resource: URL? = nil,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async throws -> OAuthTokens {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var body: [String: String] = [
        "grant_type": "client_credentials",
        "client_assertion_type": jwtBearerAssertionType,
        "client_assertion": assertion,
    ]

    if let scope {
        body["scope"] = scope
    }

    if let resource {
        body["resource"] = resource.absoluteString
    }

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

// MARK: - JWT Assertion Refresh (RFC 7523 + RFC 6749 §6)

/// Refreshes an access token using a refresh token grant with JWT assertion
/// for client authentication (RFC 7523).
///
/// Authorization servers that issued tokens using `private_key_jwt`
/// authentication may require the same authentication method for refresh.
/// This function sends `grant_type=refresh_token` with the JWT assertion
/// parameters for client authentication.
///
/// - Parameters:
///   - refreshToken: The refresh token to use
///   - assertion: The signed JWT assertion string
///   - tokenEndpoint: The authorization server's token endpoint URL
///   - resource: The resource indicator URL (RFC 8707), if applicable
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The new tokens from the token endpoint
/// - Throws: ``OAuthError`` if the refresh fails
public func refreshAccessTokenWithJWTAssertion(
    refreshToken: String,
    assertion: String,
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
        "client_assertion_type": jwtBearerAssertionType,
        "client_assertion": assertion,
    ]

    if let resource {
        body["resource"] = resource.absoluteString
    }

    request.httpBody = formURLEncodedBody(body)

    let (data, response) = try await httpClient(request)

    guard response.statusCode == 200 || response.statusCode == 201 else {
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
        throw OAuthError.tokenRefreshFailed(
            "Invalid token response: \(error.localizedDescription)")
    }
}
