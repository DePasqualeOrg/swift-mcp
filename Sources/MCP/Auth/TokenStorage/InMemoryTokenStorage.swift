// Copyright © Anthony DePasquale

import Foundation

/// A simple in-memory implementation of ``TokenStorage`` for testing
/// and short-lived processes.
///
/// Data is not persisted across app launches. For production use on
/// Apple platforms, consider implementing a Keychain-backed storage.
///
/// Thread safety is provided by actor isolation.
public actor InMemoryTokenStorage: TokenStorage {
    private var tokens: OAuthTokens?
    private var clientInfo: OAuthClientInformation?

    public init() {}

    public func getTokens() async throws -> OAuthTokens? {
        tokens
    }

    public func setTokens(_ tokens: OAuthTokens) async throws {
        self.tokens = tokens
    }

    public func getClientInfo() async throws -> OAuthClientInformation? {
        clientInfo
    }

    public func setClientInfo(_ info: OAuthClientInformation) async throws {
        clientInfo = info
    }

    public func removeTokens() async throws {
        tokens = nil
    }

    public func removeClientInfo() async throws {
        clientInfo = nil
    }
}
