// Copyright © Anthony DePasquale

#if swift(>=6.1)

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MCP
import Testing

// MARK: - Test Helpers

/// Actor-based counter for use in async `HTTPRequestHandler` closures.
private actor OAuthCallCounter {
    var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// Lock-based counter for use in synchronous `@Sendable` closures (e.g., `MockURLProtocol` handler).
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

// MARK: - PKCE Tests

struct PKCETests {
    @Test
    func `Code verifier has correct length and character set`() {
        let verifier = PKCE.generateCodeVerifier()

        // RFC 7636 §4.1: verifier is 43-128 characters from unreserved set
        #expect(verifier.count == 128)

        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
        )
        for scalar in verifier.unicodeScalars {
            #expect(allowedCharacters.contains(scalar), "Invalid character in verifier: \(scalar)")
        }
    }

    @Test
    func `Two verifiers are different (randomness check)`() {
        let v1 = PKCE.generateCodeVerifier()
        let v2 = PKCE.generateCodeVerifier()
        #expect(v1 != v2)
    }

    @Test
    func `S256 challenge matches known vector`() {
        // RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.computeCodeChallenge(verifier: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func `Challenge has no base64 padding`() {
        let challenge = PKCE.Challenge.generate()
        #expect(!challenge.challenge.contains("="))
        #expect(!challenge.challenge.contains("+"))
        #expect(!challenge.challenge.contains("/"))
    }

    @Test
    func `Challenge method is always S256`() {
        let challenge = PKCE.Challenge.generate()
        #expect(challenge.method == "S256")
    }

    @Test
    func `Server support check: S256 present`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            codeChallengeMethodsSupported: ["S256"],
        )
        #expect(PKCE.isSupported(by: metadata))
    }

    @Test
    func `Server support check: S256 absent`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            codeChallengeMethodsSupported: ["plain"],
        )
        #expect(!PKCE.isSupported(by: metadata))
    }

    @Test
    func `Server support check: field absent means not supported (per MCP spec 2025-11-25)`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            codeChallengeMethodsSupported: nil,
        )
        #expect(!PKCE.isSupported(by: metadata))
    }
}

// MARK: - WWW-Authenticate Parsing Tests

struct WWWAuthenticateTests {
    @Test
    func `Parse Bearer with resource_metadata and scope`() {
        let header =
            #"Bearer resource_metadata="https://api.example.com/.well-known/oauth-protected-resource", scope="read write""#

        let challenges = parseWWWAuthenticate(header)
        #expect(challenges.count == 1)

        let challenge = challenges[0]
        #expect(challenge.scheme == "Bearer")
        #expect(
            challenge.resourceMetadataURL
                == URL(
                    string: "https://api.example.com/.well-known/oauth-protected-resource",
                ),
        )
        #expect(challenge.scope == "read write")
    }

    @Test
    func `Parse Bearer with error fields`() {
        let header =
            #"Bearer error="insufficient_scope", scope="admin", error_description="Need admin access""#

        let challenge = parseBearerChallenge(header)
        #expect(challenge != nil)
        #expect(challenge?.error == "insufficient_scope")
        #expect(challenge?.scope == "admin")
        #expect(challenge?.errorDescription == "Need admin access")
    }

    @Test
    func `Parse Bearer with unquoted values`() {
        let header = "Bearer realm=example, scope=read"

        let challenge = parseBearerChallenge(header)
        #expect(challenge != nil)
        #expect(challenge?.parameters["realm"] == "example")
        #expect(challenge?.scope == "read")
    }

    @Test
    func `Parse empty header returns empty array`() {
        let challenges = parseWWWAuthenticate("")
        #expect(challenges.isEmpty)
    }

    @Test
    func `Parse header with only scheme, no params`() {
        let challenges = parseWWWAuthenticate("Basic")
        #expect(challenges.count == 1)
        #expect(challenges[0].scheme == "Basic")
        #expect(challenges[0].parameters.isEmpty)
    }

    @Test
    func `parseBearerChallenge returns nil for non-Bearer`() {
        let challenge = parseBearerChallenge("Basic realm=test")
        #expect(challenge == nil)
    }

    @Test
    func `Quoted values with escaped characters`() {
        let header = #"Bearer error_description="token is \"expired\"""#

        let challenge = parseBearerChallenge(header)
        #expect(challenge?.errorDescription == #"token is "expired""#)
    }

    // MARK: - Multi-Challenge Parsing

    @Test
    func `Bearer as second challenge is found by parseBearerChallenge`() {
        let header =
            #"Basic realm="My Server", Bearer error="invalid_token", scope="read""#

        let challenges = parseWWWAuthenticate(header)
        #expect(challenges.count == 2)
        #expect(challenges[0].scheme == "Basic")
        #expect(challenges[0].parameters["realm"] == "My Server")
        #expect(challenges[1].scheme == "Bearer")
        #expect(challenges[1].error == "invalid_token")
        #expect(challenges[1].scope == "read")

        // parseBearerChallenge finds it regardless of position
        let bearer = parseBearerChallenge(header)
        #expect(bearer != nil)
        #expect(bearer?.error == "invalid_token")
    }

    @Test
    func `Two bare schemes`() {
        let challenges = parseWWWAuthenticate("Negotiate, Basic")
        #expect(challenges.count == 2)
        #expect(challenges[0].scheme == "Negotiate")
        #expect(challenges[0].parameters.isEmpty)
        #expect(challenges[1].scheme == "Basic")
        #expect(challenges[1].parameters.isEmpty)
    }

    @Test
    func `Three challenges with mixed formats`() {
        let header =
            #"Negotiate, Basic realm="test", Bearer scope="admin""#

        let challenges = parseWWWAuthenticate(header)
        #expect(challenges.count == 3)
        #expect(challenges[0].scheme == "Negotiate")
        #expect(challenges[0].parameters.isEmpty)
        #expect(challenges[1].scheme == "Basic")
        #expect(challenges[1].parameters["realm"] == "test")
        #expect(challenges[2].scheme == "Bearer")
        #expect(challenges[2].scope == "admin")
    }

    @Test
    func `Token68 credential followed by Bearer challenge`() {
        let header = #"Basic dXNlcjpwYXNz, Bearer scope="read""#

        let challenges = parseWWWAuthenticate(header)
        #expect(challenges.count == 2)
        #expect(challenges[0].scheme == "Basic")
        #expect(challenges[0].parameters.isEmpty)
        #expect(challenges[1].scheme == "Bearer")
        #expect(challenges[1].scope == "read")
    }

    @Test
    func `Token68 with base64 padding`() {
        let header = #"Basic dXNlcjpwYXNz==, Bearer scope="read""#

        let challenges = parseWWWAuthenticate(header)
        #expect(challenges.count == 2)
        #expect(challenges[0].scheme == "Basic")
        #expect(challenges[1].scheme == "Bearer")
        #expect(challenges[1].scope == "read")
    }

    @Test
    func `Bearer with resource_metadata as second challenge`() {
        let header =
            #"Basic, Bearer resource_metadata="https://api.example.com/.well-known/oauth-protected-resource""#

        let bearer = parseBearerChallenge(header)
        #expect(bearer != nil)
        #expect(
            bearer?.resourceMetadataURL
                == URL(string: "https://api.example.com/.well-known/oauth-protected-resource"),
        )
    }
}

// MARK: - Resource URL Tests

struct ResourceURLTests {
    @Test
    func `Canonicalize lowercases scheme and host`() throws {
        let url = try #require(URL(string: "HTTPS://API.Example.COM/mcp"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `Canonicalize removes fragment`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp#section"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `Canonicalize preserves path and query`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp/v1?key=value"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "https://api.example.com/mcp/v1?key=value")
    }

    @Test
    func `Canonicalize removes default HTTPS port`() throws {
        let url = try #require(URL(string: "https://api.example.com:443/mcp"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `Canonicalize removes default HTTP port`() throws {
        let url = try #require(URL(string: "http://api.example.com:80/mcp"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "http://api.example.com/mcp")
    }

    @Test
    func `Canonicalize preserves non-default port`() throws {
        let url = try #require(URL(string: "https://api.example.com:8443/mcp"))
        let canonical = ResourceURL.canonicalize(url)
        #expect(canonical?.absoluteString == "https://api.example.com:8443/mcp")
    }

    @Test
    func `Matching: same origin with path prefix`() throws {
        let requested = try #require(URL(string: "https://api.example.com/mcp/v1/tools"))
        let configured = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: exact match`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(ResourceURL.matches(requested: url, configured: url))
    }

    @Test
    func `Matching: different path`() throws {
        let requested = try #require(URL(string: "https://api.example.com/other"))
        let configured = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(!ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: different host`() throws {
        let requested = try #require(URL(string: "https://evil.example.com/mcp"))
        let configured = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(!ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: different scheme`() throws {
        let requested = try #require(URL(string: "http://api.example.com/mcp"))
        let configured = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(!ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: different port`() throws {
        let requested = try #require(URL(string: "https://api.example.com:9443/mcp"))
        let configured = try #require(URL(string: "https://api.example.com:8443/mcp"))
        #expect(!ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: case-insensitive scheme and host`() throws {
        let requested = try #require(URL(string: "HTTPS://API.Example.COM/mcp"))
        let configured = try #require(URL(string: "https://api.example.com/mcp"))
        #expect(ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: path prefix must be at segment boundary`() throws {
        // "/api" should NOT match "/api-evil" – only "/api/" and "/api/..." should match
        let requested = try #require(URL(string: "https://api.example.com/api-evil"))
        let configured = try #require(URL(string: "https://api.example.com/api"))
        #expect(!ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: path prefix at segment boundary succeeds`() throws {
        let requested = try #require(URL(string: "https://api.example.com/api/v1"))
        let configured = try #require(URL(string: "https://api.example.com/api"))
        #expect(ResourceURL.matches(requested: requested, configured: configured))
    }

    @Test
    func `Matching: root configured matches all paths`() throws {
        let requested = try #require(URL(string: "https://api.example.com/anything/at/all"))
        let configured = try #require(URL(string: "https://api.example.com"))
        #expect(ResourceURL.matches(requested: requested, configured: configured))
    }
}

// MARK: - Metadata Discovery URL Tests

struct MetadataDiscoveryURLTests {
    @Test
    func `PRM URLs: server with path`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com/mcp/v1"))
        let urls = buildProtectedResourceMetadataDiscoveryURLs(serverURL: serverURL)

        #expect(urls.count == 2)
        #expect(
            urls[0].absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp/v1",
        )
        #expect(
            urls[1].absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource",
        )
    }

    @Test
    func `PRM URLs: server without path`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com"))
        let urls = buildProtectedResourceMetadataDiscoveryURLs(serverURL: serverURL)

