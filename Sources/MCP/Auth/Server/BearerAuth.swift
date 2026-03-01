// Copyright © Anthony DePasquale

import Foundation

/// The result of authenticating an incoming HTTP request.
///
/// - ``authenticated(_:)``: The request has a valid bearer token.
/// - ``unauthorized(_:)``: Authentication failed; the response includes
///   a 401 status code and `WWW-Authenticate` header.
public enum AuthenticationResult: Sendable {
    /// The request was authenticated successfully.
    case authenticated(AuthInfo)
    /// Authentication failed. Return this response to the client.
    case unauthorized(HTTPResponse)
}

/// Validates a bearer token from an incoming HTTP request.
///
/// This function extracts the bearer token from the `Authorization` header,
/// validates it via the ``ServerAuthConfig/tokenVerifier``, checks expiration
/// and audience, and returns either the validated ``AuthInfo`` or an error
/// ``HTTPResponse`` with the appropriate `WWW-Authenticate` header.
///
/// ## Usage
///
/// ```swift
/// let result = await authenticateRequest(httpRequest, config: authConfig)
/// switch result {
/// case .authenticated(let authInfo):
///     let response = await transport.handleRequest(httpRequest, authInfo: authInfo)
///     return convert(response)
/// case .unauthorized(let errorResponse):
///     return convert(errorResponse)  // 401 with WWW-Authenticate
/// }
/// ```
///
/// - Parameters:
///   - request: The incoming HTTP request.
///   - config: Server auth configuration with token verifier and resource identity.
/// - Returns: ``AuthenticationResult/authenticated(_:)`` with validated auth info,
///   or ``AuthenticationResult/unauthorized(_:)`` with a 401 response.
public func authenticateRequest(
    _ request: HTTPRequest,
    config: ServerAuthConfig
) async -> AuthenticationResult {
    // Extract Authorization header
    guard let authHeader = request.header(HTTPHeader.authorization) else {
        return .unauthorized(
            unauthorizedResponse(
                error: "invalid_token",
                description: "Missing Authorization header",
                config: config
            )
        )
    }

    // Verify it's a Bearer token (case-insensitive per RFC 9110 §11.1)
    let bearerPrefix = "Bearer "
    guard authHeader.count >= bearerPrefix.count,
          authHeader.prefix(bearerPrefix.count).caseInsensitiveCompare(bearerPrefix) == .orderedSame
    else {
        return .unauthorized(
            unauthorizedResponse(
                error: "invalid_token",
                description: "Invalid Authorization header format",
                config: config
            )
        )
    }

    let token = String(authHeader.dropFirst(bearerPrefix.count))

    guard !token.isEmpty else {
        return .unauthorized(
            unauthorizedResponse(
                error: "invalid_token",
                description: "Empty bearer token",
                config: config
            )
        )
    }

    // Validate the token via the application-provided verifier
    guard let authInfo = await config.tokenVerifier.verifyToken(token) else {
        return .unauthorized(
            unauthorizedResponse(
                error: "invalid_token",
                description: "Token validation failed",
                config: config
            )
        )
    }

    // Check expiration
    if let expiresAt = authInfo.expiresAt {
        let now = Int(Date().timeIntervalSince1970)
        if expiresAt < now {
            return .unauthorized(
                unauthorizedResponse(
                    error: "invalid_token",
                    description: "Token has expired",
                    config: config
                )
            )
        }
    }

    // Check audience (RFC 8707) – the token's resource must match this server.
    // If the token has a resource claim, validate it. If the claim is present
    // but not a valid URL, reject the token rather than silently skipping validation.
    if let tokenResource = authInfo.resource {
        guard let tokenResourceURL = URL(string: tokenResource) else {
            return .unauthorized(
                unauthorizedResponse(
                    error: "invalid_token",
                    description: "Token has invalid resource identifier",
                    config: config
                )
            )
        }
        if !ResourceURL.matches(requested: tokenResourceURL, configured: config.resource) {
            return .unauthorized(
                unauthorizedResponse(
                    error: "invalid_token",
                    description: "Token not valid for this resource",
                    config: config
                )
            )
        }
    }

    return .authenticated(authInfo)
}

