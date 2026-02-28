// Copyright © Anthony DePasquale

#if canImport(Security)
import Foundation
import Security

/// A ``TokenStorage`` implementation backed by the Apple Keychain.
///
/// Stores OAuth tokens and client information securely using the Keychain
/// Services API. Data is JSON-encoded and stored as generic password items.
///
/// This implementation is only available on Apple platforms.
///
/// ## Sharing Between App Extensions
///
/// To share OAuth tokens between your app and its extensions, provide an
/// `accessGroup` that matches a Keychain Access Group in your entitlements:
///
/// ```swift
/// let storage = KeychainTokenStorage(
///     service: "com.myapp.mcp",
///     accessGroup: "TEAMID.com.myapp.shared"
/// )
/// ```
public actor KeychainTokenStorage: TokenStorage {
    private let service: String
    private let accessGroup: String?

    private let tokensAccount = "tokens"
    private let clientInfoAccount = "clientInfo"

    /// Creates a new Keychain-backed token storage.
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier. Defaults to `"com.mcp.oauth"`.
    ///   - accessGroup: Optional Keychain access group for sharing between
    ///     app extensions. Must match an entitlement.
    public init(service: String = "com.mcp.oauth", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func getTokens() async throws -> OAuthTokens? {
        try read(account: tokensAccount)
    }

    public func setTokens(_ tokens: OAuthTokens) async throws {
        try write(tokens, account: tokensAccount)
    }

    public func getClientInfo() async throws -> OAuthClientInformation? {
        try read(account: clientInfoAccount)
    }

    public func setClientInfo(_ info: OAuthClientInformation) async throws {
        try write(info, account: clientInfoAccount)
    }

    public func removeTokens() async throws {
        try delete(account: tokensAccount)
    }

    public func removeClientInfo() async throws {
        try delete(account: clientInfoAccount)
    }

    // MARK: - Keychain Operations

    private func read<T: Decodable>(account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data else {
            return nil
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func write(_ value: some Encodable, account: String) throws {
        let data = try JSONEncoder().encode(value)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try updating the existing item first to avoid a non-atomic
        // delete-then-add sequence.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet; add it.
            var addQuery = baseQuery(account: account)
            addQuery.merge(attributes) { _, new in new }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.writeFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.writeFailed(updateStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainError.writeFailed(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// Errors from Keychain operations.
public enum KeychainError: Error, LocalizedError {
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
            case let .readFailed(status):
                "Failed to read from Keychain (OSStatus \(status))"
            case let .writeFailed(status):
                "Failed to write to Keychain (OSStatus \(status))"
        }
    }
}
#endif