        #expect(urls.count == 1)
        #expect(
            urls[0].absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource",
        )
    }

    @Test
    func `PRM URLs: WWW-Authenticate URL takes priority`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com/mcp"))
        let wwwAuthURL = try #require(URL(string: "https://custom.example.com/.well-known/prm"))
        let urls = buildProtectedResourceMetadataDiscoveryURLs(
            serverURL: serverURL, wwwAuthenticateURL: wwwAuthURL,
        )

        #expect(urls.count == 3)
        #expect(urls[0].absoluteString == "https://custom.example.com/.well-known/prm")
        #expect(
            urls[1].absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp",
        )
        #expect(
            urls[2].absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource",
        )
    }

    @Test
    func `AS URLs: auth server with path`() throws {
        let authURL = try #require(URL(string: "https://auth.example.com/tenant1"))
        let urls = buildAuthorizationServerMetadataDiscoveryURLs(authServerURL: authURL)

        #expect(urls.count == 3)
        #expect(
            urls[0].absoluteString
                == "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        )
        #expect(
            urls[1].absoluteString
                == "https://auth.example.com/.well-known/openid-configuration/tenant1",
        )
        #expect(
            urls[2].absoluteString
                == "https://auth.example.com/tenant1/.well-known/openid-configuration",
        )
    }

    @Test
    func `AS URLs: auth server without path`() throws {
        let authURL = try #require(URL(string: "https://auth.example.com"))
        let urls = buildAuthorizationServerMetadataDiscoveryURLs(authServerURL: authURL)

        #expect(urls.count == 2)
        #expect(
            urls[0].absoluteString
                == "https://auth.example.com/.well-known/oauth-authorization-server",
        )
        #expect(
            urls[1].absoluteString == "https://auth.example.com/.well-known/openid-configuration",
        )
    }

    @Test
    func `AS URLs: path with trailing slash is stripped`() throws {
        let authURL = try #require(URL(string: "https://auth.example.com/tenant1/"))
        let urls = buildAuthorizationServerMetadataDiscoveryURLs(authServerURL: authURL)

        #expect(urls.count == 3)
        #expect(
            urls[0].absoluteString
                == "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        )
        #expect(
            urls[1].absoluteString
                == "https://auth.example.com/.well-known/openid-configuration/tenant1",
        )
        #expect(
            urls[2].absoluteString
                == "https://auth.example.com/tenant1/.well-known/openid-configuration",
        )
    }
}

// MARK: - Client Authentication Tests

struct ClientAuthenticationTests {
    @Test
    func `Basic auth encoding`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body = ["grant_type": "authorization_code"]

        try applyClientAuthentication(
            to: &request,
            body: &body,
            clientId: "my-client",
            clientSecret: "my-secret",
            method: .clientSecretBasic,
        )

        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader != nil)
        #expect(try #require(authHeader?.hasPrefix("Basic ")))

        // Decode and verify
        let base64Part = try String(#require(authHeader?.dropFirst("Basic ".count)))
        let decodedData = try #require(Data(base64Encoded: base64Part))
        let decoded = try #require(String(data: decodedData, encoding: .utf8))
        #expect(decoded == "my-client:my-secret")

        // Body should not contain client credentials
        #expect(body["client_id"] == nil)
        #expect(body["client_secret"] == nil)
    }

    @Test
    func `Basic auth URL-encodes special characters per RFC 6749 §2.3.1`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body: [String: String] = [:]

        try applyClientAuthentication(
            to: &request,
            body: &body,
            clientId: "client@host:8080",
            clientSecret: "secret/path+value",
            method: .clientSecretBasic,
        )

        let authHeader = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let base64Part = String(authHeader.dropFirst("Basic ".count))
        let decodedData = try #require(Data(base64Encoded: base64Part))
        let decoded = try #require(String(data: decodedData, encoding: .utf8))
        // @, :, /, and + must be percent-encoded (only unreserved chars are allowed)
        #expect(decoded == "client%40host%3A8080:secret%2Fpath%2Bvalue")
    }

    @Test
    func `Post auth adds credentials to body`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body = ["grant_type": "authorization_code"]

        try applyClientAuthentication(
            to: &request,
            body: &body,
            clientId: "my-client",
            clientSecret: "my-secret",
            method: .clientSecretPost,
        )

        #expect(body["client_id"] == "my-client")
        #expect(body["client_secret"] == "my-secret")
        // Should not set Authorization header
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `None auth adds only client_id to body`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body = ["grant_type": "authorization_code"]

        try applyClientAuthentication(
            to: &request,
            body: &body,
            clientId: "my-client",
            clientSecret: nil,
            method: .none,
        )

        #expect(body["client_id"] == "my-client")
        #expect(body["client_secret"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `Method selection: client preferred and server supported`() {
        let method = selectClientAuthenticationMethod(
            serverSupported: ["none", "client_secret_basic", "client_secret_post"],
            clientPreferred: "client_secret_post",
        )
        #expect(method == .clientSecretPost)
    }

    @Test
    func `Method selection: client preference not supported by server`() {
        let method = selectClientAuthenticationMethod(
            serverSupported: ["client_secret_basic"],
            clientPreferred: "none",
        )
        // Falls back to first supported method we implement
        #expect(method == .clientSecretBasic)
    }

    @Test
    func `Method selection: nil server defaults to client_secret_basic per RFC 8414`() {
        let method = selectClientAuthenticationMethod(
            serverSupported: nil,
            clientPreferred: nil,
        )
        #expect(method == .clientSecretBasic)
    }

    @Test
    func `Method selection: public client prefers none`() {
        let method = selectClientAuthenticationMethod(
            serverSupported: ["none", "client_secret_basic", "client_secret_post"],
            clientPreferred: nil,
            hasClientSecret: false,
        )
        #expect(method == .none)
    }

    @Test
    func `Method selection: confidential client prefers client_secret_basic`() {
        let method = selectClientAuthenticationMethod(
            serverSupported: ["none", "client_secret_basic", "client_secret_post"],
            clientPreferred: nil,
            hasClientSecret: true,
        )
        #expect(method == .clientSecretBasic)
    }

    @Test
    func `Form URL encoded body`() throws {
        let body = formURLEncodedBody(["grant_type": "refresh_token", "refresh_token": "abc123"])
        let string = try #require(String(data: body, encoding: .utf8))

        #expect(string.contains("grant_type=refresh_token"))
        #expect(string.contains("refresh_token=abc123"))
        #expect(string.contains("&"))
    }

    @Test
    func `Form URL encoded body has deterministic key ordering`() throws {
        let body = formURLEncodedBody([
            "z_param": "last",
            "a_param": "first",
            "m_param": "middle",
        ])
        let string = try #require(String(data: body, encoding: .utf8))
        #expect(string == "a_param=first&m_param=middle&z_param=last")
    }

    @Test
    func `Form URL encoded body encodes special characters`() throws {
        let body = formURLEncodedBody(["redirect_uri": "https://example.com/callback?foo=bar&baz=1"])
        let string = try #require(String(data: body, encoding: .utf8))
        // & and = in the value must be percent-encoded
        #expect(!string.contains("foo=bar"))
        #expect(string.contains("redirect_uri="))
        #expect(string.contains("%26"))
        #expect(string.contains("%3D"))
    }

    @Test
    func `Basic auth with nil secret throws error`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body = ["grant_type": "authorization_code"]

        #expect(throws: OAuthError.self) {
            try applyClientAuthentication(
                to: &request,
                body: &body,
                clientId: "my-client",
                clientSecret: nil,
                method: .clientSecretBasic,
            )
        }
    }

    @Test
    func `Post auth with nil secret throws error`() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com/token")))
        var body = ["grant_type": "authorization_code"]

        #expect(throws: OAuthError.self) {
            try applyClientAuthentication(
                to: &request,
                body: &body,
                clientId: "my-client",
                clientSecret: nil,
                method: .clientSecretPost,
            )
        }
    }
}

// MARK: - OAuth Types Codable Tests

struct OAuthTypesTests {
    @Test
    func `OAuthMetadata decodes from JSON with snake_case keys`() throws {
        let json = """
        {
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
            "registration_endpoint": "https://auth.example.com/register",
            "code_challenge_methods_supported": ["S256"],
            "scopes_supported": ["read", "write"],
            "response_types_supported": ["code"],
            "token_endpoint_auth_methods_supported": ["none", "client_secret_basic"],
            "client_id_metadata_document_supported": true
        }
        """

        let metadata = try JSONDecoder().decode(
            OAuthMetadata.self, from: Data(json.utf8),
        )

        #expect(metadata.issuer.absoluteString == "https://auth.example.com")
        #expect(
            metadata.authorizationEndpoint.absoluteString
                == "https://auth.example.com/authorize",
        )
        #expect(metadata.tokenEndpoint.absoluteString == "https://auth.example.com/token")
        #expect(metadata.registrationEndpoint?.absoluteString == "https://auth.example.com/register")
        #expect(metadata.codeChallengeMethodsSupported == ["S256"])
        #expect(metadata.scopesSupported == ["read", "write"])
        #expect(metadata.clientIdMetadataDocumentSupported == true)
    }

    @Test
    func `OAuthMetadata encodes to JSON with snake_case keys`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            codeChallengeMethodsSupported: ["S256"],
        )

        let data = try JSONEncoder().encode(metadata)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["issuer"] as? String == "https://auth.example.com")
        #expect(json["authorization_endpoint"] as? String == "https://auth.example.com/authorize")
        #expect(json["code_challenge_methods_supported"] as? [String] == ["S256"])
    }

    @Test
    func `ProtectedResourceMetadata round-trips`() throws {
        let json = """
        {
            "resource": "https://api.example.com/mcp",
            "authorization_servers": ["https://auth.example.com"],
            "scopes_supported": ["mcp:read", "mcp:write"],
            "bearer_methods_supported": ["header"],
            "resource_name": "My MCP Server"
        }
        """

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: Data(json.utf8),
        )

        #expect(metadata.resource.absoluteString == "https://api.example.com/mcp")
        #expect(metadata.authorizationServers?.count == 1)
        #expect(
            metadata.authorizationServers?[0].absoluteString == "https://auth.example.com",
        )
        #expect(metadata.scopesSupported == ["mcp:read", "mcp:write"])
        #expect(metadata.resourceName == "My MCP Server")
    }

    @Test
    func `OAuthClientInformation decodes from registration response`() throws {
        let json = """
        {
            "client_id": "abc123",
            "client_secret": "secret456",
            "client_id_issued_at": 1700000000,
            "client_secret_expires_at": 0
        }
        """

        let info = try JSONDecoder().decode(
            OAuthClientInformation.self, from: Data(json.utf8),
        )

        #expect(info.clientId == "abc123")
        #expect(info.clientSecret == "secret456")
        #expect(info.clientIdIssuedAt == 1_700_000_000)
        #expect(info.clientSecretExpiresAt == 0)
    }

    @Test
    func `OAuthTokens decodes id_token field`() throws {
        let json = """
        {
            "access_token": "at_123",
            "token_type": "Bearer",
            "id_token": "eyJhbGciOiJSUzI1NiJ9.payload.signature"
        }
        """

        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        #expect(tokens.idToken == "eyJhbGciOiJSUzI1NiJ9.payload.signature")
    }

    @Test
    func `ProtectedResourceMetadata decodes without authorization_servers`() throws {
        let json = """
        {
            "resource": "https://api.example.com/mcp"
        }
        """

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: Data(json.utf8),
        )
        #expect(metadata.resource.absoluteString == "https://api.example.com/mcp")
        #expect(metadata.authorizationServers == nil)
    }

    @Test
    func `OAuthTokens uses snake_case coding keys`() throws {
        let json = """
        {
            "access_token": "at_123",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "rt_456",
            "scope": "read write"
        }
        """

        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))

        #expect(tokens.accessToken == "at_123")
        #expect(tokens.tokenType == "Bearer")
        #expect(tokens.expiresIn == 3600)
        #expect(tokens.refreshToken == "rt_456")
        #expect(tokens.scope == "read write")
    }

    @Test
    func `OAuthTokenErrorResponse decodes`() throws {
        let json = """
        {
            "error": "invalid_grant",
            "error_description": "The refresh token has expired"
        }
        """

        let errorResponse = try JSONDecoder().decode(
            OAuthTokenErrorResponse.self, from: Data(json.utf8),
        )

        #expect(errorResponse.error == "invalid_grant")
        #expect(errorResponse.errorDescription == "The refresh token has expired")
    }
}

// MARK: - OAuth Error Tests

