// Copyright © Anthony DePasquale

#if swift(>=6.1)

import Foundation
@testable import MCP
import Testing

// MARK: - Test Helpers

/// A mock token verifier for testing that returns predefined results.
private struct MockTokenVerifier: TokenVerifier {
    let handler: @Sendable (String) async -> AuthInfo?

    init(_ handler: @escaping @Sendable (String) async -> AuthInfo?) {
        self.handler = handler
    }

    func verifyToken(_ token: String) async -> AuthInfo? {
        await handler(token)
    }
}

/// Creates a ``ServerAuthConfig`` for testing.
private func testConfig(
    resource: URL = URL(string: "https://api.example.com/mcp")!,
    authorizationServers: [URL] = [URL(string: "https://auth.example.com")!],
    verifier: @escaping @Sendable (String) async -> AuthInfo? = { _ in nil },
    scopesSupported: [String]? = nil,
    resourceName: String? = nil,
    resourceDocumentation: URL? = nil,
) -> ServerAuthConfig {
    ServerAuthConfig(
        resource: resource,
        authorizationServers: authorizationServers,
        tokenVerifier: MockTokenVerifier(verifier),
        scopesSupported: scopesSupported,
        resourceName: resourceName,
        resourceDocumentation: resourceDocumentation,
    )
}

/// Creates a valid ``AuthInfo`` for testing.
private func validAuthInfo(
    token: String = "valid-token",
    resource: String? = "https://api.example.com/mcp",
    expiresAt: Int? = nil,
) -> AuthInfo {
    AuthInfo(
        token: token,
        clientId: "test-client",
        scopes: ["read", "write"],
        expiresAt: expiresAt ?? Int(Date().timeIntervalSince1970) + 3600,
        resource: resource,
    )
}

// MARK: - Bearer Token Extraction Tests

struct BearerTokenExtractionTests {
    @Test
    func `Valid bearer token is extracted and validated`() async {
        let expectedAuthInfo = validAuthInfo()
        let config = testConfig { token in
            token == "valid-token" ? expectedAuthInfo : nil
        }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid-token"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case let .authenticated(authInfo):
                #expect(authInfo.token == "valid-token")
                #expect(authInfo.clientId == "test-client")
                #expect(authInfo.scopes == ["read", "write"])
            case let .unauthorized(response):
                Issue.record("Expected success, got 401 with status \(response.statusCode)")
        }
    }

    @Test
    func `Missing Authorization header returns 401`() async {
        let config = testConfig()
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for missing auth header")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth != nil)
                #expect(wwwAuth?.contains("invalid_token") == true)
        }
    }

    @Test
    func `Non-Bearer authorization scheme returns 401`() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Basic dXNlcjpwYXNz"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for non-Bearer scheme")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test
    func `Empty bearer token returns 401`() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer "],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for empty token")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test
    func `Malformed Authorization header returns 401`() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "just-a-token-no-scheme"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for malformed header")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test
    func `Case-insensitive 'bearer' prefix is accepted`() async {
        let expectedAuthInfo = validAuthInfo()
        let config = testConfig { token in
            token == "valid-token" ? expectedAuthInfo : nil
        }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "bearer valid-token"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case let .authenticated(authInfo):
                #expect(authInfo.token == "valid-token")
            case .unauthorized:
                Issue.record("Expected success with lowercase 'bearer' prefix")
        }
    }
}

// MARK: - Token Validation Tests

struct TokenValidationTests {
    @Test
    func `TokenVerifier returning nil produces 401`() async {
        let config = testConfig { _ in nil }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer unknown-token"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for unrecognized token")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth?.contains("invalid_token") == true)
                #expect(wwwAuth?.contains("Token validation failed") == true)
        }
    }

    @Test
    func `Expired token returns 401`() async {
        let pastTimestamp = Int(Date().timeIntervalSince1970) - 3600
        let expiredAuthInfo = validAuthInfo(expiresAt: pastTimestamp)
        let config = testConfig { _ in expiredAuthInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer expired-token"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for expired token")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth?.contains("Token has expired") == true)
        }
    }

    @Test
    func `Token without expiration passes`() async {
        let authInfo = AuthInfo(
            token: "no-expiry",
            clientId: "test",
            scopes: ["read"],
            expiresAt: nil,
            resource: "https://api.example.com/mcp",
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer no-expiry"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case let .authenticated(info):
                #expect(info.token == "no-expiry")
            case .unauthorized:
                Issue.record("Expected success for token without expiration")
        }
    }
}

// MARK: - Audience Validation Tests

struct AudienceValidationTests {
    @Test
    func `Token for matching resource passes`() async throws {
        let authInfo = validAuthInfo(resource: "https://api.example.com/mcp")
        let config = try testConfig(
            resource: #require(URL(string: "https://api.example.com/mcp")),
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case let .authenticated(info):
                #expect(info.resource == "https://api.example.com/mcp")
            case .unauthorized:
                Issue.record("Expected success for matching resource")
        }
    }

