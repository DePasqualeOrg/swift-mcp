// Copyright © Anthony DePasquale

#if swift(>=6.1)

import Foundation
import Testing

@testable import MCP

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
    resourceDocumentation: URL? = nil
) -> ServerAuthConfig {
    ServerAuthConfig(
        resource: resource,
        authorizationServers: authorizationServers,
        tokenVerifier: MockTokenVerifier(verifier),
        scopesSupported: scopesSupported,
        resourceName: resourceName,
        resourceDocumentation: resourceDocumentation
    )
}

/// Creates a valid ``AuthInfo`` for testing.
private func validAuthInfo(
    token: String = "valid-token",
    resource: String? = "https://api.example.com/mcp",
    expiresAt: Int? = nil
) -> AuthInfo {
    AuthInfo(
        token: token,
        clientId: "test-client",
        scopes: ["read", "write"],
        expiresAt: expiresAt ?? Int(Date().timeIntervalSince1970) + 3600,
        resource: resource
    )
}

// MARK: - Bearer Token Extraction Tests

@Suite("Bearer token extraction")
struct BearerTokenExtractionTests {
    @Test("Valid bearer token is extracted and validated")
    func validBearerToken() async {
        let expectedAuthInfo = validAuthInfo()
        let config = testConfig { token in
            token == "valid-token" ? expectedAuthInfo : nil
        }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid-token"]
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

    @Test("Missing Authorization header returns 401")
    func missingAuthHeader() async {
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

    @Test("Non-Bearer authorization scheme returns 401")
    func nonBearerScheme() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Basic dXNlcjpwYXNz"]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for non-Bearer scheme")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test("Empty bearer token returns 401")
    func emptyToken() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer "]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for empty token")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test("Malformed Authorization header returns 401")
    func malformedHeader() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "just-a-token-no-scheme"]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                Issue.record("Expected failure for malformed header")
            case let .unauthorized(response):
                #expect(response.statusCode == 401)
        }
    }

    @Test("Case-insensitive 'bearer' prefix is accepted")
    func caseInsensitiveBearer() async {
        let expectedAuthInfo = validAuthInfo()
        let config = testConfig { token in
            token == "valid-token" ? expectedAuthInfo : nil
        }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "bearer valid-token"]
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

