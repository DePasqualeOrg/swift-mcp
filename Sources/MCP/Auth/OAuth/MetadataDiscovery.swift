// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP Client Abstraction

/// A function that performs an HTTP request and returns the response.
///
/// Used for dependency injection in discovery and token exchange functions,
/// allowing tests to provide mock responses without hitting the network.
public typealias HTTPRequestHandler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Default `HTTPRequestHandler` that uses `URLSession`.
public func defaultHTTPRequestHandler(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw OAuthError.discoveryFailed("Non-HTTP response received")
    }
    return (data, httpResponse)
}

// MARK: - Protected Resource Metadata Discovery

/// Discovers Protected Resource Metadata (RFC 9728) for an MCP server.
///
/// Tries a fallback chain of well-known URLs:
/// 1. URL from `WWW-Authenticate` `resource_metadata` parameter (if provided)
/// 2. `/.well-known/oauth-protected-resource/{path}` (if the server URL has a path)
/// 3. `/.well-known/oauth-protected-resource` (root)
///
/// - Parameters:
///   - serverURL: The MCP server URL
///   - wwwAuthenticateResourceMetadataURL: Optional URL from the `WWW-Authenticate` header
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The discovered metadata, or `nil` if discovery failed at all URLs
///
/// - SeeAlso: [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)
public func discoverProtectedResourceMetadata(
    serverURL: URL,
    wwwAuthenticateResourceMetadataURL: URL? = nil,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async -> ProtectedResourceMetadata? {
    let urls = buildProtectedResourceMetadataDiscoveryURLs(
        serverURL: serverURL,
        wwwAuthenticateURL: wwwAuthenticateResourceMetadataURL
    )

    for url in urls {
        let result = await fetchProtectedResourceMetadata(url: url, httpClient: httpClient)
        switch result {
            case let .success(metadata):
                return metadata
            case .continueDiscovery:
                continue
            case .stopDiscovery:
                return nil
        }
    }

    return nil
}

/// Builds the ordered list of URLs to try for Protected Resource Metadata discovery.
///
/// - Parameters:
///   - serverURL: The MCP server URL
///   - wwwAuthenticateURL: Optional URL from the `WWW-Authenticate` `resource_metadata` parameter
/// - Returns: Ordered list of discovery URLs to try
public func buildProtectedResourceMetadataDiscoveryURLs(
    serverURL: URL,
    wwwAuthenticateURL: URL? = nil
) -> [URL] {
    var urls: [URL] = []

    // Priority 1: WWW-Authenticate header (validated for safe scheme)
    if let wwwAuthenticateURL, (try? validateEndpointURL(wwwAuthenticateURL)) != nil {
        urls.append(wwwAuthenticateURL)
    }

    guard let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: true) else {
        return urls
    }

    let baseURL = "\(components.scheme ?? "https")://\(components.host ?? "localhost")"
        + (components.port.map { ":\($0)" } ?? "")

    // Priority 2: Path-based well-known URI (if server has a path component)
    let path = components.path
    if !path.isEmpty, path != "/" {
        if let url = URL(string: "\(baseURL)/.well-known/oauth-protected-resource\(path)") {
            urls.append(url)
        }
    }

    // Priority 3: Root-based well-known URI
    if let url = URL(string: "\(baseURL)/.well-known/oauth-protected-resource") {
        urls.append(url)
    }

    return urls
}

/// Result of attempting to fetch PRM from a single URL.
private enum PRMFetchResult {
    /// Metadata was fetched and parsed successfully.
    case success(ProtectedResourceMetadata)
    /// This URL failed with a 4xx error; try the next URL.
    case continueDiscovery
    /// A non-4xx error occurred (e.g., 5xx or network error); stop trying.
    case stopDiscovery
}

