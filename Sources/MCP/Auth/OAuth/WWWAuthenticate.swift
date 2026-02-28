// Copyright © Anthony DePasquale

import Foundation

// MARK: - WWW-Authenticate Header Parsing

/// A parsed challenge from a `WWW-Authenticate` HTTP response header.
///
/// Used to extract OAuth-related parameters from 401 and 403 responses,
/// including `resource_metadata` (RFC 9728), `scope` (RFC 6750), and
/// `error`/`error_description` fields.
public struct WWWAuthenticateChallenge: Sendable, Equatable {
    /// The authentication scheme (e.g., `"Bearer"`).
    public let scheme: String

    /// The key-value parameters from the challenge.
    public let parameters: [String: String]

    /// The `resource_metadata` URL, if present (RFC 9728 §5.1).
    public var resourceMetadataURL: URL? {
        parameters["resource_metadata"].flatMap(URL.init(string:))
    }

    /// The `scope` parameter, if present (RFC 6750 §3).
    public var scope: String? {
        parameters["scope"]
    }

    /// The `error` parameter, if present (RFC 6750 §3).
    public var error: String? {
        parameters["error"]
    }

    /// The `error_description` parameter, if present (RFC 6750 §3).
    public var errorDescription: String? {
        parameters["error_description"]
    }
}

/// Parses a `WWW-Authenticate` header value into structured challenges.
///
/// Supports multiple challenges in a single header per RFC 9110 §11.6.1,
/// including auth-params (key=value pairs), token68 credentials, and bare
/// schemes. Uses lookahead after each comma to disambiguate commas that
/// separate parameters within a challenge from commas between challenges.
///
/// - Note: The TypeScript and Python MCP SDKs only parse the first challenge.
///   This implementation supports multi-challenge headers so that Bearer
///   parameters are found regardless of their position in the header.
///
/// Handles:
/// - Multiple challenges (e.g., `Basic realm="test", Bearer scope="read"`)
/// - Quoted and unquoted parameter values
/// - Escaped characters within quoted values
/// - Token68 credentials (e.g., `Basic dXNlcjpwYXNz`)
/// - Bare schemes with no parameters (e.g., `Negotiate`)
///
/// - Parameter headerValue: The raw `WWW-Authenticate` header string
/// - Returns: An array of parsed challenges
public func parseWWWAuthenticate(_ headerValue: String) -> [WWWAuthenticateChallenge] {
    var challenges: [WWWAuthenticateChallenge] = []
    var s = headerValue[...]
    skipOWS(&s)

    while !s.isEmpty {
        let scheme = consumeToken(&s)
        guard !scheme.isEmpty else {
            // Skip unexpected characters to avoid infinite loops on malformed input
            s = s.dropFirst()
            skipOWS(&s)
            continue
        }
        skipOWS(&s)

        // Bare scheme (end of string or comma with no parameters)
        if s.isEmpty || s.first == "," {
            if s.first == "," {
                s = s.dropFirst()
                skipOWS(&s)
            }
            challenges.append(.init(scheme: scheme, parameters: [:]))
            continue
        }

        // Determine if what follows is auth-params (key=value) or token68.
        // Auth-params start with `token "=" value`; token68 does not.
        if looksLikeAuthParam(s) {
            let params = consumeAuthParams(&s)
            challenges.append(.init(scheme: scheme, parameters: params))
        } else {
            // Token68: skip the opaque credential value and trailing "=" padding
            consumeToken68(&s)
            skipOWS(&s)
            if s.first == "," {
                s = s.dropFirst()
                skipOWS(&s)
            }
            challenges.append(.init(scheme: scheme, parameters: [:]))
        }
    }

    return challenges
}

/// Extracts the Bearer challenge from a `WWW-Authenticate` header, if present.
///
/// Searches all challenges in the header for one with the `Bearer` scheme
/// (case-insensitive).
///
/// - Parameter headerValue: The raw `WWW-Authenticate` header string
/// - Returns: The first Bearer challenge, or `nil` if none found
public func parseBearerChallenge(_ headerValue: String) -> WWWAuthenticateChallenge? {
    parseWWWAuthenticate(headerValue).first { $0.scheme.lowercased() == "bearer" }
}

