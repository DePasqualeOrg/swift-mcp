// Copyright © Anthony DePasquale

import Foundation

/// Selects the scope to use for an OAuth authorization request, following
/// the MCP specification's priority order.
///
/// Priority (highest to lowest):
/// 1. `scope` from the `WWW-Authenticate` header (from a 401/403 response)
/// 2. `scopes_supported` from Protected Resource Metadata (RFC 9728)
/// 3. `scopes_supported` from Authorization Server Metadata (RFC 8414)
/// 4. `scope` from the client's own metadata
/// 5. `nil` (omit scope parameter entirely)
///
/// - Parameters:
///   - wwwAuthenticateScope: Scope extracted from a `WWW-Authenticate` header
///   - protectedResourceMetadata: Discovered Protected Resource Metadata
///   - authServerMetadata: Discovered Authorization Server Metadata
///   - clientMetadataScope: Default scope from the client's own metadata
/// - Returns: The selected scope string, or `nil` to omit the scope parameter
public func selectScope(
    wwwAuthenticateScope: String?,
    protectedResourceMetadata: ProtectedResourceMetadata?,
    authServerMetadata: OAuthMetadata?,
    clientMetadataScope: String? = nil
) -> String? {
    if let wwwAuthenticateScope {
        return wwwAuthenticateScope
    }

    if let scopes = protectedResourceMetadata?.scopesSupported, !scopes.isEmpty {
        return scopes.joined(separator: " ")
    }

    if let scopes = authServerMetadata?.scopesSupported, !scopes.isEmpty {
        return scopes.joined(separator: " ")
    }

    if let clientMetadataScope {
        return clientMetadataScope
    }

    return nil
}