struct OAuthErrorTests {
    @Test
    func `Error created from token error response`() {
        let response = OAuthTokenErrorResponse(
            error: "invalid_grant",
            errorDescription: "Token expired",
        )
        let error = OAuthError(from: response)
        #expect(error == .invalidGrant("Token expired"))
    }

    @Test
    func `Unknown error code maps to unrecognizedError`() {
        let response = OAuthTokenErrorResponse(
            error: "custom_error",
            errorDescription: "Something went wrong",
        )
        let error = OAuthError(from: response)
        if case let .unrecognizedError(code, description) = error {
            #expect(code == "custom_error")
            #expect(description == "Something went wrong")
        } else {
            Issue.record("Expected unrecognizedError, got \(error)")
        }
    }

    @Test
    func `All standard error codes are mapped`() {
        let codes = [
            "invalid_request", "invalid_client", "invalid_grant", "unauthorized_client",
            "unsupported_grant_type", "invalid_scope", "access_denied", "server_error",
            "temporarily_unavailable", "unsupported_response_type", "invalid_token",
            "insufficient_scope", "unsupported_token_type", "invalid_target",
            "invalid_client_metadata",
        ]

        for code in codes {
            let response = OAuthTokenErrorResponse(error: code)
            let error = OAuthError(from: response)
            // Verify it doesn't fall through to the default case (which adds "Unknown error:")
            #expect(!error.localizedDescription.contains("Unknown error:"))
        }
    }

    @Test
    func `Errors have localized descriptions`() {
        let errors: [OAuthError] = [
            .invalidClient(nil),
            .discoveryFailed("all URLs failed"),
            .pkceNotSupported,
            .tokenRefreshFailed("timeout"),
        ]

        for error in errors {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}

// MARK: - Token Refresh Tests

struct TokenRefreshTests {
    @Test
    func `Successful refresh returns new tokens`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            // Verify the request
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://auth.example.com/token")

            let bodyString = String(data: request.httpBody!, encoding: .utf8)!
            #expect(bodyString.contains("grant_type=refresh_token"))
            #expect(bodyString.contains("refresh_token=rt_old"))

            let responseJSON = """
            {
                "access_token": "at_new",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "rt_new"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(responseJSON.utf8), response)
        }

        let tokens = try await refreshAccessToken(
            refreshToken: "rt_old",
            clientId: "client1",
            clientSecret: nil,
            clientAuthMethod: .none,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: mockHTTPClient,
        )

        #expect(tokens.accessToken == "at_new")
        #expect(tokens.refreshToken == "rt_new")
        #expect(tokens.expiresIn == 3600)
    }

    @Test
    func `Refresh with resource parameter`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            let bodyString = String(data: request.httpBody!, encoding: .utf8)!
            #expect(bodyString.contains("resource=https"))

            let responseJSON = """
            {"access_token": "at_new", "token_type": "Bearer"}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(responseJSON.utf8), response)
        }

        let tokens = try await refreshAccessToken(
            refreshToken: "rt_old",
            clientId: "client1",
            clientSecret: nil,
            clientAuthMethod: .none,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: mockHTTPClient,
        )

