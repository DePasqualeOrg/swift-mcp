// Copyright © Anthony DePasquale

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

import Foundation

// MARK: - PKCE

/// PKCE (Proof Key for Code Exchange) support for OAuth 2.0 (RFC 7636).
///
/// The MCP specification requires all authorization code flows to use PKCE with S256.
/// Clients must verify that the authorization server supports S256 before proceeding.
///
/// - SeeAlso: [RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636)
public enum PKCE {
    /// A PKCE code verifier and its corresponding S256 challenge.
    public struct Challenge: Sendable {
        /// The code verifier to include in the token exchange request.
        public let verifier: String

        /// The S256 code challenge to include in the authorization request.
        public let challenge: String

        /// The challenge method, always `"S256"`.
        public let method: String = "S256"

        /// Generates a new PKCE challenge pair.
        ///
        /// Creates a cryptographically random code verifier and computes its S256 challenge.
        public static func generate() -> Challenge {
            let verifier = generateCodeVerifier()
            let challenge = computeCodeChallenge(verifier: verifier)
            return Challenge(verifier: verifier, challenge: challenge)
        }
    }

    /// Characters allowed in a PKCE code verifier (RFC 7636 §4.1).
    private static let unreservedCharacters = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    /// Generates a cryptographically random code verifier.
    ///
    /// The verifier is 128 characters from the unreserved character set,
    /// selected using rejection sampling to avoid modulo bias.
    ///
    /// - Returns: A code verifier string suitable for PKCE
    static func generateCodeVerifier() -> String {
        let charCount = UInt8(unreservedCharacters.count) // 66
        // Largest multiple of charCount that fits in a UInt8. Bytes at or above
        // this threshold are discarded to eliminate modulo bias.
        let limit = 256 - (256 % Int(charCount)) // 252

        var result = [Character]()
        result.reserveCapacity(128)

        while result.count < 128 {
            // Generate a batch of random bytes. On average, 252/256 of bytes are
            // usable, so a batch of 140 almost always fills the remaining slots.
            let batchSize = max(140, 128 - result.count + 12)
            let randomBytes = (0 ..< batchSize).map { _ in UInt8.random(in: 0 ... 255) }

            for byte in randomBytes where result.count < 128 {
                guard byte < limit else { continue } // rejection sampling
                result.append(Character(UnicodeScalar(unreservedCharacters[Int(byte) % Int(charCount)])))
            }
        }

        return String(result)
    }

    /// Computes the S256 code challenge for a given verifier.
    ///
    /// The challenge is `BASE64URL(SHA256(ASCII(code_verifier)))` with no padding,
    /// as specified in RFC 7636 §4.2.
    ///
    /// - Parameter verifier: The code verifier string
    /// - Returns: The base64url-encoded SHA-256 hash of the verifier
    static func computeCodeChallenge(verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

    /// Checks whether the authorization server supports PKCE with S256.
    ///
    /// Per the MCP specification (2025-11-25), clients must verify that
    /// `code_challenge_methods_supported` includes `"S256"` before proceeding
    /// with the authorization flow. If the field is absent, the server does not
    /// advertise PKCE support and clients must refuse to proceed.
    ///
    /// - Note: The TypeScript and Python SDKs treat an absent field as "assume
    ///   supported." This implementation follows the spec, which requires the
    ///   field to be present and to include `"S256"`.
    ///
    /// - Parameter metadata: The authorization server metadata
    /// - Returns: `true` if `code_challenge_methods_supported` is present and includes `"S256"`
    public static func isSupported(by metadata: OAuthMetadata) -> Bool {
        guard let methods = metadata.codeChallengeMethodsSupported else {
            return false
        }
        return methods.contains("S256")
    }
}

// MARK: - Base64URL Encoding

extension Data {
    /// Encodes data as a base64url string without padding, per RFC 4648 §5.
    /// Used by PKCE and available for future JWT token handling.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