@Suite("Token validation")
struct TokenValidationTests {
    @Test("TokenVerifier returning nil produces 401")
    func verifierReturnsNil() async {
        let config = testConfig { _ in nil }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer unknown-token"]
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

    @Test("Expired token returns 401")
    func expiredToken() async {
        let pastTimestamp = Int(Date().timeIntervalSince1970) - 3600
        let expiredAuthInfo = validAuthInfo(expiresAt: pastTimestamp)
        let config = testConfig { _ in expiredAuthInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer expired-token"]
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

    @Test("Token without expiration passes")
    func noExpiration() async {
        let authInfo = AuthInfo(
            token: "no-expiry",
            clientId: "test",
            scopes: ["read"],
            expiresAt: nil,
            resource: "https://api.example.com/mcp"
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer no-expiry"]
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

@Suite("Audience validation")
struct AudienceValidationTests {
    @Test("Token for matching resource passes")
    func matchingResource() async {
        let authInfo = validAuthInfo(resource: "https://api.example.com/mcp")
        let config = testConfig(
            resource: URL(string: "https://api.example.com/mcp")!
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case let .authenticated(info):
                #expect(info.resource == "https://api.example.com/mcp")
            case .unauthorized:
                Issue.record("Expected success for matching resource")
        }
    }

    @Test("Token for hierarchically matching sub-path passes")
    func hierarchicalMatch() async {
        let authInfo = validAuthInfo(resource: "https://api.example.com/mcp/v1")
        let config = testConfig(
            resource: URL(string: "https://api.example.com/mcp")!
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                break // Hierarchical match should succeed
            case .unauthorized:
                Issue.record("Expected success for hierarchical resource match")
        }
    }

    @Test("Token for different resource returns 401")
    func differentResource() async {
        let authInfo = validAuthInfo(resource: "https://other.example.com/api")
        let config = testConfig(
            resource: URL(string: "https://api.example.com/mcp")!
        ) { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"]
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

    @Test("Token without resource claim passes (no audience restriction)")
    func noResourceClaim() async {
        let authInfo = validAuthInfo(resource: nil)
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer valid"]
        )

        let result = await authenticateRequest(request, config: config)

        switch result {
            case .authenticated:
                break // No resource claim means no audience check
            case .unauthorized:
                Issue.record("Expected success for token without resource claim")
        }
    }

    @Test("Token with empty resource string returns 401")
    func emptyResourceString() async {
        let authInfo = AuthInfo(
            token: "bad-resource",
            clientId: "test",
            scopes: ["read"],
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            resource: ""
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer bad-resource"]
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

    @Test("Token with malformed resource (no scheme/host) fails audience check")
    func malformedResource() async {
        // URL(string:) parses this but it has no scheme or host,
        // so ResourceURL.matches correctly rejects it
        let authInfo = AuthInfo(
            token: "bad-resource",
            clientId: "test",
            scopes: ["read"],
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            resource: "not-a-real-url"
        )
        let config = testConfig { _ in authInfo }
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer bad-resource"]
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

@Suite("WWW-Authenticate header")
struct WWWAuthenticateHeaderTests {
    @Test("401 response includes error, description, and resource_metadata")
    func headerFields() async {
        let config = testConfig(
            resource: URL(string: "https://api.example.com/mcp")!
        )
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(wwwAuth.contains("Bearer"))
        #expect(wwwAuth.contains("error=\"invalid_token\""))
        #expect(wwwAuth.contains("error_description="))
        #expect(
            wwwAuth.contains(
                "resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource/mcp\""
            )
        )
    }

    @Test("buildWWWAuthenticateHeader constructs correct format")
    func buildHeader() {
        let prmURL = URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource/mcp"
        )!

        let header = buildWWWAuthenticateHeader(
            error: "invalid_token",
            description: "Token has expired",
            resourceMetadataURL: prmURL
        )

        #expect(header.hasPrefix("Bearer "))
        #expect(header.contains("error=\"invalid_token\""))
        #expect(header.contains("error_description=\"Token has expired\""))
        #expect(
            header.contains(
                "resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource/mcp\""
            )
        )
    }

    @Test("buildWWWAuthenticateHeader includes scope when provided")
    func headerWithScope() {
        let prmURL = URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource"
        )!

        let header = buildWWWAuthenticateHeader(
            error: "insufficient_scope",
            description: "Additional permissions required",
            resourceMetadataURL: prmURL,
            scope: "read write admin"
        )

        #expect(header.contains("error=\"insufficient_scope\""))
        #expect(header.contains("scope=\"read write admin\""))
    }

    @Test("buildWWWAuthenticateHeader omits description when nil")
    func headerWithoutDescription() {
        let prmURL = URL(
            string: "https://api.example.com/.well-known/oauth-protected-resource"
        )!

        let header = buildWWWAuthenticateHeader(
            error: "invalid_token",
            resourceMetadataURL: prmURL
        )

        #expect(header.contains("error=\"invalid_token\""))
        #expect(!header.contains("error_description"))
    }

    @Test("401 response body contains JSON error")
    func responseBody() async {
        let config = testConfig()
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        #expect(response.headers[HTTPHeader.contentType] == "application/json")

        let body = try! JSONDecoder().decode(OAuthTokenErrorResponse.self, from: response.body!)
        #expect(body.error == "invalid_token")
        #expect(body.errorDescription != nil)
    }

    @Test("401 response includes scope when scopesSupported is configured")
    func scopeInResponse() async {
        let config = testConfig(scopesSupported: ["read", "write", "admin"])
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(wwwAuth.contains("scope=\"read write admin\""))
    }

    @Test("401 response omits scope when scopesSupported is nil")
    func noScopeInResponse() async {
        let config = testConfig(scopesSupported: nil)
        let request = HTTPRequest(method: "GET", headers: [:])

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(!wwwAuth.contains("scope="))
    }

    @Test("Empty bearer token gets correct error message")
    func emptyTokenErrorMessage() async {
        let config = testConfig()
        let request = HTTPRequest(
            method: "GET",
            headers: ["Authorization": "Bearer "]
        )

        let result = await authenticateRequest(request, config: config)

        guard case let .unauthorized(response) = result else {
            Issue.record("Expected failure")
            return
        }

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(wwwAuth.contains("Empty bearer token"))
    }
}

// MARK: - Insufficient Scope Response Tests

@Suite("Insufficient scope response")
struct InsufficientScopeTests {
    @Test("403 response has correct status code and error")
    func statusAndError() throws {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "admin",
            description: "Admin access required",
            config: config
        )

        #expect(response.statusCode == 403)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(wwwAuth.contains("error=\"insufficient_scope\""))
        #expect(wwwAuth.contains("scope=\"admin\""))
        #expect(wwwAuth.contains("error_description=\"Admin access required\""))
        #expect(wwwAuth.contains("resource_metadata="))

        let body = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: response.body!)
        #expect(body.error == "insufficient_scope")
        #expect(body.errorDescription == "Admin access required")
    }

    @Test("403 response with multiple scopes")
    func multipleScopes() {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "read write admin",
            config: config
        )

        #expect(response.statusCode == 403)

        let wwwAuth = response.headers["www-authenticate"]!
        #expect(wwwAuth.contains("scope=\"read write admin\""))
    }

    @Test("403 response without description uses default")
    func defaultDescription() throws {
        let config = testConfig()

        let response = insufficientScopeResponse(
            scope: "admin",
            config: config
        )

        let body = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: response.body!)
        #expect(body.errorDescription == "Insufficient scope")
    }
}

// MARK: - PRM Endpoint Tests

@Suite("Protected Resource Metadata endpoint")
struct PRMEndpointTests {
    @Test("PRM response contains correct metadata")
    func responseContent() throws {
        let config = testConfig(
            resource: URL(string: "https://api.example.com/mcp")!,
            authorizationServers: [URL(string: "https://auth.example.com")!],
            scopesSupported: ["read", "write"],
            resourceName: "Test MCP Server",
            resourceDocumentation: URL(string: "https://docs.example.com")!
        )

        let response = protectedResourceMetadataResponse(config: config)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeader.contentType] == "application/json")
        #expect(response.headers[HTTPHeader.cacheControl] == "public, max-age=3600")

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: response.body!
        )
        #expect(metadata.resource == URL(string: "https://api.example.com/mcp")!)
        #expect(metadata.authorizationServers == [URL(string: "https://auth.example.com")!])
        #expect(metadata.scopesSupported == ["read", "write"])
        #expect(metadata.bearerMethodsSupported == ["header"])
        #expect(metadata.resourceName == "Test MCP Server")
        #expect(metadata.resourceDocumentation == URL(string: "https://docs.example.com")!)
    }