        #expect(tokens.accessToken == "at_new")
    }

    @Test
    func `Refresh failure throws OAuthError`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            let responseJSON = """
            {"error": "invalid_grant", "error_description": "Refresh token expired"}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(responseJSON.utf8), response)
        }

        await #expect(throws: OAuthError.self) {
            try await refreshAccessToken(
                refreshToken: "rt_expired",
                clientId: "client1",
                clientSecret: nil,
                clientAuthMethod: .none,
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: mockHTTPClient,
            )
        }
    }

    @Test
    func `Refresh preserves original refresh token when server omits it`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            // Server returns new access token but no refresh token
            let responseJSON = """
            {
                "access_token": "at_new",
                "token_type": "Bearer"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(responseJSON.utf8), response)
        }

        let tokens = try await refreshAccessToken(
            refreshToken: "rt_original",
            clientId: "client1",
            clientSecret: nil,
            clientAuthMethod: .none,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: mockHTTPClient,
        )

        #expect(tokens.accessToken == "at_new")
        #expect(tokens.refreshToken == "rt_original")
    }

    @Test
    func `Refresh with unparseable success response throws tokenRefreshFailed`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data("not json".utf8), response)
        }

        await #expect(throws: OAuthError.self) {
            try await refreshAccessToken(
                refreshToken: "rt_old",
                clientId: "client1",
                clientSecret: nil,
                clientAuthMethod: .none,
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: mockHTTPClient,
            )
        }
    }

    @Test
    func `Refresh applies client_secret_basic auth`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            // Verify Basic auth header is present
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader != nil)
            #expect(authHeader!.hasPrefix("Basic "))

            let responseJSON = """
            {"access_token": "at_new", "token_type": "Bearer"}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(responseJSON.utf8), response)
        }

        let tokens = try await refreshAccessToken(
            refreshToken: "rt_old",
            clientId: "client1",
            clientSecret: "secret1",
            clientAuthMethod: .clientSecretBasic,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: mockHTTPClient,
        )

        #expect(tokens.accessToken == "at_new")
    }
}

// MARK: - Metadata Discovery Integration Tests

struct MetadataDiscoveryTests {
    @Test
    func `PRM discovery succeeds on first URL`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            if request.url!.absoluteString.contains("well-known/oauth-protected-resource") {
                let json = """
                {
                    "resource": "https://api.example.com",
                    "authorization_servers": ["https://auth.example.com"]
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil,
                )!
                return (Data(json.utf8), response)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(), response)
        }

        let metadata = try await discoverProtectedResourceMetadata(
            serverURL: #require(URL(string: "https://api.example.com")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata != nil)
        #expect(metadata?.resource.absoluteString == "https://api.example.com")
        #expect(metadata?.authorizationServers?.first?.absoluteString == "https://auth.example.com")
    }

    @Test
    func `PRM discovery falls back to root`() async throws {
        let counter = OAuthCallCounter()
        let mockHTTPClient: HTTPRequestHandler = { request in
            let count = await counter.increment()
            // First URL (path-based) returns 404, second URL (root) succeeds
            if count == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil,
                )!
                return (Data(), response)
            }
            let json = """
            {
                "resource": "https://api.example.com",
                "authorization_servers": ["https://auth.example.com"]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(json.utf8), response)
        }

        let metadata = try await discoverProtectedResourceMetadata(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata != nil)
        let finalCount = await counter.value
        #expect(finalCount == 2)
    }

    @Test
    func `PRM discovery stops on 5xx error`() async throws {
        let counter = OAuthCallCounter()
        let mockHTTPClient: HTTPRequestHandler = { request in
            await counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(), response)
        }

        let metadata = try await discoverProtectedResourceMetadata(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata == nil)
        // Should stop after first 5xx, not try root fallback
        let finalCount = await counter.value
        #expect(finalCount == 1)
    }

    @Test
    func `PRM discovery returns nil when all URLs fail`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(), response)
        }

        let metadata = try await discoverProtectedResourceMetadata(
            serverURL: #require(URL(string: "https://api.example.com")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata == nil)
    }

    @Test
    func `AS metadata discovery succeeds`() async throws {
        let mockHTTPClient: HTTPRequestHandler = { request in
            let json = """
            {
                "issuer": "https://auth.example.com",
                "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token",
                "code_challenge_methods_supported": ["S256"]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(json.utf8), response)
        }

        let metadata = try await discoverAuthorizationServerMetadata(
            authServerURL: #require(URL(string: "https://auth.example.com")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata != nil)
        #expect(metadata?.issuer.absoluteString == "https://auth.example.com")
        #expect(metadata?.codeChallengeMethodsSupported == ["S256"])
    }

    @Test
    func `AS discovery falls back to OIDC`() async throws {
        let counter = OAuthCallCounter()
        let mockHTTPClient: HTTPRequestHandler = { request in
            await counter.increment()
            // First URL (RFC 8414) returns 404, second URL (OIDC) succeeds
            if request.url!.absoluteString.contains("oauth-authorization-server") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil,
                )!
                return (Data(), response)
            }
            let json = """
            {
                "issuer": "https://auth.example.com",
                "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(json.utf8), response)
        }

        let metadata = try await discoverAuthorizationServerMetadata(
            authServerURL: #require(URL(string: "https://auth.example.com")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata != nil)
        let finalCount = await counter.value
        #expect(finalCount == 2)
    }

    @Test
    func `AS discovery stops on 5xx error`() async throws {
        let counter = OAuthCallCounter()
        let mockHTTPClient: HTTPRequestHandler = { request in
            await counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data(), response)
        }

        let metadata = try await discoverAuthorizationServerMetadata(
            authServerURL: #require(URL(string: "https://auth.example.com")),
            httpClient: mockHTTPClient,
        )

        #expect(metadata == nil)
        // Should stop after first 5xx, not try OIDC fallback
        let finalCount = await counter.value
        #expect(finalCount == 1)
    }
}

// MARK: - Security Tests

struct IssuerValidationTests {
    @Test
    func `Matching issuer passes validation`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
        )
        try validateIssuer(metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
    }

    @Test
    func `Trailing slash normalization`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com/")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
        )
        // Issuer has trailing slash, expected does not – should still pass
        try validateIssuer(metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
    }

    @Test
    func `Mismatched issuer throws discoveryFailed`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://evil.example.com")),
            authorizationEndpoint: #require(URL(string: "https://evil.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://evil.example.com/token")),
        )
        #expect(throws: OAuthError.self) {
            try validateIssuer(metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
        }
    }

    @Test
    func `Issuer with different path is rejected`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com/tenant2")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
        )
        #expect(throws: OAuthError.self) {
            try validateIssuer(metadata, authServerURL: #require(URL(string: "https://auth.example.com/tenant1")))
        }
    }

    @Test
    func `DefaultOAuthProvider rejects mismatched issuer`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://auth.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                // Return AS metadata with a different issuer than what PRM specified
                let body = #"{"issuer": "https://evil.example.com", "authorization_endpoint": "https://evil.example.com/authorize", "token_endpoint": "https://evil.example.com/token", "registration_endpoint": "https://evil.example.com/register", "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try DefaultOAuthProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientMetadata: OAuthClientMetadata(
                redirectURIs: [#require(URL(string: "http://127.0.0.1:3000/callback"))],
                clientName: "Test",
            ),
            storage: InMemoryTokenStorage(),
            redirectHandler: { _ in },
            callbackHandler: { ("code", nil) },
            httpClient: httpClient,
        )

        await #expect(throws: OAuthError.self) {
            try await provider.handleUnauthorized(context: UnauthorizedContext())
        }
    }
}

struct TokenTypeValidationTests {
    @Test
    func `Bearer token type is accepted (case-insensitive)`() throws {
        // Lowercase
        let json1 = #"{"access_token": "tok", "token_type": "bearer"}"#
        let tokens1 = try JSONDecoder().decode(OAuthTokens.self, from: Data(json1.utf8))
        #expect(tokens1.tokenType == "Bearer")

        // Mixed case
        let json2 = #"{"access_token": "tok", "token_type": "BEARER"}"#
        let tokens2 = try JSONDecoder().decode(OAuthTokens.self, from: Data(json2.utf8))
        #expect(tokens2.tokenType == "Bearer")

        // Title case
        let json3 = #"{"access_token": "tok", "token_type": "Bearer"}"#
        let tokens3 = try JSONDecoder().decode(OAuthTokens.self, from: Data(json3.utf8))
        #expect(tokens3.tokenType == "Bearer")
    }

    @Test
    func `Non-bearer token type is rejected`() {
        let json = #"{"access_token": "tok", "token_type": "mac"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        }
    }

    @Test
    func `Empty token type is rejected`() {
        let json = #"{"access_token": "tok", "token_type": ""}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        }
    }
}

struct PRMRequiredTests {
    @Test
    func `DefaultOAuthProvider throws when PRM has no authorization_servers`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            // Return PRM without authorization_servers
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try DefaultOAuthProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientMetadata: OAuthClientMetadata(
                redirectURIs: [#require(URL(string: "http://127.0.0.1:3000/callback"))],
                clientName: "Test",
            ),
            storage: InMemoryTokenStorage(),
            redirectHandler: { _ in },
            callbackHandler: { ("code", nil) },
            httpClient: httpClient,
        )

        await #expect(throws: OAuthError.self) {
            try await provider.handleUnauthorized(context: UnauthorizedContext())
        }
    }

    @Test
    func `ClientCredentialsProvider throws when PRM is unavailable`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        await #expect(throws: OAuthError.self) {
            try await provider.handleUnauthorized(context: UnauthorizedContext())
        }
    }

    @Test
    func `PrivateKeyJWTProvider throws when PRM is unavailable`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            storage: InMemoryTokenStorage(),
            assertionProvider: { _ in "jwt" },
            httpClient: httpClient,
        )

        await #expect(throws: OAuthError.self) {
            try await provider.handleUnauthorized(context: UnauthorizedContext())
        }
    }
}

struct SSRFPreventionTests {
    @Test
    func `Unsafe resource_metadata URL is excluded from PRM discovery`() throws {
        // An attacker-controlled resource_metadata URL with a dangerous scheme
        // should be filtered out rather than causing an SSRF request
        let serverURL = try #require(URL(string: "https://api.example.com/mcp"))
        let unsafeURL = try #require(URL(string: "http://internal.corp:8080/.well-known/oauth-protected-resource"))

        let urls = buildProtectedResourceMetadataDiscoveryURLs(
            serverURL: serverURL,
            wwwAuthenticateURL: unsafeURL,
        )

        // The unsafe HTTP URL should be excluded; only the standard server-derived URLs remain
        for url in urls {
            #expect(url.absoluteString != unsafeURL.absoluteString)
        }
    }

    @Test
    func `Safe HTTPS resource_metadata URL is included in PRM discovery`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com/mcp"))
        let safeURL = try #require(URL(string: "https://custom.example.com/.well-known/prm"))

        let urls = buildProtectedResourceMetadataDiscoveryURLs(
            serverURL: serverURL,
            wwwAuthenticateURL: safeURL,
        )

        #expect(urls[0].absoluteString == safeURL.absoluteString)
    }

    @Test
    func `HTTP localhost resource_metadata URL is accepted`() throws {
        let serverURL = try #require(URL(string: "http://localhost:8080/mcp"))
        let localhostURL = try #require(URL(string: "http://localhost:8080/.well-known/prm"))

        let urls = buildProtectedResourceMetadataDiscoveryURLs(
            serverURL: serverURL,
            wwwAuthenticateURL: localhostURL,
        )

        #expect(urls[0].absoluteString == localhostURL.absoluteString)
    }
}

// MARK: - Token Storage Tests

struct InMemoryTokenStorageTests {
    @Test
    func `Returns nil when empty`() async throws {
        let storage = InMemoryTokenStorage()
        let tokens = try await storage.getTokens()
        let clientInfo = try await storage.getClientInfo()
        #expect(tokens == nil)
        #expect(clientInfo == nil)
    }

    @Test
    func `Stores and retrieves tokens`() async throws {
        let storage = InMemoryTokenStorage()
        let tokens = OAuthTokens(
            accessToken: "access-123",
            tokenType: "Bearer",
            expiresIn: 3600,
            refreshToken: "refresh-456",
        )
        try await storage.setTokens(tokens)
        let retrieved = try await storage.getTokens()
        #expect(retrieved?.accessToken == "access-123")
        #expect(retrieved?.refreshToken == "refresh-456")
    }

    @Test
    func `Stores and retrieves client info`() async throws {
        let storage = InMemoryTokenStorage()
        let info = OAuthClientInformation(clientId: "client-789", clientSecret: "secret")
        try await storage.setClientInfo(info)
        let retrieved = try await storage.getClientInfo()
        #expect(retrieved?.clientId == "client-789")
        #expect(retrieved?.clientSecret == "secret")
    }

    @Test
    func `Overwrites existing tokens`() async throws {
        let storage = InMemoryTokenStorage()
        try await storage.setTokens(OAuthTokens(accessToken: "old"))
        try await storage.setTokens(OAuthTokens(accessToken: "new"))
        let retrieved = try await storage.getTokens()
        #expect(retrieved?.accessToken == "new")
    }

    @Test
    func `Tokens and client info are independent`() async throws {
        let storage = InMemoryTokenStorage()
        try await storage.setTokens(OAuthTokens(accessToken: "token"))
        let clientInfo = try await storage.getClientInfo()
        #expect(clientInfo == nil)

        try await storage.setClientInfo(OAuthClientInformation(clientId: "client"))
        let tokens = try await storage.getTokens()
        #expect(tokens?.accessToken == "token")
    }
}

// MARK: - Scope Selection Tests

struct ScopeSelectionTests {
    @Test
    func `WWW-Authenticate scope has highest priority`() throws {
        let result = try selectScope(
            wwwAuthenticateScope: "read",
            protectedResourceMetadata: ProtectedResourceMetadata(
                resource: #require(URL(string: "https://example.com")),
                authorizationServers: [],
                scopesSupported: ["admin"],
            ),
            authServerMetadata: OAuthMetadata(
                issuer: #require(URL(string: "https://auth.example.com")),
                authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                scopesSupported: ["write"],
            ),
            clientMetadataScope: "offline_access",
        )
        #expect(result == "read")
    }

    @Test
    func `PRM scopes used when no WWW-Authenticate scope`() throws {
        let result = try selectScope(
            wwwAuthenticateScope: nil,
            protectedResourceMetadata: ProtectedResourceMetadata(
                resource: #require(URL(string: "https://example.com")),
                authorizationServers: [],
                scopesSupported: ["read", "write"],
            ),
            authServerMetadata: nil,
        )
        #expect(result == "read write")
    }

    @Test
    func `AS metadata scopes used when no PRM scopes`() throws {
        let result = try selectScope(
            wwwAuthenticateScope: nil,
            protectedResourceMetadata: nil,
            authServerMetadata: OAuthMetadata(
                issuer: #require(URL(string: "https://auth.example.com")),
                authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                scopesSupported: ["openid", "profile"],
            ),
        )
        #expect(result == "openid profile")
    }

    @Test
    func `Client metadata scope used as final fallback`() {
        let result = selectScope(
            wwwAuthenticateScope: nil,
            protectedResourceMetadata: nil,
            authServerMetadata: nil,
            clientMetadataScope: "offline_access",
        )
        #expect(result == "offline_access")
    }

    @Test
    func `Returns nil when all sources are nil`() {
        let result = selectScope(
            wwwAuthenticateScope: nil,
            protectedResourceMetadata: nil,
            authServerMetadata: nil,
        )
        #expect(result == nil)
    }

    @Test
    func `Empty PRM scopes array is skipped`() throws {
        let result = try selectScope(
            wwwAuthenticateScope: nil,
            protectedResourceMetadata: ProtectedResourceMetadata(
                resource: #require(URL(string: "https://example.com")),
                authorizationServers: [],
                scopesSupported: [],
            ),
            authServerMetadata: OAuthMetadata(
                issuer: #require(URL(string: "https://auth.example.com")),
                authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                scopesSupported: ["fallback"],
            ),
        )
        #expect(result == "fallback")
    }
}

// MARK: - State Parameter Tests

struct StateParameterTests {
    @Test
    func `Generated state has expected length`() {
        let state = generateState()
        // 32 bytes base64url-encoded: ceil(32 * 4/3) = 43 characters (no padding)
        #expect(state.count == 43)
    }

    @Test
    func `Generated state uses base64url characters only`() {
        let state = generateState()
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
        )
        for scalar in state.unicodeScalars {
            #expect(allowed.contains(scalar), "Invalid character: \(scalar)")
        }
    }

    @Test
    func `Two generated states are different`() {
        let s1 = generateState()
        let s2 = generateState()
        #expect(s1 != s2)
    }

    @Test
    func `State verification succeeds for matching values`() {
        let state = "test-state-value"
        #expect(verifyState(returned: "test-state-value", expected: state))
    }

    @Test
    func `State verification fails for mismatched values`() {
        #expect(!verifyState(returned: "wrong-state", expected: "expected-state"))
    }

    @Test
    func `State verification fails for nil returned state`() {
        #expect(!verifyState(returned: nil, expected: "expected-state"))
    }

    @Test
    func `State verification fails for different lengths`() {
        #expect(!verifyState(returned: "short", expected: "much-longer-state"))
    }
}

// MARK: - Client Registration Tests

struct ClientRegistrationTests {
    @Test
    func `Valid CIMD URL: HTTPS with non-root path`() throws {
        #expect(try isValidCIMDURL(#require(URL(string: "https://example.com/.well-known/client"))))
        #expect(try isValidCIMDURL(#require(URL(string: "https://example.com/client/metadata.json"))))
    }

    @Test
    func `Invalid CIMD URL: HTTP scheme`() throws {
        #expect(try !isValidCIMDURL(#require(URL(string: "http://example.com/client"))))
    }

    @Test
    func `Invalid CIMD URL: root path`() throws {
        #expect(try !isValidCIMDURL(#require(URL(string: "https://example.com/"))))
        #expect(try !isValidCIMDURL(#require(URL(string: "https://example.com"))))
    }

    @Test
    func `shouldUseCIMD: supported and valid URL`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            clientIdMetadataDocumentSupported: true,
        )
        let url = try #require(URL(string: "https://example.com/.well-known/client"))
        #expect(shouldUseCIMD(serverMetadata: metadata, clientMetadataURL: url))
    }

    @Test
    func `shouldUseCIMD: not supported by server`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            clientIdMetadataDocumentSupported: false,
        )
        let url = try #require(URL(string: "https://example.com/.well-known/client"))
        #expect(!shouldUseCIMD(serverMetadata: metadata, clientMetadataURL: url))
    }

    @Test
    func `shouldUseCIMD: no URL provided`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            clientIdMetadataDocumentSupported: true,
        )
        #expect(!shouldUseCIMD(serverMetadata: metadata, clientMetadataURL: nil))
    }

    @Test
    func `CIMD client info uses URL as client_id`() throws {
        let url = try #require(URL(string: "https://example.com/.well-known/client"))
        let info = clientInfoFromMetadataURL(url)
        #expect(info.clientId == "https://example.com/.well-known/client")
    }

    @Test
    func `DCR sends POST with JSON body`() async throws {
        let clientMetadata = try OAuthClientMetadata(
            redirectURIs: [#require(URL(string: "http://127.0.0.1:3000/callback"))],
            grantTypes: ["authorization_code"],
            responseTypes: ["code"],
            clientName: "Test Client",
        )

        let httpClient: HTTPRequestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let responseBody = """
            {"client_id": "assigned-id", "client_secret": "assigned-secret"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: [:],
                )!,
            )
        }

        let info = try await registerClient(
            clientMetadata: clientMetadata,
            registrationEndpoint: #require(URL(string: "https://auth.example.com/register")),
            httpClient: httpClient,
        )
        #expect(info.clientId == "assigned-id")
        #expect(info.clientSecret == "assigned-secret")
    }

    @Test
    func `DCR error response throws OAuthError`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let responseBody = """
            {"error": "invalid_client_metadata", "error_description": "Bad redirect"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: [:],
                )!,
            )
        }

        await #expect(throws: OAuthError.self) {
            try await registerClient(
                clientMetadata: OAuthClientMetadata(clientName: "Test"),
                registrationEndpoint: #require(URL(string: "https://auth.example.com/register")),
                httpClient: httpClient,
            )
        }
    }

    @Test
    func `Registration endpoint from metadata`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            registrationEndpoint: #require(URL(string: "https://auth.example.com/custom-register")),
        )
        let endpoint = try registrationEndpoint(from: metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/custom-register")
    }

    @Test
    func `Registration endpoint fallback to /register when no metadata`() throws {
        let endpoint = try registrationEndpoint(from: nil, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/register")
    }

    @Test
    func `Registration endpoint throws when metadata has no registration endpoint`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
        )
        #expect(throws: OAuthError.self) {
            try registrationEndpoint(from: metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
        }
    }
}

// MARK: - Resource Parameter Tests

struct ResourceParameterTests {
    @Test
    func `selectResourceURL uses PRM resource when it's a valid parent`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com/mcp/v1"))
        let prm = try ProtectedResourceMetadata(
            resource: #require(URL(string: "https://api.example.com/mcp")),
            authorizationServers: [#require(URL(string: "https://auth.example.com"))],
        )
        let result = ResourceURL.selectResourceURL(serverURL: serverURL, protectedResourceMetadata: prm)
        #expect(result.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `selectResourceURL falls back to canonical server URL when PRM resource is not a parent`() throws {
        let serverURL = try #require(URL(string: "https://api.example.com/mcp"))
        let prm = try ProtectedResourceMetadata(
            resource: #require(URL(string: "https://other.example.com/different")),
            authorizationServers: [#require(URL(string: "https://auth.example.com"))],
        )
        let result = ResourceURL.selectResourceURL(serverURL: serverURL, protectedResourceMetadata: prm)
        #expect(result.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `selectResourceURL uses canonical server URL when no PRM`() throws {
        let serverURL = try #require(URL(string: "https://API.Example.com:443/mcp"))
        let result = ResourceURL.selectResourceURL(serverURL: serverURL, protectedResourceMetadata: nil)
        #expect(result.absoluteString == "https://api.example.com/mcp")
    }

    @Test
    func `originURL strips path and query`() throws {
        let url = try #require(URL(string: "https://api.example.com:8443/mcp/v1?key=val"))
        let origin = ResourceURL.originURL(of: url)
        #expect(origin?.absoluteString == "https://api.example.com:8443/")
    }

    @Test
    func `originURL preserves scheme and host`() throws {
        let url = try #require(URL(string: "http://localhost:3000/mcp"))
        let origin = ResourceURL.originURL(of: url)
        #expect(origin?.absoluteString == "http://localhost:3000/")
    }
}

// MARK: - Endpoint URL Validation Tests

struct EndpointURLValidationTests {
    @Test
    func `HTTPS URLs are accepted`() throws {
        try validateEndpointURL(#require(URL(string: "https://auth.example.com/token")))
    }

    @Test
    func `HTTP localhost is accepted`() throws {
        try validateEndpointURL(#require(URL(string: "http://localhost:3000/token")))
        try validateEndpointURL(#require(URL(string: "http://127.0.0.1:8080/auth")))
    }

    @Test
    func `HTTP non-localhost is rejected`() throws {
        #expect(throws: OAuthError.self) {
            try validateEndpointURL(#require(URL(string: "http://auth.example.com/token")))
        }
    }

    @Test
    func `Dangerous schemes are rejected`() throws {
        #expect(throws: OAuthError.self) {
            try validateEndpointURL(#require(URL(string: "javascript:alert(1)")))
        }
        #expect(throws: OAuthError.self) {
            try validateEndpointURL(#require(URL(string: "data:text/html,<h1>hi</h1>")))
        }
    }
}

// MARK: - Token Exchange Tests

struct TokenExchangeTests {
    @Test
    func `Authorization endpoint from metadata`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/custom-auth")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
        )
        let endpoint = try authorizationEndpoint(from: metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/custom-auth")
    }

    @Test
    func `Authorization endpoint fallback to /authorize`() throws {
        let endpoint = try authorizationEndpoint(from: nil, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/authorize")
    }

    @Test
    func `Token endpoint from metadata`() throws {
        let metadata = try OAuthMetadata(
            issuer: #require(URL(string: "https://auth.example.com")),
            authorizationEndpoint: #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: #require(URL(string: "https://auth.example.com/custom-token")),
        )
        let endpoint = try tokenEndpoint(from: metadata, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/custom-token")
    }

    @Test
    func `Token endpoint fallback to /token`() throws {
        let endpoint = try tokenEndpoint(from: nil, authServerURL: #require(URL(string: "https://auth.example.com")))
        #expect(endpoint.absoluteString == "https://auth.example.com/token")
    }

    @Test
    func `Successful token exchange returns OAuthTokens`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            // Verify the request format
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

            let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("grant_type=authorization_code"))
            #expect(bodyString.contains("code=auth-code-123"))
            #expect(bodyString.contains("code_verifier="))

            let responseBody = """
            {"access_token": "new-access", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "new-refresh"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:],
                )!,
            )
        }

        let tokens = try await exchangeAuthorizationCode(
            code: "auth-code-123",
            codeVerifier: "test-verifier",
            redirectURI: #require(URL(string: "http://127.0.0.1:3000/callback")),
            clientId: "client-1",
            clientSecret: nil,
            clientAuthMethod: .none,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: httpClient,
        )
        #expect(tokens.accessToken == "new-access")
        #expect(tokens.refreshToken == "new-refresh")
        #expect(tokens.expiresIn == 3600)
    }

    @Test
    func `Token exchange includes resource parameter`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("resource=https%3A%2F%2Fapi.example.com%2Fmcp"))

            let responseBody = """
            {"access_token": "token", "token_type": "Bearer"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await exchangeAuthorizationCode(
            code: "code",
            codeVerifier: "verifier",
            redirectURI: #require(URL(string: "http://127.0.0.1/callback")),
            clientId: "client-1",
            clientSecret: nil,
            clientAuthMethod: .none,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )
        #expect(tokens.accessToken == "token")
    }

    @Test
    func `Token exchange error response throws OAuthError`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let responseBody = """
            {"error": "invalid_grant", "error_description": "Code expired"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.self) {
            try await exchangeAuthorizationCode(
                code: "expired-code",
                codeVerifier: "verifier",
                redirectURI: #require(URL(string: "http://127.0.0.1/callback")),
                clientId: "client-1",
                clientSecret: nil,
                clientAuthMethod: .none,
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }

    @Test
    func `Token exchange applies client_secret_basic authentication`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader != nil)
            #expect(authHeader?.hasPrefix("Basic ") == true)

            let responseBody = """
            {"access_token": "token", "token_type": "Bearer"}
            """
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        _ = try await exchangeAuthorizationCode(
            code: "code",
            codeVerifier: "verifier",
            redirectURI: #require(URL(string: "http://127.0.0.1/callback")),
            clientId: "client-1",
            clientSecret: "secret-1",
            clientAuthMethod: .clientSecretBasic,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: httpClient,
        )
    }
}