    @Test
    func `Token for hierarchically matching sub-path passes`() async throws {
        let authInfo = validAuthInfo(resource: "https://api.example.com/mcp/v1")
        let config = try testConfig(
            resource: #require(URL(string: "https://api.example.com/mcp")),
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                break // Hierarchical match should succeed
            case .unauthorized:
                Issue.record("Expected success for hierarchical resource match")
        }
    }

    @Test
    func `Token for different resource returns 401`() async throws {
        let authInfo = validAuthInfo(resource: "https://other.example.com/api")
        let config = try testConfig(
            resource: #require(URL(string: "https://api.example.com/mcp")),
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for non-matching resource")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth?.contains("not valid for this resource") == true)
        }
    }

    @Test
    func `Token without resource claim passes (no audience restriction)`() async {
        let authInfo = validAuthInfo(resource: nil)
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                break // No resource claim means no audience check
            case .unauthorized:
                Issue.record("Expected success for token without resource claim")
        }
    }

    @Test
    func `Token with empty resource string returns 401`() async {
        let authInfo = AuthInfo(
            token: "bad-resource",
            clientId: "test",
            scopes: ["read"],
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            resource: "",
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer bad-resource"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for empty resource string")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth?.contains("invalid resource identifier") == true)
        }
    }

    @Test
    func `Token with malformed resource (no scheme/host) fails audience check`() async {
        // URL(string:) parses this but it has no scheme or host,
        // so ResourceURL.matches correctly rejects it
        let authInfo = AuthInfo(
            token: "bad-resource",
            clientId: "test",
            scopes: ["read"],
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            resource: "not-a-real-url",
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer bad-resource"],
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for malformed resource URL")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
                let wwwAuth = response.headers["www-authenticate"]
                #expect(wwwAuth?.contains("not valid for this resource") == true)
        }
    }
}

// MARK: - WWW-Authenticate Header Tests

struct WWWAuthenticateHeaderTests {
    @Test
    func `401 response includes error, description, and resource_metadata`() async throws {
        let config = try testConfig(
            resource: #require(URL(string: "https://api.example.com/mcp")),
        )
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(wwwAuth.contains("Bearer"))
        #expect(wwwAuth.contains("error=\"invalid_token\""))
        #expect(wwwAuth.contains("error_description="))
        #expect(
            wwwAuth.contains(
                "resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource/mcp\"",
            ),
        )
    }

    @Test
    func `buildWWWAuthenticateHeader constructs correct format`() throws {
        let prmURL = try #require(URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource/mcp",
        ))

        let header = buildWWWAuthenticateHeader(
            error: "invalid_token",
            description: "Token has expired",
            resourceMetadataURL: prmURL,
        )

        #expect(header.hasPrefix("Bearer "))
        #expect(header.contains("error=\"invalid_token\""))
        #expect(header.contains("error_description=\"Token has expired\""))
        #expect(
            header.contains(
                "resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource/mcp\"",
            ),
        )
    }

    @Test
    func `buildWWWAuthenticateHeader includes scope when provided`() throws {
        let prmURL = try #require(URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource",
        ))

        let header = buildWWWAuthenticateHeader(
            error: "insufficient_scope",
            description: "Additional permissions required",
            resourceMetadataURL: prmURL,
            scope: "read write admin",
        )

        #expect(header.contains("error=\"insufficient_scope\""))
        #expect(header.contains("scope=\"read write admin\""))
    }

    @Test
    func `buildWWWAuthenticateHeader omits description when nil`() throws {
        let prmURL = try #require(URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource",
        ))

        let header = buildWWWAuthenticateHeader(
            error: "invalid_token",
            resourceMetadataURL: prmURL,
        )

        #expect(header.contains("error=\"invalid_token\""))
        #expect(!header.contains("error_description"))
    }

    @Test
    func `401 response body contains JSON error`() async throws {
        let config = testConfig()
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        #expect(response.headers[HTTPHeader.contentType] == "application/json")

        let body = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: #require(response.body))
        #expect(body.error == "invalid_token")
        #expect(body.errorDescription != nil)
    }

    @Test
    func `401 response includes scope when scopesSupported is configured`() async throws {
        let config = testConfig(scopesSupported: ["read", "write", "admin"])
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(wwwAuth.contains("scope=\"read write admin\""))
    }

    @Test
    func `401 response omits scope when scopesSupported is nil`() async throws {
        let config = testConfig(scopesSupported: nil)
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(!wwwAuth.contains("scope="))
    }

    @Test
    func `Empty bearer token gets correct error message`() async throws {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer "],
        )

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(wwwAuth.contains("Empty bearer token"))
    }
}

// MARK: - Insufficient Scope Response Tests

