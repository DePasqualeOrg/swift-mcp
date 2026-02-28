// Copyright © Anthony DePasquale

/// Application-provided token validator for MCP server auth.
///
/// The SDK calls ``verifyToken(_:)`` to validate bearer tokens extracted from
/// incoming requests. The application decides the validation strategy — JWT
/// verification, token introspection, database lookup, or any other approach.
///
/// The SDK handles audience validation separately: ``verifyToken(_:)`` returns
/// what the token claims (via ``AuthInfo``), and the SDK verifies that the
/// ``AuthInfo/resource`` field matches this server's configured resource URL.
///
/// ## Example
///
/// ```swift
/// struct MyTokenVerifier: TokenVerifier {
///     func verifyToken(_ token: String) async -> AuthInfo? {
///         // Look up the token in your database or validate a JWT
///         guard let record = await tokenStore.find(token) else {
///             return nil
///         }
///         return AuthInfo(
///             token: token,
///             clientId: record.clientId,
///             scopes: record.scopes,
///             expiresAt: record.expiresAt,
///             resource: record.resource
///         )
///     }
/// }
/// ```
public protocol TokenVerifier: Sendable {
    /// Validates a bearer token and returns structured auth info if valid.
    ///
    /// - Parameter token: The bearer token string extracted from the `Authorization` header.
    /// - Returns: Populated ``AuthInfo`` for a valid token, or `nil` for
    ///   invalid or unrecognized tokens. The SDK checks audience and expiration separately.
    func verifyToken(_ token: String) async -> AuthInfo?
}