// MARK: - DefaultOAuthProvider Tests

struct DefaultOAuthProviderTests {
    /// Creates a provider with a mock HTTP client that routes requests
    /// based on URL path.
    private func createProvider(
        serverURL: URL = URL(string: "https://api.example.com/mcp")!,
        storage: InMemoryTokenStorage = InMemoryTokenStorage(),
        clientMetadataURL: URL? = nil,
        redirectHandler: @Sendable @escaping (URL) async throws -> Void = { _ in },
        callbackHandler: @Sendable @escaping () async throws -> (code: String, state: String?) = {
            ("auth-code", nil)
        },
        httpClient: @escaping HTTPRequestHandler,
    ) -> DefaultOAuthProvider {
        DefaultOAuthProvider(
            serverURL: serverURL,
            clientMetadata: OAuthClientMetadata(
                redirectURIs: [URL(string: "http://127.0.0.1:3000/callback")!],
                clientName: "Test Client",
            ),
            storage: storage,
            redirectHandler: redirectHandler,
            callbackHandler: callbackHandler,
            clientMetadataURL: clientMetadataURL,
            httpClient: httpClient,
        )
    }

    /// A mock HTTP client for the full authorization flow that handles
    /// PRM discovery, AS metadata discovery, client registration, and token exchange.
    private func fullFlowHTTPClient(
        prmResource: String = "https://api.example.com/mcp",
        authServer: String = "https://auth.example.com",
        clientId: String = "test-client-id",
        accessToken: String = "access-token",
        refreshToken: String? = "refresh-token",
        expiresIn: Int = 3600,
    ) -> HTTPRequestHandler {
        { request in
            let url = request.url!.absoluteString

            // PRM discovery
            if url.contains(".well-known/oauth-protected-resource") {
                let body = """
                {
                    "resource": "\(prmResource)",
                    "authorization_servers": ["\(authServer)"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // AS metadata discovery
            if url.contains(".well-known/oauth-authorization-server")
                || url.contains(".well-known/openid-configuration")
            {
                let body = """
                {
                    "issuer": "\(authServer)",
                    "authorization_endpoint": "\(authServer)/authorize",
                    "token_endpoint": "\(authServer)/token",
                    "registration_endpoint": "\(authServer)/register",
                    "code_challenge_methods_supported": ["S256"],
                    "response_types_supported": ["code"],
                    "token_endpoint_auth_methods_supported": ["none", "client_secret_basic"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // Client registration (DCR)
            if url.contains("/register") {
                let body = """
                {"client_id": "\(clientId)"}
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // Token exchange
            if url.contains("/token") {
                var body = """
                {"access_token": "\(accessToken)", "token_type": "Bearer", "expires_in": \(expiresIn)
                """
                if let refreshToken {
                    body += ", \"refresh_token\": \"\(refreshToken)\""
                }
                body += "}"
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // Default: 404
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!,
            )
        }
    }

    @Test
    func `tokens() returns nil when no stored tokens`() async throws {
        let provider = createProvider(httpClient: fullFlowHTTPClient())
        let tokens = try await provider.tokens()
        #expect(tokens == nil)
    }

    @Test
    func `tokens() returns stored tokens when valid`() async throws {
        let storage = InMemoryTokenStorage()
        try await storage.setTokens(OAuthTokens(accessToken: "cached-token", expiresIn: 3600))

        let provider = createProvider(storage: storage, httpClient: fullFlowHTTPClient())
        let tokens = try await provider.tokens()
        #expect(tokens?.accessToken == "cached-token")
    }

    @Test
    func `handleUnauthorized performs full authorization flow`() async throws {
        let redirectedURL = UncheckedSendableBox<URL?>(nil)
        let callbackState = UncheckedSendableBox<String?>(nil)

        let provider = createProvider(
            redirectHandler: { url in
                redirectedURL.value = url

                // Extract state from redirect URL for the callback
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
                callbackState.value = state
            },
            callbackHandler: {
                ("auth-code-123", callbackState.value)
            },
            httpClient: fullFlowHTTPClient(),
        )

        let context = UnauthorizedContext(
            resourceMetadataURL: nil,
            scope: nil,
            wwwAuthenticate: nil,
        )

        let tokens = try await provider.handleUnauthorized(context: context)

        // Verify tokens were returned
        #expect(tokens.accessToken == "access-token")
        #expect(tokens.refreshToken == "refresh-token")

        // Verify redirect URL was constructed correctly
        #expect(redirectedURL.value != nil)
        let components = try URLComponents(url: #require(redirectedURL.value), resolvingAgainstBaseURL: true)
        let queryItems = components?.queryItems ?? []
        #expect(queryItems.contains(where: { $0.name == "response_type" && $0.value == "code" }))
        #expect(queryItems.contains(where: { $0.name == "code_challenge_method" && $0.value == "S256" }))
        #expect(queryItems.contains(where: { $0.name == "state" }))
        #expect(queryItems.contains(where: { $0.name == "resource" }))
    }

    @Test
    func `handleUnauthorized validates state parameter`() async throws {
        let provider = createProvider(
            callbackHandler: {
                ("auth-code", "wrong-state")
            },
            httpClient: fullFlowHTTPClient(),
        )

        let context = UnauthorizedContext(
            resourceMetadataURL: nil,
            scope: nil,
            wwwAuthenticate: nil,
        )

        await #expect(throws: OAuthError.self) {
            try await provider.handleUnauthorized(context: context)
        }
    }

    @Test
    func `handleUnauthorized uses scope from context`() async throws {
        let capturedURL = UncheckedSendableBox<URL?>(nil)
        let callbackState = UncheckedSendableBox<String?>(nil)

        let provider = createProvider(
            redirectHandler: { url in
                capturedURL.value = url
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                callbackState.value = components?.queryItems?.first(where: { $0.name == "state" })?.value
            },
            callbackHandler: {
                ("code", callbackState.value)
            },
            httpClient: fullFlowHTTPClient(),
        )

        let context = UnauthorizedContext(
            resourceMetadataURL: nil,
            scope: "read write",
            wwwAuthenticate: nil,
        )

        _ = try await provider.handleUnauthorized(context: context)

        let components = try URLComponents(url: #require(capturedURL.value), resolvingAgainstBaseURL: true)
        let scopeParam = components?.queryItems?.first(where: { $0.name == "scope" })
        #expect(scopeParam?.value == "read write")
    }

    @Test
    func `handleUnauthorized retries on InvalidClient error`() async throws {
        let counter = OAuthCallCounter()
        let callbackState = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com", "authorization_servers": ["https://api.example.com"]}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                )
            }

            if url.contains(".well-known/oauth-authorization-server")
                || url.contains(".well-known/openid-configuration")
            {
                let body = """
                {
                    "issuer": "https://api.example.com",
                    "authorization_endpoint": "https://api.example.com/authorize",
                    "token_endpoint": "https://api.example.com/token",
                    "registration_endpoint": "https://api.example.com/register",
                    "code_challenge_methods_supported": ["S256"],
                    "response_types_supported": ["code"],
                    "token_endpoint_auth_methods_supported": ["none"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            if url.contains("/register") {
                let count = await counter.increment()
                if count == 1 {
                    let body = #"{"error": "invalid_client"}"#
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!,
                    )
                }
                return (
                    Data(#"{"client_id": "new-client"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: [:])!,
                )
            }

            if url.contains("/token") {
                let body = #"{"access_token": "recovered", "token_type": "Bearer"}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                )
            }

            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!,
            )
        }

        let provider = createProvider(
            redirectHandler: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                callbackState.value = components?.queryItems?.first(where: { $0.name == "state" })?.value
            },
            callbackHandler: {
                ("code", callbackState.value)
            },
            httpClient: httpClient,
        )

        let context = UnauthorizedContext(resourceMetadataURL: nil, scope: nil, wwwAuthenticate: nil)
        let tokens = try await provider.handleUnauthorized(context: context)
        #expect(tokens.accessToken == "recovered")
    }

    @Test
    func `tokens() returns stored tokens after successful handleUnauthorized`() async throws {
        let callbackState = UncheckedSendableBox<String?>(nil)

        let provider = createProvider(
            redirectHandler: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                callbackState.value = components?.queryItems?.first(where: { $0.name == "state" })?.value
            },
            callbackHandler: {
                ("code", callbackState.value)
            },
            httpClient: fullFlowHTTPClient(),
        )

        // Initially nil
        let before = try await provider.tokens()
        #expect(before == nil)

        // Perform auth
        let context = UnauthorizedContext(resourceMetadataURL: nil, scope: nil, wwwAuthenticate: nil)
        _ = try await provider.handleUnauthorized(context: context)

        // Now tokens should be available
        let after = try await provider.tokens()
        #expect(after?.accessToken == "access-token")
    }

    @Test
    func `handleUnauthorized uses CIMD when server supports it, skipping DCR`() async throws {
        let callbackState = UncheckedSendableBox<String?>(nil)
        let registrationCalled = UncheckedSendableBox<Bool>(false)
        let capturedTokenBody = UncheckedSendableBox<String?>(nil)

        let clientMetadataURL = try #require(URL(string: "https://example.com/.well-known/client-metadata.json"))

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString

            // PRM discovery
            if url.contains(".well-known/oauth-protected-resource") {
                let body = """
                {
                    "resource": "https://api.example.com/mcp",
                    "authorization_servers": ["https://auth.example.com"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // AS metadata with CIMD support
            if url.contains(".well-known/oauth-authorization-server")
                || url.contains(".well-known/openid-configuration")
            {
                let body = """
                {
                    "issuer": "https://auth.example.com",
                    "authorization_endpoint": "https://auth.example.com/authorize",
                    "token_endpoint": "https://auth.example.com/token",
                    "registration_endpoint": "https://auth.example.com/register",
                    "code_challenge_methods_supported": ["S256"],
                    "response_types_supported": ["code"],
                    "client_id_metadata_document_supported": true,
                    "token_endpoint_auth_methods_supported": ["none", "client_secret_basic"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // DCR should NOT be called
            if url.contains("/register") {
                registrationCalled.value = true
                let body = #"{"client_id": "dcr-client"}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            // Token exchange
            if url.contains("/token") {
                capturedTokenBody.value = String(data: request.httpBody ?? Data(), encoding: .utf8)
                let body = #"{"access_token": "cimd-token", "token_type": "Bearer", "expires_in": 3600}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                )
            }

            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!,
            )
        }

        let storage = InMemoryTokenStorage()
        let provider = createProvider(
            storage: storage,
            clientMetadataURL: clientMetadataURL,
            redirectHandler: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                callbackState.value = components?.queryItems?.first(where: { $0.name == "state" })?.value
            },
            callbackHandler: {
                ("auth-code", callbackState.value)
            },
            httpClient: httpClient,
        )

        let tokens = try await provider.handleUnauthorized(context: UnauthorizedContext())

        #expect(tokens.accessToken == "cimd-token")

        // DCR should not have been called
        #expect(!registrationCalled.value)

        // The client ID in the token request should be the metadata URL
        let tokenBody = try #require(capturedTokenBody.value)
        let expectedClientId = try #require(clientMetadataURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed))
        #expect(tokenBody.contains("client_id=\(expectedClientId)"))

        // Storage should have the CIMD-based client info
        let storedClientInfo = try await storage.getClientInfo()
        #expect(storedClientInfo?.clientId == clientMetadataURL.absoluteString)
    }

    @Test
    func `Resource mismatch in PRM aborts before authorization`() async throws {
        let provider = createProvider(
            httpClient: fullFlowHTTPClient(
                prmResource: "https://evil.example.com/mcp",
            ),
        )

        do {
            _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
            Issue.record("Expected resourceMismatch error")
        } catch let error as OAuthError {
            guard case let .resourceMismatch(expected, actual) = error else {
                Issue.record("Expected resourceMismatch, got \(error)")
                return
            }
            #expect(expected.absoluteString == "https://api.example.com/mcp")
            #expect(actual.absoluteString == "https://evil.example.com/mcp")
        }
    }
}

// MARK: - Client Credentials Token Request Tests

struct ClientCredentialsTokenRequestTests {
    @Test
    func `Success with basic auth`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            // Verify request format
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

            // Verify basic auth header is present
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader != nil)
            #expect(authHeader!.hasPrefix("Basic "))

            // Verify body
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(body.contains("grant_type=client_credentials"))
            #expect(body.contains("scope=read%20write"))
            #expect(body.contains("resource=https"))
            // client_id should NOT be in body for basic auth
            #expect(!body.contains("client_id="))

            let responseBody = #"{"access_token": "cc-token", "token_type": "Bearer", "expires_in": 3600}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await requestClientCredentialsToken(
            clientId: "my-client",
            clientSecret: "my-secret",
            clientAuthMethod: .clientSecretBasic,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            scope: "read write",
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )

        #expect(tokens.accessToken == "cc-token")
        #expect(tokens.expiresIn == 3600)
    }

    @Test
    func `Success with post body auth`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(body.contains("grant_type=client_credentials"))
            #expect(body.contains("client_id=my-client"))
            #expect(body.contains("client_secret=my-secret"))

            // No Authorization header for post auth
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let responseBody = #"{"access_token": "token", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await requestClientCredentialsToken(
            clientId: "my-client",
            clientSecret: "my-secret",
            clientAuthMethod: .clientSecretPost,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: httpClient,
        )

        #expect(tokens.accessToken == "token")
    }

