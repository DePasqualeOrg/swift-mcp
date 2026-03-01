// Copyright © Anthony DePasquale

import Foundation

// MARK: - Resource URL Handling

/// Utilities for constructing and matching OAuth 2.0 resource indicator URLs (RFC 8707).
///
/// The MCP specification requires that resource URLs are in canonical form and that
/// token audience validation uses hierarchical matching.
///
/// - SeeAlso: [RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707)
public enum ResourceURL {
    /// Converts a URL to canonical form for use as an OAuth resource indicator.
    ///
    /// Canonical form applies these transformations:
    /// - Lowercases the scheme and host
    /// - Removes the fragment component
    /// - Preserves the path (including trailing slash) and query string
    /// - Removes default ports (80 for HTTP, 443 for HTTPS)
    ///
    /// - Parameter url: The URL to canonicalize
    /// - Returns: The canonical URL, or `nil` if the URL cannot be parsed
    public static func canonicalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }

        // Lowercase scheme and host
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // Remove fragment
        components.fragment = nil

        // Remove default ports
        if let port = components.port {
            let isDefaultPort =
                (components.scheme == "http" && port == 80)
                    || (components.scheme == "https" && port == 443)
            if isDefaultPort {
                components.port = nil
            }
        }

        return components.url
    }

    /// Checks whether a requested resource URL matches a configured resource URL
    /// using hierarchical matching.
    ///
    /// Matching rules:
    /// - The scheme, host, and port must be identical (case-insensitive for scheme and host)
    /// - The requested path must start with the configured path (prefix matching)
    ///
    /// This allows a token issued for `https://api.example.com/mcp` to be used
    /// for `https://api.example.com/mcp/v1/tools` but not for `https://api.example.com/other`.
    ///
    /// - Parameters:
    ///   - requested: The resource URL from the incoming request
    ///   - configured: The resource URL this server is configured for
    /// - Returns: `true` if the requested URL matches the configured resource
    public static func matches(requested: URL, configured: URL) -> Bool {
        guard
            let requestedComponents = URLComponents(url: requested, resolvingAgainstBaseURL: true),
            let configuredComponents = URLComponents(url: configured, resolvingAgainstBaseURL: true)
        else {
            return false
        }

        // Scheme must match (case-insensitive)
        guard requestedComponents.scheme?.lowercased() == configuredComponents.scheme?.lowercased()
        else {
            return false
        }

        // Host must match (case-insensitive)
        guard requestedComponents.host?.lowercased() == configuredComponents.host?.lowercased()
        else {
            return false
        }

        // Port must match (normalize nil to default)
        let requestedPort = effectivePort(
            scheme: requestedComponents.scheme, port: requestedComponents.port
        )
        let configuredPort = effectivePort(
            scheme: configuredComponents.scheme, port: configuredComponents.port
        )
        guard requestedPort == configuredPort else {
            return false
        }

        // Path: requested must start with configured path (hierarchical matching).
        // Ensure the configured path ends with "/" so that "/api" doesn't match "/api-evil".
        let configuredPath = configuredComponents.path
        let requestedPath = requestedComponents.path
        let normalizedConfigured =
            configuredPath.hasSuffix("/") ? configuredPath : configuredPath + "/"
        let normalizedRequested = requestedPath.hasSuffix("/") ? requestedPath : requestedPath + "/"
        return normalizedRequested.hasPrefix(normalizedConfigured)
    }

    /// Selects the resource URL to include in authorization and token requests.
    ///
    /// If Protected Resource Metadata was discovered and its `resource` field is a
    /// valid parent of the server URL (per hierarchical matching), use the PRM's
    /// resource. Otherwise, use the canonical form of the server URL.
    ///
    /// - Parameters:
    ///   - serverURL: The MCP server URL
    ///   - protectedResourceMetadata: Discovered PRM, if available
    /// - Returns: The resource URL to use in OAuth requests
    public static func selectResourceURL(
        serverURL: URL,
        protectedResourceMetadata: ProtectedResourceMetadata?
    ) -> URL {
        let canonical = canonicalize(serverURL) ?? serverURL

        if let prmResource = protectedResourceMetadata?.resource {
            // Use PRM's resource if it's a valid parent of the server URL
            if matches(requested: canonical, configured: prmResource) {
                return prmResource
            }
        }

        return canonical
    }

    /// Per the MCP spec (2025-11-25), clients MUST include the `resource`
    /// parameter in authorization, token exchange, and token refresh requests.
    ///
    /// This method always returns `true`. It exists as a named function to
    /// document the spec requirement and to serve as an extension point if
    /// future specs introduce conditions under which it should be omitted.
    public static func shouldIncludeResource(
        protectedResourceMetadata _: ProtectedResourceMetadata?,
        protocolVersion _: String?
    ) -> Bool {
        true
    }

    /// Returns the origin (scheme, host, port) of a URL, stripping the path,
    /// query, and fragment.
    ///
    /// Used for legacy (2025-03-26) authorization server discovery when PRM
    /// is unavailable and the server URL's origin serves as the auth server.
    static func originURL(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Returns the effective port for a URL, substituting defaults for nil.
    private static func effectivePort(scheme: String?, port: Int?) -> Int {
        if let port {
            return port
        }
        switch scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return -1
        }
    }
}