    @Test("PRM response with minimal config")
    func minimalConfig() throws {
        let config = testConfig()

        let response = protectedResourceMetadataResponse(config: config)

        #expect(response.statusCode == 200)

        let metadata = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: response.body!
        )
        #expect(metadata.resource == URL(string: "https://api.example.com/mcp")!)
        #expect(metadata.authorizationServers == [URL(string: "https://auth.example.com")!])
        #expect(metadata.scopesSupported == nil)
        #expect(metadata.bearerMethodsSupported == ["header"])
        #expect(metadata.resourceName == nil)
        #expect(metadata.resourceDocumentation == nil)
    }

    @Test("PRM response JSON uses snake_case keys")
    func snakeCaseKeys() throws {
        let config = testConfig(
            scopesSupported: ["read"],
            resourceName: "Test"
        )

        let response = protectedResourceMetadataResponse(config: config)
        let json = try JSONSerialization.jsonObject(with: response.body!) as! [String: Any]

        #expect(json["authorization_servers"] != nil)
        #expect(json["scopes_supported"] != nil)
        #expect(json["bearer_methods_supported"] != nil)
        #expect(json["resource_name"] != nil)
    }

    @Test("PRM response omits nil optional fields")
    func omitsNilFields() throws {
        let config = testConfig()

        let response = protectedResourceMetadataResponse(config: config)
        let json = try JSONSerialization.jsonObject(with: response.body!) as! [String: Any]

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

@Suite("PRM path construction")
struct PRMPathTests {
    @Test("Path-based server URL")
    func pathBased() {
        let url = URL(string: "https://api.example.com/mcp")!
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource/mcp")
    }

    @Test("Root server URL")
    func rootServer() {
        let url = URL(string: "https://api.example.com/")!
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource")
    }

    @Test("Root server URL without trailing slash")
    func rootServerNoSlash() {
        let url = URL(string: "https://api.example.com")!
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource")
    }

    @Test("Nested path server URL")
    func nestedPath() {
        let url = URL(string: "https://api.example.com/v1/mcp")!
        let path = protectedResourceMetadataPath(for: url)
        #expect(path == "/.well-known/oauth-protected-resource/v1/mcp")
    }

    @Test("PRM full URL construction")
    func fullURL() {
        let url = URL(string: "https://api.example.com/mcp")!
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp"
        )
    }

    @Test("PRM full URL for root server")
    func fullURLRoot() {
        let url = URL(string: "https://api.example.com")!
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource"
        )
    }

    @Test("PRM full URL strips query and fragment")
    func fullURLStripsQueryAndFragment() {
        let url = URL(string: "https://api.example.com/mcp?key=val#section")!
        let prmURL = protectedResourceMetadataURL(for: url)
        #expect(
            prmURL.absoluteString
                == "https://api.example.com/.well-known/oauth-protected-resource/mcp"
        )
    }
}

#endif