    @Test
    func `Scope omitted when nil`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(!body.contains("scope="))

            let responseBody = #"{"access_token": "token", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        _ = try await requestClientCredentialsToken(
            clientId: "c",
            clientSecret: "s",
            clientAuthMethod: .clientSecretBasic,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            scope: nil,
            httpClient: httpClient,
        )
    }

    @Test
    func `OAuth error response is parsed and thrown`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = #"{"error": "invalid_client", "error_description": "bad credentials"}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.invalidClient("bad credentials")) {
            try await requestClientCredentialsToken(
                clientId: "c",
                clientSecret: "s",
                clientAuthMethod: .clientSecretBasic,
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }

    @Test
    func `HTTP error without JSON body throws authorizationFailed`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            (
                Data("Internal Server Error".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.self) {
            try await requestClientCredentialsToken(
                clientId: "c",
                clientSecret: "s",
                clientAuthMethod: .clientSecretBasic,
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }

    @Test
    func `Resource included in request body`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(body.contains("resource=https%3A%2F%2Fapi.example.com%2Fmcp"))

            let responseBody = #"{"access_token": "token", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        _ = try await requestClientCredentialsToken(
            clientId: "c",
            clientSecret: "s",
            clientAuthMethod: .clientSecretBasic,
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )
    }
}

// MARK: - JWT Assertion Token Request Tests

struct JWTAssertionTokenRequestTests {
    @Test
    func `Success with correct body parameters`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(body.contains("grant_type=client_credentials"))
            #expect(body.contains("client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"))
            #expect(body.contains("client_assertion=my.jwt.token"))

            // No Authorization header for JWT assertion
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let responseBody = #"{"access_token": "jwt-token", "token_type": "Bearer", "expires_in": 1800}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await requestTokenWithJWTAssertion(
            assertion: "my.jwt.token",
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            scope: "mcp:read",
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )

        #expect(tokens.accessToken == "jwt-token")
        #expect(tokens.expiresIn == 1800)
    }

    @Test
    func `No client_id in body`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(!body.contains("client_id="))
            #expect(!body.contains("client_secret="))

            let responseBody = #"{"access_token": "token", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        _ = try await requestTokenWithJWTAssertion(
            assertion: "jwt",
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: httpClient,
        )
    }

    @Test
    func `Scope and resource included`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = String(data: request.httpBody!, encoding: .utf8)!
            #expect(body.contains("scope=tools%3Aread"))
            #expect(body.contains("resource=https"))

            let responseBody = #"{"access_token": "token", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        _ = try await requestTokenWithJWTAssertion(
            assertion: "jwt",
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            scope: "tools:read",
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )
    }

    @Test
    func `oauth error response`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = #"{"error": "unauthorized_client", "error_description": "invalid assertion"}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.unauthorizedClient("invalid assertion")) {
            try await requestTokenWithJWTAssertion(
                assertion: "bad.jwt",
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }
}