/// Fetches and parses Protected Resource Metadata from a single URL.
private func fetchProtectedResourceMetadata(
    url: URL,
    httpClient: HTTPRequestHandler
) async -> PRMFetchResult {
    do {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Version.latest, forHTTPHeaderField: HTTPHeader.protocolVersion)
        let (data, response) = try await httpClient(request)

        if response.statusCode == 200 {
            if let metadata = try? JSONDecoder().decode(
                ProtectedResourceMetadata.self, from: data
            ) {
                return .success(metadata)
            }
            return .continueDiscovery
        } else if response.statusCode >= 400, response.statusCode < 500 {
            return .continueDiscovery
        } else {
            return .stopDiscovery
        }
    } catch {
        return .stopDiscovery
    }
}

// MARK: - Authorization Server Metadata Discovery

/// Discovers Authorization Server Metadata (RFC 8414) with OIDC fallback.
///
/// Tries different well-known URL patterns depending on whether the authorization
/// server URL has a path component:
///
/// **With path** (e.g., `https://auth.example.com/tenant1`):
/// 1. `/.well-known/oauth-authorization-server/tenant1` (RFC 8414)
/// 2. `/.well-known/openid-configuration/tenant1` (OIDC path-aware)
/// 3. `/tenant1/.well-known/openid-configuration` (OIDC legacy)
///
/// **Without path** (e.g., `https://auth.example.com`):
/// 1. `/.well-known/oauth-authorization-server` (RFC 8414)
/// 2. `/.well-known/openid-configuration` (OIDC)
///
/// - Parameters:
///   - authServerURL: The authorization server URL (from PRM or server URL as fallback)
///   - httpClient: HTTP request handler (defaults to URLSession)
/// - Returns: The discovered metadata, or `nil` if discovery failed at all URLs
///
/// - SeeAlso: [RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)
public func discoverAuthorizationServerMetadata(
    authServerURL: URL,
    httpClient: HTTPRequestHandler = defaultHTTPRequestHandler
) async -> OAuthMetadata? {
    let urls = buildAuthorizationServerMetadataDiscoveryURLs(authServerURL: authServerURL)

    for url in urls {
        let result = await fetchAuthorizationServerMetadata(url: url, httpClient: httpClient)
        switch result {
            case let .success(metadata):
                return metadata
            case .continueDiscovery:
                continue
            case .stopDiscovery:
                return nil
        }
    }

    return nil
}

/// Builds the ordered list of URLs to try for Authorization Server Metadata discovery.
///
/// - Parameter authServerURL: The authorization server URL
/// - Returns: Ordered list of discovery URLs to try
public func buildAuthorizationServerMetadataDiscoveryURLs(authServerURL: URL) -> [URL] {
    guard let components = URLComponents(url: authServerURL, resolvingAgainstBaseURL: true) else {
        return []
    }

    let baseURL = "\(components.scheme ?? "https")://\(components.host ?? "localhost")"
        + (components.port.map { ":\($0)" } ?? "")

    var urls: [URL] = []
    let path = components.path

    if !path.isEmpty, path != "/" {
        // Path-aware URLs
        let strippedPath = path.hasSuffix("/") ? String(path.dropLast()) : path

        // RFC 8414: /.well-known/oauth-authorization-server/{path}
        if let url = URL(string: "\(baseURL)/.well-known/oauth-authorization-server\(strippedPath)") {
            urls.append(url)
        }

        // OIDC path-aware: /.well-known/openid-configuration/{path}
        if let url = URL(string: "\(baseURL)/.well-known/openid-configuration\(strippedPath)") {
            urls.append(url)
        }

        // OIDC legacy: /{path}/.well-known/openid-configuration
        if let url = URL(string: "\(baseURL)\(strippedPath)/.well-known/openid-configuration") {
            urls.append(url)
        }
    } else {
        // Root URLs (no path)
        if let url = URL(string: "\(baseURL)/.well-known/oauth-authorization-server") {
            urls.append(url)
        }

        if let url = URL(string: "\(baseURL)/.well-known/openid-configuration") {
            urls.append(url)
        }
    }

    return urls
}

