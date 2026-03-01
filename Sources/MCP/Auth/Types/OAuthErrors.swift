// Copyright © Anthony DePasquale

import Foundation

/// Errors that can occur during OAuth 2.0 authorization flows.
///
/// Covers standard OAuth error codes from RFC 6749 §5.2 and RFC 6750 §3.1,
/// as well as MCP-specific errors for discovery and PKCE.
public enum OAuthError: Error, Sendable, Equatable {
    // MARK: - Token endpoint errors (RFC 6749 §5.2)

    /// The request is missing a required parameter or is otherwise malformed.
    case invalidRequest(String?)

    /// Client authentication failed.
    case invalidClient(String?)

    /// The authorization grant or refresh token is invalid, expired, or revoked.
    case invalidGrant(String?)

    /// The client is not authorized to use this grant type.
    case unauthorizedClient(String?)

    /// The authorization server does not support this grant type.
    case unsupportedGrantType(String?)

    /// The requested scope is invalid, unknown, or exceeds what was granted.
    case invalidScope(String?)

    /// The resource owner denied the authorization request.
    case accessDenied(String?)

    /// The authorization server encountered an unexpected error.
    case serverError(String?)

    /// The server is temporarily unable to handle the request.
    case temporarilyUnavailable(String?)

    /// The authorization server does not support the requested response type.
    case unsupportedResponseType(String?)

    // MARK: - Resource server errors (RFC 6750 §3.1)

    /// The access token is expired, revoked, or otherwise invalid.
    case invalidToken(String?)

    /// The request requires higher privileges than provided by the access token.
    case insufficientScope(String?)

    /// The token type is not supported by the revocation endpoint.
    case unsupportedTokenType(String?)

    // MARK: - Resource indicator errors (RFC 8707)

    /// The target resource is invalid or not recognized.
    case invalidTarget(String?)

    // MARK: - Dynamic client registration errors (RFC 7591)

    /// The client metadata provided during registration is invalid.
    case invalidClientMetadata(String?)

    // MARK: - Unrecognized errors

    /// An error code not in the set of standard OAuth or MCP error codes.
    case unrecognizedError(code: String, description: String?)

    // MARK: - MCP-specific errors

    /// Protected Resource Metadata or AS Metadata discovery failed at all fallback URLs.
    case discoveryFailed(String)

    /// The authorization server does not support PKCE with S256.
    case pkceNotSupported

    /// Token refresh failed and re-authorization is required.
    case tokenRefreshFailed(String)

    /// The state parameter returned from the authorization callback does not match.
    case invalidState

    /// Client registration failed.
    case registrationFailed(String)

    /// The authorization flow failed (e.g., redirect or callback error).
    case authorizationFailed(String)

    /// The Protected Resource Metadata `resource` field does not match the server URL.
    case resourceMismatch(expected: URL, actual: URL)

    /// Creates an `OAuthError` from an ``OAuthTokenErrorResponse``.
    ///
    /// Maps the `error` field from the token endpoint response to the appropriate case.
    /// Unknown error codes are mapped to ``unrecognizedError(code:description:)``.
    public init(from response: OAuthTokenErrorResponse) {
        switch response.error {
            case "invalid_request":
                self = .invalidRequest(response.errorDescription)
            case "invalid_client":
                self = .invalidClient(response.errorDescription)
            case "invalid_grant":
                self = .invalidGrant(response.errorDescription)
            case "unauthorized_client":
                self = .unauthorizedClient(response.errorDescription)
            case "unsupported_grant_type":
                self = .unsupportedGrantType(response.errorDescription)
            case "invalid_scope":
                self = .invalidScope(response.errorDescription)
            case "access_denied":
                self = .accessDenied(response.errorDescription)
            case "server_error":
                self = .serverError(response.errorDescription)
            case "temporarily_unavailable":
                self = .temporarilyUnavailable(response.errorDescription)
            case "invalid_token":
                self = .invalidToken(response.errorDescription)
            case "insufficient_scope":
                self = .insufficientScope(response.errorDescription)
            case "unsupported_response_type":
                self = .unsupportedResponseType(response.errorDescription)
            case "unsupported_token_type":
                self = .unsupportedTokenType(response.errorDescription)
            case "invalid_target":
                self = .invalidTarget(response.errorDescription)
            case "invalid_client_metadata":
                self = .invalidClientMetadata(response.errorDescription)
            default:
                self = .unrecognizedError(code: response.error, description: response.errorDescription)
        }
    }
}

extension OAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case let .invalidRequest(detail):
                detail ?? "The OAuth request is missing a required parameter or is otherwise malformed."
            case let .invalidClient(detail):
                detail ?? "Client authentication failed."
            case let .invalidGrant(detail):
                detail ?? "The authorization grant or refresh token is invalid, expired, or revoked."
            case let .unauthorizedClient(detail):
                detail ?? "The client is not authorized to use this grant type."
            case let .unsupportedGrantType(detail):
                detail ?? "The authorization server does not support this grant type."
            case let .invalidScope(detail):
                detail ?? "The requested scope is invalid, unknown, or exceeds what was granted."
            case let .accessDenied(detail):
                detail ?? "The resource owner denied the authorization request."
            case let .serverError(detail):
                detail ?? "The authorization server encountered an unexpected error."
            case let .temporarilyUnavailable(detail):
                detail ?? "The authorization server is temporarily unable to handle the request."
            case let .unsupportedResponseType(detail):
                detail ?? "The authorization server does not support the requested response type."
            case let .invalidToken(detail):
                detail ?? "The access token is expired, revoked, or otherwise invalid."
            case let .insufficientScope(detail):
                detail ?? "The request requires higher privileges than provided by the access token."
            case let .unsupportedTokenType(detail):
                detail ?? "The token type is not supported."
            case let .invalidTarget(detail):
                detail ?? "The target resource is invalid or not recognized."
            case let .invalidClientMetadata(detail):
                detail ?? "The client metadata provided during registration is invalid."
            case let .unrecognizedError(code, description):
                description ?? "OAuth error: \(code)"
            case let .discoveryFailed(detail):
                "OAuth discovery failed: \(detail)"
            case .pkceNotSupported:
                "The authorization server does not support PKCE with S256, which is required by the MCP specification."
            case let .tokenRefreshFailed(detail):
                "Token refresh failed: \(detail)"
            case .invalidState:
                "The state parameter returned from the authorization callback does not match the expected value."
            case let .registrationFailed(detail):
                "Client registration failed: \(detail)"
            case let .authorizationFailed(detail):
                "Authorization flow failed: \(detail)"
            case let .resourceMismatch(expected, actual):
                "Protected Resource Metadata resource \(actual) does not match expected \(expected)"
        }
    }
}