// MARK: - JWT Assertion Refresh Tests

struct JWTAssertionRefreshTests {
    @Test
    func `Sends correct body parameters for refresh with JWT assertion`() async throws {
        let capturedBody = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            capturedBody.value = String(data: request.httpBody!, encoding: .utf8)
            let responseBody = #"{"access_token": "refreshed", "token_type": "Bearer", "expires_in": 3600}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await refreshAccessTokenWithJWTAssertion(
            refreshToken: "rt-123",
            assertion: "signed.jwt.here",
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            resource: #require(URL(string: "https://api.example.com/mcp")),
            httpClient: httpClient,
        )

        let body = try #require(capturedBody.value)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt-123"))
        #expect(body.contains("client_assertion=signed.jwt.here"))
        #expect(body.contains("client_assertion_type="))
        #expect(body.contains("resource=https"))
        #expect(!body.contains("client_id="))
        #expect(!body.contains("client_secret="))
        #expect(tokens.accessToken == "refreshed")
    }

    @Test
    func `Preserves original refresh token when server omits it`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let responseBody = #"{"access_token": "new-access", "token_type": "Bearer"}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
            )
        }

        let tokens = try await refreshAccessTokenWithJWTAssertion(
            refreshToken: "original-rt",
            assertion: "jwt",
            tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
            httpClient: httpClient,
        )

        #expect(tokens.accessToken == "new-access")
        #expect(tokens.refreshToken == "original-rt")
    }

    @Test
    func `error response parsed`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let body = #"{"error": "invalid_grant", "error_description": "token revoked"}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.invalidGrant("token revoked")) {
            try await refreshAccessTokenWithJWTAssertion(
                refreshToken: "revoked-rt",
                assertion: "jwt",
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }

    @Test
    func `HTTP error without JSON body throws tokenRefreshFailed`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            (
                Data("Internal Server Error".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!,
            )
        }

        await #expect(throws: OAuthError.self) {
            try await refreshAccessTokenWithJWTAssertion(
                refreshToken: "rt",
                assertion: "jwt",
                tokenEndpoint: #require(URL(string: "https://auth.example.com/token")),
                httpClient: httpClient,
            )
        }
    }
}

// MARK: - ClientCredentialsProvider Tests