/// Constructs a `WWW-Authenticate` header value for Bearer token error responses.
///
/// The header follows RFC 6750 §3 format with `resource_metadata` from RFC 9728 §5.1:
/// ```
/// Bearer error="invalid_token", error_description="...", resource_metadata="...", scope="..."
/// ```
///
/// - Parameters:
///   - error: The OAuth error code (e.g., `"invalid_token"`, `"insufficient_scope"`).
///   - description: Human-readable error description.
///   - resourceMetadataURL: The URL of the Protected Resource Metadata endpoint.
///   - scope: Required scope(s), space-separated (used for `insufficient_scope` errors).
/// - Returns: The formatted `WWW-Authenticate` header value.
public func buildWWWAuthenticateHeader(
    error: String,
    description: String? = nil,
    resourceMetadataURL: URL,
    scope: String? = nil
) -> String {
    var parts = ["Bearer"]
    var params: [String] = []

    params.append("error=\(quotedString(error))")

    if let description {
        params.append("error_description=\(quotedString(description))")
    }

    params.append("resource_metadata=\(quotedString(resourceMetadataURL.absoluteString))")

    if let scope {
        params.append("scope=\(quotedString(scope))")
    }

    parts.append(params.joined(separator: ", "))
    return parts.joined(separator: " ")
}

/// Builds a 403 Forbidden response for insufficient scope errors.
///
/// Use this when a client has a valid token but needs additional permissions.
/// The response includes a `WWW-Authenticate` header with the `insufficient_scope`
/// error and the required scopes, per RFC 6750 §3.1 and the MCP spec.
///
/// ## Example
///
/// ```swift
/// // In a request handler that requires specific scopes:
/// if !authInfo.scopes.contains("admin") {
///     return insufficientScopeResponse(
///         scope: "admin",
///         description: "Admin scope required",
///         config: authConfig
///     )
/// }
/// ```
///
/// - Parameters:
///   - scope: The scope(s) required, space-separated.
///   - description: Human-readable description of why the scope is insufficient.
///   - config: Server auth configuration.
/// - Returns: An ``HTTPResponse`` with status 403 and `WWW-Authenticate` header.
public func insufficientScopeResponse(
    scope: String,
    description: String? = nil,
    config: ServerAuthConfig
) -> HTTPResponse {
    let prmURL = protectedResourceMetadataURL(for: config.resource)
    let wwwAuth = buildWWWAuthenticateHeader(
        error: "insufficient_scope",
        description: description,
        resourceMetadataURL: prmURL,
        scope: scope
    )

    let errorDescription = description ?? "Insufficient scope"
    let body: Data
    do {
        body = try JSONEncoder().encode(
            OAuthTokenErrorResponse(
                error: "insufficient_scope", errorDescription: errorDescription
            )
        )
    } catch {
        body = Data()
    }

    return HTTPResponse(
        statusCode: 403,
        headers: [
            "www-authenticate": wwwAuth,
            HTTPHeader.contentType: "application/json",
        ],
        body: body
    )
}

// MARK: - Private Helpers

/// Wraps a value in an RFC 9110 §5.6.4 quoted-string, escaping backslashes
/// and double quotes. Swift has no built-in escaping for HTTP header values,
/// so this ensures caller-provided strings (e.g., error descriptions) don't
/// break the `WWW-Authenticate` header format.
private func quotedString(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

/// Builds a 401 HTTP response with the appropriate `WWW-Authenticate` header.
private func unauthorizedResponse(
    error: String,
    description: String,
    config: ServerAuthConfig
) -> HTTPResponse {
    let prmURL = protectedResourceMetadataURL(for: config.resource)
    let scope = config.scopesSupported?.joined(separator: " ")
    let wwwAuth = buildWWWAuthenticateHeader(
        error: error,
        description: description,
        resourceMetadataURL: prmURL,
        scope: scope
    )

    let body: Data
    do {
        body = try JSONEncoder().encode(
            OAuthTokenErrorResponse(error: error, errorDescription: description)
        )
    } catch {
        body = Data()
    }

    return HTTPResponse(
        statusCode: 401,
        headers: [
            "www-authenticate": wwwAuth,
            HTTPHeader.contentType: "application/json",
        ],
        body: body
    )
}