// MARK: - Character Classification

/// Whether a character is an RFC 9110 token character (tchar).
///
/// ```
/// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+"
///       / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
/// ```
private func isTokenChar(_ c: Character) -> Bool {
    switch c {
        case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~":
            true
        default:
            c.isASCII && (c.isLetter || c.isNumber)
    }
}

/// Whether a character is an RFC 9110 token68 character.
///
/// Token68 includes `"/"` and `"+"` but not the other tchar punctuation.
/// Trailing `"="` padding is handled separately.
private func isToken68Char(_ c: Character) -> Bool {
    switch c {
        case "-", ".", "_", "~", "+", "/":
            true
        default:
            c.isASCII && (c.isLetter || c.isNumber)
    }
}

/// Whether a character is optional whitespace (OWS: SP or HTAB).
private func isOWS(_ c: Character) -> Bool {
    c == " " || c == "\t"
}

// MARK: - Scanner Primitives

/// Skips optional whitespace (SP / HTAB).
private func skipOWS(_ s: inout Substring) {
    s = s.drop(while: isOWS)
}

/// Consumes a token (sequence of tchar) from the front of the substring.
private func consumeToken(_ s: inout Substring) -> String {
    let token = s.prefix(while: isTokenChar)
    s = s[token.endIndex...]
    return String(token)
}

/// Consumes a token68 value (token68 chars plus trailing `"="` padding).
private func consumeToken68(_ s: inout Substring) {
    s = s.drop(while: isToken68Char)
    s = s.drop(while: { $0 == "=" })
}

/// Consumes a quoted-string per RFC 9110 §5.6.4, handling backslash escapes.
private func consumeQuotedString(_ s: inout Substring) -> String {
    guard s.first == "\"" else { return "" }
    s = s.dropFirst()
    var result: [Character] = []
    var escaped = false
    while let c = s.first {
        s = s.dropFirst()
        if escaped {
            result.append(c)
            escaped = false
        } else if c == "\\" {
            escaped = true
        } else if c == "\"" {
            break
        } else {
            result.append(c)
        }
    }
    return String(result)
}

/// Consumes an unquoted parameter value (until comma, whitespace, or end).
private func consumeUnquotedValue(_ s: inout Substring) -> String {
    let value = s.prefix(while: { !isOWS($0) && $0 != "," })
    s = s[value.endIndex...]
    return String(value)
}

// MARK: - Auth-Param Parsing

/// Non-consuming lookahead: checks whether the substring starts with an
/// auth-param (`token "=" value`) rather than a token68.
///
/// Distinguishes `key=value` from `token68data=` by checking that the
/// character after `"="` is the start of a value (a quote or token char),
/// not another `"="` or end-of-string.
private func looksLikeAuthParam(_ s: Substring) -> Bool {
    var peek = s
    let token = consumeToken(&peek)
    guard !token.isEmpty else { return false }
    skipOWS(&peek)
    guard peek.first == "=" else { return false }
    peek = peek.dropFirst()
    skipOWS(&peek)
    guard let next = peek.first else { return false }
    return next == "\"" || isTokenChar(next)
}

/// Consumes auth-params (comma-separated key=value pairs), using lookahead
/// after each comma to determine whether the next token is another parameter
/// of the current challenge or the scheme of a new challenge.
private func consumeAuthParams(_ s: inout Substring) -> [String: String] {
    var params: [String: String] = [:]

    while !s.isEmpty {
        skipOWS(&s)

        let key = consumeToken(&s)
        guard !key.isEmpty else { break }
        skipOWS(&s)

        guard s.first == "=" else { break }
        s = s.dropFirst()
        skipOWS(&s)

        let value: String = if s.first == "\"" {
            consumeQuotedString(&s)
        } else {
            consumeUnquotedValue(&s)
        }
        params[key.lowercased()] = value

        skipOWS(&s)

        // After a parameter, a comma can separate either the next parameter
        // or the next challenge. Peek ahead to decide.
        guard s.first == "," else { break }
        s = s.dropFirst()
        skipOWS(&s)

        if !looksLikeAuthParam(s) {
            break
        }
    }

    return params
}
