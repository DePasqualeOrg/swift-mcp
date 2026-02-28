// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Client Authentication Methods

/// OAuth 2.0 client authentication method for the token endpoint.
///
/// Determines how the client authenticates itself when making requests
/// to the authorization server's token endpoint.
///
/// - SeeAlso: [RFC 6749 §2.3](https://datatracker.ietf.org/doc/html/rfc6749#section-2.3)
public enum ClientAuthenticationMethod: String, Sendable, Equatable {
    /// Public client with no secret. Only `client_id` is included in the request body.
    /// Typically used with PKCE or Client ID Metadata Documents.
    case none

    /// HTTP Basic authentication with `client_id:client_secret` in the `Authorization` header.
    /// Values are URL-encoded before base64 encoding per RFC 6749 §2.3.1.
    case clientSecretBasic = "client_secret_basic"

    /// Client credentials included in the POST request body.
    case clientSecretPost = "client_secret_post"
}

/// Applies client authentication to a token endpoint request.
///
/// Mutates the given request's headers and/or body to include client credentials
/// using the specified authentication method.
///
/// - Parameters:
///   - request: The URLRequest to modify (passed by reference)
///   - body: The request body parameters (passed by reference, may be modified for `post` and `none` methods)
///   - clientId: The client identifier
///   - clientSecret: The client secret (required for `clientSecretBasic` and `clientSecretPost`)
///   - method: The authentication method to apply
public func applyClientAuthentication(
    to request: inout URLRequest,
    body: inout [String: String],
    clientId: String,
    clientSecret: String?,
    method: ClientAuthenticationMethod
) throws {
    switch method {
        case .none:
            // Public client: include client_id in body, no secret
            body["client_id"] = clientId

        case .clientSecretBasic:
            // HTTP Basic: Authorization: Basic base64(urlEncode(id):urlEncode(secret))
            guard let clientSecret else {
                throw OAuthError.invalidClient(
                    "client_secret_basic authentication requires a client secret")
            }
            let encodedId =
                clientId.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? clientId
            let encodedSecret =
                clientSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
                    ?? clientSecret
            let credentials = "\(encodedId):\(encodedSecret)"
            let base64Credentials = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        case .clientSecretPost:
            // POST body: include client_id and client_secret in form body
            body["client_id"] = clientId
            guard let clientSecret else {
                throw OAuthError.invalidClient(
                    "client_secret_post authentication requires a client secret")
            }
            body["client_secret"] = clientSecret
    }
}

/// Selects the best client authentication method based on server capabilities,
/// client preference, and whether the client has a secret.
///
/// - Parameters:
///   - serverSupported: Authentication methods the server supports (from AS metadata
///     `token_endpoint_auth_methods_supported`). If `nil`, defaults to `["client_secret_basic"]`
///     per RFC 8414 §2.
///   - clientPreferred: The method the client prefers (from client metadata
///     `token_endpoint_auth_method`). If `nil`, the first mutually supported method is used.
///   - hasClientSecret: Whether the client has a secret. Confidential clients (with a secret)
///     prefer `client_secret_basic` or `client_secret_post`; public clients prefer `none`.
/// - Returns: The selected authentication method, falling back to `.none` if no match
public func selectClientAuthenticationMethod(
    serverSupported: [String]?,
    clientPreferred: String?,
    hasClientSecret: Bool = false
) -> ClientAuthenticationMethod {
    // RFC 8414 §2: default is client_secret_basic if not specified
    let supported = serverSupported ?? ["client_secret_basic"]

    // If client has a preference, check if server supports it
    if let preferred = clientPreferred,
       let method = ClientAuthenticationMethod(rawValue: preferred),
       supported.contains(preferred)
    {
        return method
    }

    // Priority depends on whether the client is confidential (has a secret) or public.
    let priority: [ClientAuthenticationMethod] = if hasClientSecret {
        [.clientSecretBasic, .clientSecretPost, .none]
    } else {
        [.none, .clientSecretPost, .clientSecretBasic]
    }
    for method in priority {
        if supported.contains(method.rawValue) {
            return method
        }
    }

    // Fallback if nothing matches
    return .none
}

// MARK: - URL Encoding Helpers

extension CharacterSet {
    /// RFC 3986 unreserved characters only: `A-Z a-z 0-9 - . _ ~`.
    ///
    /// Used for `application/x-www-form-urlencoded` encoding (RFC 6749 §2.3.1) and
    /// form body encoding. This is stricter than `urlQueryAllowed`, which permits
    /// sub-delimiters like `@`, `:`, `/`, and `!` that must be percent-encoded in
    /// OAuth credential and form body values.
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return allowed
    }()
}

// MARK: - Form Body Encoding

/// Encodes a dictionary of string parameters as `application/x-www-form-urlencoded` body data.
///
/// - Parameter parameters: The key-value pairs to encode
/// - Returns: The encoded form data
public func formURLEncodedBody(_ parameters: [String: String]) -> Data {
    let encoded = parameters.sorted(by: { $0.key < $1.key }).map { key, value in
        let encodedKey =
            key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
        let encodedValue =
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")

    return Data(encoded.utf8)
}
