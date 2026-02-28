// Copyright © Anthony DePasquale

import Foundation

/// Returns an HTTP response containing the Protected Resource Metadata (RFC 9728)
/// for this server.
///
/// Framework integration code should route
/// `GET /.well-known/oauth-protected-resource{/path}` to this function.
/// Use ``protectedResourceMetadataPath(for:)`` to determine the correct route path.
///
/// The response includes `Cache-Control: public, max-age=3600` to allow caching
/// for one hour, matching the Python SDK's behavior.
///
/// ## Example
///
/// ```swift
/// // In Hummingbird/Vapor route handler:
/// func handlePRM(request: FrameworkRequest) async -> FrameworkResponse {
///     let response = protectedResourceMetadataResponse(config: authConfig)
///     return convert(response)
/// }
/// ```
///
/// - Parameter config: Server auth configuration.
/// - Returns: An ``HTTPResponse`` with status 200, JSON body, and caching headers.
public func protectedResourceMetadataResponse(config: ServerAuthConfig) -> HTTPResponse {
    let metadata = ProtectedResourceMetadata(
        resource: config.resource,
        authorizationServers: config.authorizationServers,
        scopesSupported: config.scopesSupported,
        bearerMethodsSupported: ["header"],
        resourceName: config.resourceName,
        resourceDocumentation: config.resourceDocumentation
    )

    let body: Data
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        body = try encoder.encode(metadata)
    } catch {
        return HTTPResponse(statusCode: 500, body: nil)
    }

    return HTTPResponse(
        statusCode: 200,
        headers: [
            HTTPHeader.contentType: "application/json",
            HTTPHeader.cacheControl: "public, max-age=3600",
        ],
        body: body
    )
}

/// Returns the well-known path for the Protected Resource Metadata endpoint
/// given a resource URL.
///
/// Per RFC 9728 §3.1, the path is constructed by inserting
/// `/.well-known/oauth-protected-resource` between the host and the resource path:
/// - `https://example.com/mcp` → `/.well-known/oauth-protected-resource/mcp`
/// - `https://example.com/` → `/.well-known/oauth-protected-resource`
/// - `https://example.com` → `/.well-known/oauth-protected-resource`
///
/// - Parameter resourceURL: The server's resource URL.
/// - Returns: The path component to use when routing the PRM endpoint.
public func protectedResourceMetadataPath(for resourceURL: URL) -> String {
    let path = resourceURL.path
    let resourcePath = (path == "/" || path.isEmpty) ? "" : path
    return "/.well-known/oauth-protected-resource\(resourcePath)"
}

/// Returns the full URL for the Protected Resource Metadata endpoint
/// given a resource URL.
///
/// This is used to populate the `resource_metadata` field in `WWW-Authenticate`
/// response headers.
///
/// - Parameter resourceURL: The server's resource URL.
/// - Returns: The full URL of the PRM endpoint.
public func protectedResourceMetadataURL(for resourceURL: URL) -> URL {
    guard var components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: true) else {
        // Fall back to string manipulation if URLComponents fails
        return resourceURL
    }

    let path = components.path
    let resourcePath = (path == "/" || path.isEmpty) ? "" : path
    components.path = "/.well-known/oauth-protected-resource\(resourcePath)"
    components.query = nil
    components.fragment = nil

    return components.url ?? resourceURL
}