/// Result of attempting to fetch metadata from a single URL.
private enum MetadataFetchResult {
    /// Metadata was fetched and parsed successfully.
    case success(OAuthMetadata)
    /// This URL failed with a 4xx error; try the next URL.
    case continueDiscovery
    /// A non-4xx error occurred (e.g., 5xx or network error); stop trying.
    case stopDiscovery
}

/// Fetches and parses Authorization Server Metadata from a single URL.
private func fetchAuthorizationServerMetadata(
    url: URL,
    httpClient: HTTPRequestHandler
) async -> MetadataFetchResult {
    do {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Version.latest, forHTTPHeaderField: HTTPHeader.protocolVersion)
        let (data, response) = try await httpClient(request)

        if response.statusCode == 200 {
            if let metadata = try? JSONDecoder().decode(OAuthMetadata.self, from: data) {
                return .success(metadata)
            }
            // Valid HTTP 200 but unparseable JSON – treated as a failed attempt
            return .continueDiscovery
        } else if response.statusCode >= 400, response.statusCode < 500 {
            // 4xx – this URL doesn't have metadata, try next
            return .continueDiscovery
        } else {
            // 5xx or other – server error, stop trying
            return .stopDiscovery
        }
    } catch {
        // Network error – stop trying
        return .stopDiscovery
    }
}

// MARK: - Endpoint URL Validation

/// Validates that an OAuth endpoint URL uses a safe scheme (HTTPS, or HTTP
/// for localhost/loopback during development).
///
/// This prevents discovered metadata from injecting URLs with dangerous
/// schemes (e.g., `javascript:`, `data:`) into redirect handlers or HTTP requests.
///
/// - Parameter url: The endpoint URL to validate
/// - Throws: ``OAuthError/discoveryFailed(_:)`` if the scheme is not allowed
func validateEndpointURL(_ url: URL) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
          let scheme = components.scheme?.lowercased()
    else {
        throw OAuthError.discoveryFailed("Invalid endpoint URL: \(url)")
    }

    switch scheme {
        case "https":
            return
        case "http":
            let host = components.host?.lowercased() ?? ""
            if host == "localhost" || host == "127.0.0.1" || host == "::1" {
                return
            }
            throw OAuthError.discoveryFailed(
                "HTTP endpoint URLs are only allowed for localhost: \(url)")
        default:
            throw OAuthError.discoveryFailed(
                "Endpoint URL has disallowed scheme '\(scheme)': \(url)")
    }
}

/// Validates that the AS metadata `issuer` matches the authorization server URL
/// from which the metadata was fetched, per RFC 8414 §3.
///
/// This prevents metadata injection attacks where a redirected or MITM'd response
/// points endpoints to an attacker-controlled server.
///
/// - Parameters:
///   - metadata: The fetched AS metadata
///   - authServerURL: The URL from which the metadata was discovered
/// - Throws: ``OAuthError/discoveryFailed(_:)`` if the issuer does not match
func validateIssuer(_ metadata: OAuthMetadata, authServerURL: URL) throws {
    let issuer = metadata.issuer.absoluteString
    let expected = authServerURL.absoluteString

    // Strip trailing slashes for comparison since servers may vary
    let normalizedIssuer = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
    let normalizedExpected = expected.hasSuffix("/") ? String(expected.dropLast()) : expected

    guard normalizedIssuer == normalizedExpected else {
        throw OAuthError.discoveryFailed(
            "AS metadata issuer \"\(issuer)\" does not match expected \"\(expected)\"")
    }
}

/// Validates key endpoint URLs in authorization server metadata.
///
/// Checks the authorization endpoint, token endpoint, and registration
/// endpoint (if present) for safe URL schemes.
///
/// - Parameter metadata: The AS metadata to validate
/// - Throws: ``OAuthError/discoveryFailed(_:)`` if any endpoint has an unsafe scheme
func validateASMetadataEndpoints(_ metadata: OAuthMetadata) throws {
    try validateEndpointURL(metadata.authorizationEndpoint)
    try validateEndpointURL(metadata.tokenEndpoint)
    if let endpoint = metadata.registrationEndpoint {
        try validateEndpointURL(endpoint)
    }
}