struct ClientCredentialsProviderTests {
    /// Mock HTTP client for client credentials flow: PRM → AS metadata → token endpoint.
    private func m2mHTTPClient(
        authServer: String = "https://auth.example.com",
        accessToken: String = "cc-access-token",
        expiresIn: Int = 3600,
    ) -> HTTPRequestHandler {
        { request in
            let url = request.url!.absoluteString

            if url.contains(".well-known/oauth-protected-resource") {
                let body = """
                {
                    "resource": "https://api.example.com/mcp",
                    "authorization_servers": ["\(authServer)"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                )
            }

            if url.contains(".well-known/oauth-authorization-server")
                || url.contains(".well-known/openid-configuration")
            {
                let body = """
                {
                    "issuer": "\(authServer)",
                    "authorization_endpoint": "\(authServer)/authorize",
                    "token_endpoint": "\(authServer)/token",
                    "token_endpoint_auth_methods_supported": ["client_secret_basic"]
                }
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                )
            }

            if url.contains("/token") {
                let body = #"{"access_token": "\#(accessToken)", "token_type": "Bearer", "expires_in": \#(expiresIn)}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                )
            }

            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!,
            )
        }
    }

    @Test
    func `tokens nil when empty`() async throws {
        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "client",
            clientSecret: "secret",
            storage: InMemoryTokenStorage(),
            httpClient: m2mHTTPClient(),
        )
        #expect(try await provider.tokens() == nil)
    }

    @Test
    func `tokens() returns cached tokens when valid`() async throws {
        let storage = InMemoryTokenStorage()
        try await storage.setTokens(OAuthTokens(accessToken: "cached", expiresIn: 3600))

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "client",
            clientSecret: "secret",
            storage: storage,
            httpClient: m2mHTTPClient(),
        )

        let tokens = try await provider.tokens()
        #expect(tokens?.accessToken == "cached")
    }

    @Test
    func `tokens() returns nil when expired and no refresh token`() async throws {
        // Obtain a token via the provider with a 0-second expiry so
        // tokenExpiresAt is computed. The proactive refresh window (60s)
        // means it's immediately considered expired.
        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "client",
            clientSecret: "secret",
            storage: InMemoryTokenStorage(),
            httpClient: m2mHTTPClient(expiresIn: 0),
        )

        // First, get a token
        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())

        // Now tokens() should return nil because the token is already expired
        // and there's no refresh token to use
        let tokens = try await provider.tokens()
        #expect(tokens == nil)
    }

    @Test
    func `tokens() proactively refreshes when near expiry and refresh token is available`() async throws {
        let tokenCallCount = OAuthCallCounter()

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_basic"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                await tokenCallCount.increment()
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""

                if body.contains("grant_type=refresh_token") {
                    let responseBody = #"{"access_token": "refreshed-token", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "new-refresh"}"#
                    return (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
                }

                // Initial client_credentials request – return token with 0s expiry and a refresh token
                let responseBody = #"{"access_token": "initial-token", "token_type": "Bearer", "expires_in": 0, "refresh_token": "refresh-1"}"#
                return (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        // Get initial token (expires immediately)
        let initial = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(initial.accessToken == "initial-token")

        // tokens() should detect near-expiry and proactively refresh
        let refreshed = try await provider.tokens()
        #expect(refreshed?.accessToken == "refreshed-token")

        let count = await tokenCallCount.value
        #expect(count == 2) // initial + refresh
    }

    @Test
    func `handleUnauthorized performs discovery and token request`() async throws {
        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "service-client",
            clientSecret: "service-secret",
            storage: InMemoryTokenStorage(),
            scopes: "mcp:read",
            httpClient: m2mHTTPClient(),
        )

        let tokens = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(tokens.accessToken == "cc-access-token")
        #expect(tokens.expiresIn == 3600)
    }

    @Test
    func `handleUnauthorized uses cached discovery on subsequent calls`() async throws {
        let discoveryCount = OAuthCallCounter()

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains(".well-known") {
                await discoveryCount.increment()
                if url.contains("oauth-protected-resource") {
                    let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://auth.example.com"]}"#
                    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
                }
                let body = #"{"issuer": "https://auth.example.com", "authorization_endpoint": "https://auth.example.com/authorize", "token_endpoint": "https://auth.example.com/token"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            if url.contains("/token") {
                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())

        // Discovery endpoints should only be called once (results cached)
        let count = await discoveryCount.value
        #expect(count == 2) // PRM + AS metadata, only on first call
    }

    @Test
    func `handleUnauthorized includes resource in token request`() async throws {
        let capturedBody = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_basic"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                capturedBody.value = String(data: request.httpBody!, encoding: .utf8)
                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(capturedBody.value?.contains("resource=") == true)
    }

    @Test
    func `handleUnauthorized retries on InvalidClient`() async throws {
        let tokenCallCount = OAuthCallCounter()

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_basic"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                let count = await tokenCallCount.increment()
                if count == 1 {
                    return (Data(#"{"error": "invalid_client"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!)
                }
                return (Data(#"{"access_token": "recovered", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        let tokens = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(tokens.accessToken == "recovered")
    }

    @Test
    func `handleUnauthorized propagates error on second failure`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_basic"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                return (Data(#"{"error": "invalid_client"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        await #expect(throws: OAuthError.invalidClient(nil)) {
            try await provider.handleUnauthorized(context: UnauthorizedContext())
        }
    }

    @Test
    func `Scope from context overrides configured scopes`() async throws {
        let capturedBody = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_basic"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                capturedBody.value = String(data: request.httpBody!, encoding: .utf8)
                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            scopes: "original:scope",
            httpClient: httpClient,
        )

        let context = UnauthorizedContext(scope: "elevated:scope")
        _ = try await provider.handleUnauthorized(context: context)

        #expect(capturedBody.value?.contains("scope=elevated%3Ascope") == true)
        #expect(capturedBody.value?.contains("original") != true)
    }

    @Test
    func `Client auth method selected based on AS metadata`() async throws {
        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://auth.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://auth.example.com", "authorization_endpoint": "https://auth.example.com/authorize", "token_endpoint": "https://auth.example.com/token", "token_endpoint_auth_methods_supported": ["client_secret_post"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                // Verify post auth is used (client_id and client_secret in body, no Authorization header)
                let body = String(data: request.httpBody!, encoding: .utf8)!
                #expect(body.contains("client_id="))
                #expect(body.contains("client_secret="))
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try ClientCredentialsProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            clientSecret: "s",
            storage: InMemoryTokenStorage(),
            httpClient: httpClient,
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
    }
}

// MARK: - PrivateKeyJWTProvider Tests

struct PrivateKeyJWTProviderTests {
    /// Mock HTTP client for JWT provider flow.
    private func jwtHTTPClient(
        authServer: String = "https://auth.example.com",
        accessToken: String = "jwt-access-token",
    ) -> HTTPRequestHandler {
        { request in
            let url = request.url!.absoluteString

            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["\#(authServer)"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            if url.contains(".well-known") {
                let body = #"{"issuer": "\#(authServer)", "authorization_endpoint": "\#(authServer)/authorize", "token_endpoint": "\#(authServer)/token"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            if url.contains("/token") {
                let responseBody = #"{"access_token": "\#(accessToken)", "token_type": "Bearer", "expires_in": 1800}"#
                return (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }
    }

    @Test
    func `tokens() proactively refreshes with JWT assertion when near expiry`() async throws {
        let assertionCallCount = OAuthCallCounter()
        let capturedRefreshBody = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""

                if body.contains("grant_type=refresh_token") {
                    capturedRefreshBody.value = body
                    let responseBody = #"{"access_token": "refreshed-jwt-token", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "new-rt"}"#
                    return (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
                }

                // Initial token with 0s expiry and a refresh token
                let responseBody = #"{"access_token": "initial-jwt-token", "token_type": "Bearer", "expires_in": 0, "refresh_token": "rt-1"}"#
                return (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "jwt-client",
            storage: InMemoryTokenStorage(),
            assertionProvider: { _ in
                await assertionCallCount.increment()
                return await "fresh.jwt.\(assertionCallCount.value)"
            },
            httpClient: httpClient,
        )

        // Get initial token (expires immediately)
        let initial = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(initial.accessToken == "initial-jwt-token")

        // tokens() should detect near-expiry and proactively refresh using JWT assertion
        let refreshed = try await provider.tokens()
        #expect(refreshed?.accessToken == "refreshed-jwt-token")

        // Assertion provider should have been called twice: once for initial, once for refresh
        let count = await assertionCallCount.value
        #expect(count == 2)

        // Verify the refresh request included JWT assertion parameters
        let refreshBody = try #require(capturedRefreshBody.value)
        #expect(refreshBody.contains("grant_type=refresh_token"))
        #expect(refreshBody.contains("client_assertion="))
        #expect(refreshBody.contains("client_assertion_type="))
        #expect(refreshBody.contains("refresh_token=rt-1"))
    }

    @Test
    func `handleUnauthorized calls assertion provider with AS issuer as audience`() async throws {
        let capturedAudience = UncheckedSendableBox<String?>(nil)

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "jwt-client",
            storage: InMemoryTokenStorage(),
            assertionProvider: { audience in
                capturedAudience.value = audience
                return "test.jwt.token"
            },
            httpClient: jwtHTTPClient(),
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(capturedAudience.value == "https://auth.example.com")
    }

    @Test
    func `handleUnauthorized uses token endpoint URL as audience when no AS metadata`() async throws {
        let capturedAudience = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://auth.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                // No AS metadata available
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "jwt-client",
            storage: InMemoryTokenStorage(),
            assertionProvider: { audience in
                capturedAudience.value = audience
                return "test.jwt"
            },
            httpClient: httpClient,
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())

        // Without AS metadata, falls back to token endpoint URL derived from auth server
        #expect(capturedAudience.value == "https://auth.example.com/token")
    }

    @Test
    func `handleUnauthorized sends JWT assertion in token request`() async throws {
        let capturedBody = UncheckedSendableBox<String?>(nil)

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                capturedBody.value = String(data: request.httpBody!, encoding: .utf8)
                return (Data(#"{"access_token": "t", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "jwt-client",
            storage: InMemoryTokenStorage(),
            assertionProvider: { _ in "signed.jwt.here" },
            scopes: "mcp:read",
            httpClient: httpClient,
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())

        let body = try #require(capturedBody.value)
        #expect(body.contains("grant_type=client_credentials"))
        #expect(body.contains("client_assertion=signed.jwt.here"))
        #expect(body.contains("client_assertion_type="))
        #expect(body.contains("scope=mcp%3Aread"))
        #expect(!body.contains("client_id="))
        #expect(!body.contains("client_secret="))
    }

    @Test
    func `Assertion provider is called fresh on each token request`() async throws {
        let assertionCount = OAuthCallCounter()

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "jwt-client",
            storage: InMemoryTokenStorage(),
            assertionProvider: { _ in
                await assertionCount.increment()
                return await "jwt.\(assertionCount.value)"
            },
            httpClient: jwtHTTPClient(),
        )

        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())
        _ = try await provider.handleUnauthorized(context: UnauthorizedContext())

        let count = await assertionCount.value
        #expect(count == 2)
    }

    @Test
    func `Error recovery retries with fresh assertion`() async throws {
        let tokenCallCount = OAuthCallCounter()

        let httpClient: HTTPRequestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains(".well-known/oauth-protected-resource") {
                let body = #"{"resource": "https://api.example.com/mcp", "authorization_servers": ["https://api.example.com"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains(".well-known") {
                let body = #"{"issuer": "https://api.example.com", "authorization_endpoint": "https://api.example.com/authorize", "token_endpoint": "https://api.example.com/token"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            if url.contains("/token") {
                let count = await tokenCallCount.increment()
                if count == 1 {
                    return (Data(#"{"error": "invalid_client"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!)
                }
                return (Data(#"{"access_token": "recovered", "token_type": "Bearer"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }

        let provider = try PrivateKeyJWTProvider(
            serverURL: #require(URL(string: "https://api.example.com/mcp")),
            clientId: "c",
            storage: InMemoryTokenStorage(),
            assertionProvider: { _ in "jwt" },
            httpClient: httpClient,
        )

        let tokens = try await provider.handleUnauthorized(context: UnauthorizedContext())
        #expect(tokens.accessToken == "recovered")
    }

    @Test
    func `staticAssertionProvider returns pre-built JWT`() async throws {
        let provider = staticAssertionProvider("prebuilt.jwt.token")
        let result = try await provider("any-audience")
        #expect(result == "prebuilt.jwt.token")

        // Returns same JWT regardless of audience
        let result2 = try await provider("different-audience")
        #expect(result2 == "prebuilt.jwt.token")
    }
}

/// A simple wrapper for passing mutable values into `@Sendable` closures in tests.
/// Uses `@unchecked Sendable` because test closures execute sequentially.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Transport Auth Integration Tests

#if !os(Linux)

// Separate URL protocol for OAuth transport tests to avoid interference with HTTPClientTransportTests.
private final class OAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerStorage = RequestHandlerStorage()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try Self.handlerStorage.executeHandler(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TransportAuthIntegrationTests {
    let testEndpoint = URL(string: "http://localhost:8080/mcp")!

    private func createTransport(authProvider: (any OAuthClientProvider)? = nil)
        -> HTTPClientTransport
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthMockURLProtocol.self]

        return HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: config,
            streaming: false,
            authProvider: authProvider,
        )
    }

    private var testNotification: Data {
        Data(#"{"jsonrpc":"2.0","method":"test"}"#.utf8)
    }

    @Test
    func `Bearer token injected from auth provider`() async throws {
        let provider = MockOAuthProvider(tokens: OAuthTokens(accessToken: "test-token"))

        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == "Bearer test-token")

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }
        try await transport.send(testNotification, options: .init())
    }

    @Test
    func `No auth header when provider returns nil tokens`() async throws {
        let provider = MockOAuthProvider(tokens: nil)

        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == nil)

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }
        try await transport.send(testNotification, options: .init())
    }

    @Test
    func `No auth header when no auth provider configured`() async throws {
        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == nil)

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: nil)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }
        try await transport.send(testNotification, options: .init())
    }

    @Test
    func `401 triggers auth flow and retries`() async throws {
        let provider = MockOAuthProvider(
            tokens: nil,
            handleUnauthorizedResult: OAuthTokens(accessToken: "new-token"),
        )

        let counter = RequestCounter()

        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            let count = counter.increment()

            if count == 1 {
                // First request: return 401
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: [
                            "WWW-Authenticate":
                                #"Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource", scope="read""#,
                        ],
                    )!,
                    Data(),
                )
            } else {
                // Retry: should have new token
                let authHeader = request.value(forHTTPHeaderField: "Authorization")
                #expect(authHeader == "Bearer new-token")

                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 202,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    )!,
                    Data(),
                )
            }
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }
        try await transport.send(testNotification, options: .init())

        #expect(counter.value == 2)
        #expect(provider.handleUnauthorizedCallCount == 1)

        // Verify the context was passed correctly
        #expect(provider.lastContext?.scope == "read")
        #expect(
            provider.lastContext?.resourceMetadataURL?.absoluteString
                == "https://example.com/.well-known/oauth-protected-resource",
        )
    }

    @Test
    func `401 without auth provider throws error`() async throws {
        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: nil)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }

        await #expect(throws: MCPError.self) {
            try await transport.send(testNotification, options: .init())
        }
    }

    // MARK: - 403 Insufficient Scope Tests

    @Test
    func `403 with insufficient_scope triggers re-authorization and retry`() async throws {
        let provider = MockOAuthProvider(
            tokens: OAuthTokens(accessToken: "old-token"),
            handleUnauthorizedResult: OAuthTokens(accessToken: "scoped-token"),
        )

        let counter = RequestCounter()

        OAuthMockURLProtocol.handlerStorage.setHandler { request in
            let count = counter.increment()

            if count == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 403,
                        httpVersion: nil,
                        headerFields: [
                            "WWW-Authenticate":
                                #"Bearer error="insufficient_scope", scope="read write""#,
                        ],
                    )!,
                    Data(),
                )
            } else {
                let authHeader = request.value(forHTTPHeaderField: "Authorization")
                #expect(authHeader == "Bearer scoped-token")

                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 202,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    )!,
                    Data(),
                )
            }
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }
        try await transport.send(testNotification, options: .init())

        #expect(counter.value == 2)
        #expect(provider.handleUnauthorizedCallCount == 1)
        #expect(provider.lastContext?.scope == "read write")
    }

    @Test
    func `403 without insufficient_scope error throws immediately`() async throws {
        let provider = MockOAuthProvider(
            tokens: OAuthTokens(accessToken: "token"),
            handleUnauthorizedResult: OAuthTokens(accessToken: "new-token"),
        )

        OAuthMockURLProtocol.handlerStorage.setHandler { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://localhost:8080/mcp")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: [
                        "WWW-Authenticate": #"Bearer error="access_denied""#,
                    ],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }

        await #expect(throws: MCPError.self) {
            try await transport.send(testNotification, options: .init())
        }
        #expect(provider.handleUnauthorizedCallCount == 0)
    }

    @Test
    func `403 without auth provider throws error directly`() async throws {
        OAuthMockURLProtocol.handlerStorage.setHandler { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://localhost:8080/mcp")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: [:],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: nil)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }

        await #expect(throws: MCPError.self) {
            try await transport.send(testNotification, options: .init())
        }
    }

    @Test
    func `403 after 401 retry does not retry again`() async throws {
        let provider = MockOAuthProvider(
            tokens: nil,
            handleUnauthorizedResult: OAuthTokens(accessToken: "new-token"),
        )

        let counter = RequestCounter()

        OAuthMockURLProtocol.handlerStorage.setHandler { _ in
            let count = counter.increment()

            if count == 1 {
                // First: 401
                return (
                    HTTPURLResponse(
                        url: URL(string: "http://localhost:8080/mcp")!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: [
                            "WWW-Authenticate": "Bearer",
                        ],
                    )!,
                    Data(),
                )
            } else {
                // After auth: 403
                return (
                    HTTPURLResponse(
                        url: URL(string: "http://localhost:8080/mcp")!,
                        statusCode: 403,
                        httpVersion: nil,
                        headerFields: [
                            "WWW-Authenticate":
                                #"Bearer error="insufficient_scope", scope="admin""#,
                        ],
                    )!,
                    Data(),
                )
            }
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }

        await #expect(throws: MCPError.self) {
            try await transport.send(testNotification, options: .init())
        }
        // 401 triggered handleUnauthorized, but 403 after that should not retry
        #expect(provider.handleUnauthorizedCallCount == 1)
        #expect(counter.value == 2)
    }

    @Test
    func `Repeated 403 with same WWW-Authenticate header does not retry`() async throws {
        let provider = MockOAuthProvider(
            tokens: OAuthTokens(accessToken: "token"),
            handleUnauthorizedResult: OAuthTokens(accessToken: "new-token"),
        )

        let counter = RequestCounter()
        let wwwAuthHeader = #"Bearer error="insufficient_scope", scope="admin""#

        OAuthMockURLProtocol.handlerStorage.setHandler { _ in
            counter.increment()
            return (
                HTTPURLResponse(
                    url: URL(string: "http://localhost:8080/mcp")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: [
                        "WWW-Authenticate": wwwAuthHeader,
                    ],
                )!,
                Data(),
            )
        }

        let transport = createTransport(authProvider: provider)
        try await transport.connect()
        defer { OAuthMockURLProtocol.handlerStorage.clearHandler() }

        // First send: 403 → re-auth → retry → 403 with same header → stop
        await #expect(throws: MCPError.self) {
            try await transport.send(testNotification, options: .init())
        }
        // First 403 triggers auth, retry gets same 403 which is caught by
        // hasCompletedAuthForCurrentRequest guard
        #expect(provider.handleUnauthorizedCallCount == 1)
    }
}

// MARK: - Mock OAuth Provider

/// A mock `OAuthClientProvider` for testing transport auth integration.
/// Uses `@unchecked Sendable` because mutable state is only accessed from the
/// serialized test suite, never concurrently.
private final class MockOAuthProvider: OAuthClientProvider, @unchecked Sendable {
    private var _tokens: OAuthTokens?
    private let handleUnauthorizedResult: OAuthTokens?
    var handleUnauthorizedCallCount = 0
    var lastContext: UnauthorizedContext?

    init(tokens: OAuthTokens?, handleUnauthorizedResult: OAuthTokens? = nil) {
        _tokens = tokens
        self.handleUnauthorizedResult = handleUnauthorizedResult
    }

    func tokens() async throws -> OAuthTokens? {
        _tokens
    }

    func handleUnauthorized(context: UnauthorizedContext) async throws -> OAuthTokens {
        handleUnauthorizedCallCount += 1
        lastContext = context
        guard let result = handleUnauthorizedResult else {
            throw OAuthError.accessDenied("Mock: no tokens configured")
        }
        _tokens = result
        return result
    }
}
#endif

#endif
