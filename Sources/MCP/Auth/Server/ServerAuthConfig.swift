// Copyright © Anthony DePasquale

import Foundation

/// Configuration for an MCP server's OAuth-protected resource identity.
///
/// This struct provides everything the server auth middleware needs to:
/// - Validate bearer tokens via the application-provided ``tokenVerifier``
/// - Check token audience against this server's ``resource`` URL
/// - Serve Protected Resource Metadata (RFC 9728) at the well-known endpoint
/// - Include `resource_metadata` URLs in `WWW-Authenticate` response headers
///
/// ## Example
///
/// ```swift
/// let authConfig = ServerAuthConfig(
///     resource: URL(string: "https://api.example.com/mcp")!,
///     authorizationServers: [URL(string: "https://auth.example.com")!],
///     tokenVerifier: MyTokenVerifier()
/// )
/// ```
///
/// - SeeAlso: ``TokenVerifier``, ``authenticateRequest(_:config:)``
public struct ServerAuthConfig: Sendable {
    /// This server's canonical resource URL, used for audience validation and
    /// as the `resource` field in Protected Resource Metadata.
    public let resource: URL

    /// Authorization server URLs that can issue tokens for this resource.
    /// Included in the Protected Resource Metadata `authorization_servers` field.
    public let authorizationServers: [URL]

    /// Application-provided token validator.
    public let tokenVerifier: any TokenVerifier

    /// Scopes this resource supports (optional, included in PRM if set).
    public let scopesSupported: [String]?

    /// Human-readable name for this resource (optional, included in PRM if set).
    public let resourceName: String?

    /// Documentation URL for this resource (optional, included in PRM if set).
    public let resourceDocumentation: URL?

    public init(
        resource: URL,
        authorizationServers: [URL],
        tokenVerifier: any TokenVerifier,
        scopesSupported: [String]? = nil,
        resourceName: String? = nil,
        resourceDocumentation: URL? = nil
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.tokenVerifier = tokenVerifier
        self.scopesSupported = scopesSupported
        self.resourceName = resourceName
        self.resourceDocumentation = resourceDocumentation
    }
}
