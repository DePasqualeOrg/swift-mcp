// Copyright © Anthony DePasquale

import Foundation

// MARK: - State Parameter

/// Utilities for generating and verifying OAuth state parameters.
///
/// The state parameter provides CSRF protection during the authorization
/// code flow. It is sent with the authorization request and verified when
/// the callback returns.

/// Generates a cryptographically random state parameter.
///
/// Produces 32 random bytes encoded as a base64url string (no padding),
/// matching the Python SDK's `secrets.token_urlsafe(32)`.
///
/// - Returns: A URL-safe random string
public func generateState() -> String {
    let bytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
    return Data(bytes).base64URLEncodedString()
}

/// Verifies that a returned state parameter matches the expected value
/// using a constant-time comparison to prevent timing side-channel attacks.
///
/// - Parameters:
///   - returned: The state parameter returned from the authorization callback,
///     or `nil` if the callback did not include a state parameter
///   - expected: The state parameter that was sent with the authorization request
/// - Returns: `true` if the state parameters match
public func verifyState(returned: String?, expected: String) -> Bool {
    guard let returned else { return false }
    let returnedBytes = Array(returned.utf8)
    let expectedBytes = Array(expected.utf8)
    guard returnedBytes.count == expectedBytes.count else { return false }
    // XOR all bytes and accumulate differences to avoid short-circuiting
    var result: UInt8 = 0
    for i in returnedBytes.indices {
        result |= returnedBytes[i] ^ expectedBytes[i]
    }
    return result == 0
}
