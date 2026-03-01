// Copyright © Anthony DePasquale

import Foundation

/// Protocol for persisting OAuth tokens and client registration information.
///
/// Tokens and client information are stored separately because they have
/// different lifetimes and sensitivity levels:
/// - Tokens are short-lived and frequently updated (on every refresh)
/// - Client info is longer-lived and shared across refreshes
///
/// ## Provided Implementations
///
/// - ``InMemoryTokenStorage``: Simple in-memory storage for testing
///
/// ## Custom Implementations
///
/// Implement this protocol to persist OAuth state across app launches.
/// For example, a Keychain-backed implementation for Apple platforms:
///
/// ```swift
/// actor KeychainTokenStorage: TokenStorage {
///     func getTokens() async throws -> OAuthTokens? {
///         // Read from Keychain
///     }
///     func setTokens(_ tokens: OAuthTokens) async throws {
///         // Write to Keychain
///     }
///     // ...
/// }
/// ```
public protocol TokenStorage: Sendable {
    /// Retrieves stored OAuth tokens.
    ///
    /// - Returns: The stored tokens, or `nil` if none are stored
    func getTokens() async throws -> OAuthTokens?

    /// Stores OAuth tokens, replacing any previously stored tokens.
    ///
    /// - Parameter tokens: The tokens to store
    func setTokens(_ tokens: OAuthTokens) async throws

    /// Retrieves stored client registration information.
    ///
    /// - Returns: The stored client info, or `nil` if none is stored
    func getClientInfo() async throws -> OAuthClientInformation?

    /// Stores client registration information, replacing any previously stored info.
    ///
    /// - Parameter info: The client information to store
    func setClientInfo(_ info: OAuthClientInformation) async throws

    /// Removes stored tokens.
    ///
    /// Called when tokens are invalidated (e.g., after an `invalid_grant` error).
    /// The default implementation does nothing, which is safe but may leave
    /// stale tokens in persistent storage until the next successful auth flow.
    func removeTokens() async throws

    /// Removes stored client registration information.
    ///
    /// Called when client credentials are invalidated (e.g., after an
    /// `invalid_client` error). The default implementation does nothing.
    func removeClientInfo() async throws
}

public extension TokenStorage {
    func removeTokens() async throws {}
    func removeClientInfo() async throws {}
}