struct InsufficientScopeTests {
    @Test
    func `403 response has correct status code and error`() throws {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "admin",
            description: "Admin access required",
            config: config,
        )

        #expect(response.statusCode == 403)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(wwwAuth.contains("error=\"insufficient_scope\""))
        #expect(wwwAuth.contains("scope=\"admin\""))
        #expect(wwwAuth.contains("error_description=\"Admin access required\""))
        #expect(wwwAuth.contains("resource_metadata="))

        let body = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: #require(response.body))
        #expect(body.error == "insufficient_scope")
        #expect(body.errorDescription == "Admin access required")
    }

    @Test
    func `403 response with multiple scopes`() throws {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "read write admin",
            config: config,
        )

        #expect(response.statusCode == 403)

        let wwwAuth = try #require(response.headers["www-authenticate"])
        #expect(wwwAuth.contains("scope=\"read write admin\""))
    }

    @Test
    func `403 response without description uses default`() throws {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "admin",
            config: config,
        )

        let body = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: #require(response.body))
        #expect(body.errorDescription == "Insufficient scope")
    }
}

// MARK: - PRM Endpoint Tests

struct PRMEndpointTests {
    @Test
    func `PRM response contains correct metadata`() throws {
        let config = try testConfig(
            resource: #require(URL(string: "https://api.example.com/mcp")),
            authorizationServers: [#require(URL(string: "https://auth.example.com"))],
            scopesSupported: ["read", "write"],
            resourceName: "Test MCP Server",
            resourceDocumentation: #require(URL(string: "https://docs.example.com")),
        )

        let response = protectedResourceMetadataResponse(config: config)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
        #expect(response.headers[HTTPHeader.cacheControl] == "public, max-age=3600")

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: #require(response.body),
        )
        #expect(metadata.resource == URL(string: "https://api.example.com/mcp")!)
        #expect(try metadata.authorizationServers == [#require(URL(string: "https://auth.example.com"))])
        #expect(metadata.scopesSupported == ["read", "write"])
        #expect(metadata.bearerMethodsSupported == ["header"])
        #expect(metadata.resourceName == "Test MCP Server")
        #expect(metadata.resourceDocumentation == URL(string: "https://docs.example.com")!)
    }

    @Test
    func `PRM response with minimal config`() throws {
        let config = testConfig()

        let response = protectedResourceMetadataResponse(config: config)

        #expect(response.statusCode == 200)

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: #require(response.body),
        )
        #expect(metadata.resource == URL(string: "https://api.example.com/mcp")!)
        #expect(try metadata.authorizationServers == [#require(URL(string: "https://auth.example.com"))])
        #expect(metadata.scopesSupported == nil)
        #expect(metadata.bearerMethodsSupported == ["header"])
        #expect(metadata.resourceName == nil)
        #expect(metadata.resourceDocumentation == nil)
    }

    @Test
    func `PRM response JSON uses snake_case keys`() throws {
        let config = testConfig(
            scopesSupported: ["read"],
            resourceName: "Test",
        )

        let response = protectedResourceMetadataResponse(config: config)
        let body = try #require(response.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["authorization_servers"] != nil)
        #expect(json["scopes_supported"] != nil)
        #expect(json["bearer_methods_supported"] != nil)
        #expect(json["resource_name"] != nil)
    }

    @Test
    func `PRM response omits nil optional fields`() throws {
        let config = testConfig()

        let response = protectedResourceMetadataResponse(config: config)
        let body = try #require(response.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Required/always-present fields
        #expect(json["resource"] != nil)
        #expect(json["authorization_servers"] != nil)
        #expect(json["bearer_methods_supported"] != nil)

        // Optional fields should be omitted (not null) when not configured
        #expect(json["scopes_supported"] == nil)
        #expect(json["resource_name"] == nil)
        #expect(json["resource_documentation"] == nil)
        #expect(json["jwks_uri"] == nil)
        #expect(json["resource_policy_uri"] == nil)
        #expect(json["resource_tos_uri"] == nil)
    }
}

// MARK: - PRM Path Construction Tests

struct PRMPathTests {
    @Test
    func `Path-based server URL`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp"))
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource/mcp")
    }

    @Test
    func `Root server URL`() throws {
        let url = try #require(URL(string: "https://api.example.com/"))
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource")
    }

    @Test
    func `Root server URL without trailing slash`() throws {
        let url = try #require(URL(string: "https://api.example.com"))
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource")
    }

    @Test
    func `Nested path server URL`() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/mcp"))
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource/v1/mcp")
    }

    @Test
    func `PRM full URL construction`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp"))
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp",
        )
    }

    @Test
    func `PRM full URL for root server`() throws {
        let url = try #require(URL(string: "https://api.example.com"))
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource",
        )
    }

    @Test
    func `PRM full URL strips query and fragment`() throws {
        let url = try #require(URL(string: "https://api.example.com/mcp?key=val#section"))
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp",
        )
    }
}

#endif
