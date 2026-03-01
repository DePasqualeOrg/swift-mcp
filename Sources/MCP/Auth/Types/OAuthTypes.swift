// Copyright © Anthony DePasquale

import Foundation

// MARK: - Authorization Server Metadata

/// OAuth 2.0 Authorization Server Metadata (RFC 8414).
///
/// Describes the configuration of an OAuth 2.0 authorization server, including
/// its endpoints, supported grant types, and capabilities.
///
/// - SeeAlso: [RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)
public struct OAuthMetadata: Codable, Sendable, Equatable {
    /// The authorization server's issuer identifier URL.
    public let issuer: URL

    /// URL of the authorization endpoint.
    public let authorizationEndpoint: URL

    /// URL of the token endpoint.
    public let tokenEndpoint: URL

    /// URL of the dynamic client registration endpoint (RFC 7591).
    public let registrationEndpoint: URL?

    /// List of scopes this authorization server supports.
    public let scopesSupported: [String]?

    /// Response types the server supports (e.g., `["code"]`).
    public let responseTypesSupported: [String]?

    /// Grant types the server supports (e.g., `["authorization_code", "refresh_token"]`).
    public let grantTypesSupported: [String]?

    /// PKCE code challenge methods the server supports (e.g., `["S256"]`).
    public let codeChallengeMethodsSupported: [String]?

    /// Token endpoint authentication methods the server supports.
    public let tokenEndpointAuthMethodsSupported: [String]?

    /// URL of the token revocation endpoint (RFC 7009).
    public let revocationEndpoint: URL?

    /// Authentication methods supported by the revocation endpoint.
    public let revocationEndpointAuthMethodsSupported: [String]?

    /// URL of the token introspection endpoint.
    public let introspectionEndpoint: URL?

    /// Authentication methods supported by the introspection endpoint.
    public let introspectionEndpointAuthMethodsSupported: [String]?

    /// Whether the server supports Client ID Metadata Documents (SEP-991).
    public let clientIdMetadataDocumentSupported: Bool?

    /// URL of the service documentation.
    public let serviceDocumentation: URL?

    public init(
        issuer: URL,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        scopesSupported: [String]? = nil,
        responseTypesSupported: [String]? = nil,
        grantTypesSupported: [String]? = nil,
        codeChallengeMethodsSupported: [String]? = nil,
        tokenEndpointAuthMethodsSupported: [String]? = nil,
        revocationEndpoint: URL? = nil,
        revocationEndpointAuthMethodsSupported: [String]? = nil,
        introspectionEndpoint: URL? = nil,
        introspectionEndpointAuthMethodsSupported: [String]? = nil,
        clientIdMetadataDocumentSupported: Bool? = nil,
        serviceDocumentation: URL? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopesSupported = scopesSupported
        self.responseTypesSupported = responseTypesSupported
        self.grantTypesSupported = grantTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
        self.revocationEndpoint = revocationEndpoint
        self.revocationEndpointAuthMethodsSupported = revocationEndpointAuthMethodsSupported
        self.introspectionEndpoint = introspectionEndpoint
        self.introspectionEndpointAuthMethodsSupported = introspectionEndpointAuthMethodsSupported
        self.clientIdMetadataDocumentSupported = clientIdMetadataDocumentSupported
        self.serviceDocumentation = serviceDocumentation
    }

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case revocationEndpoint = "revocation_endpoint"
        case revocationEndpointAuthMethodsSupported = "revocation_endpoint_auth_methods_supported"
        case introspectionEndpoint = "introspection_endpoint"
        case introspectionEndpointAuthMethodsSupported = "introspection_endpoint_auth_methods_supported"
        case clientIdMetadataDocumentSupported = "client_id_metadata_document_supported"
        case serviceDocumentation = "service_documentation"
    }
}

// MARK: - Protected Resource Metadata

/// OAuth 2.0 Protected Resource Metadata (RFC 9728).
///
/// Describes the authorization requirements of an OAuth 2.0 protected resource,
/// including which authorization servers can issue tokens for it.
///
/// - SeeAlso: [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)
public struct ProtectedResourceMetadata: Codable, Sendable, Equatable {
    /// The protected resource's identifier URL.
    public let resource: URL

    /// Authorization server URLs that can issue tokens for this resource.
    ///
    /// The MCP spec requires this field and the Python SDK enforces it, but the
    /// TypeScript SDK treats it as optional. We keep it optional here so that
    /// clients can tolerate non-compliant servers; callers should validate that
    /// at least one entry is present when using the metadata for discovery.
    public let authorizationServers: [URL]?

    /// Scopes this resource supports.
    public let scopesSupported: [String]?

    /// Bearer token delivery methods the resource supports.
    /// MCP only supports the `"header"` method.
    public let bearerMethodsSupported: [String]?

    /// Human-readable name for the resource.
    public let resourceName: String?

    /// URL of the resource's documentation.
    public let resourceDocumentation: URL?

    /// URL of the resource's JSON Web Key Set.
    public let jwksURI: URL?

    /// JWS algorithms supported for resource-level signing.
    public let resourceSigningAlgValuesSupported: [String]?

    /// URL of the resource's policy.
    public let resourcePolicyURI: URL?

    /// URL of the resource's terms of service.
    public let resourceTosURI: URL?

    /// Whether the resource requires TLS client certificate-bound access tokens.
    public let tlsClientCertificateBoundAccessTokens: Bool?

    /// Authorization detail types the resource supports.
    public let authorizationDetailsTypesSupported: [String]?

    /// DPoP signing algorithms the resource supports.
    public let dpopSigningAlgValuesSupported: [String]?

    /// Whether the resource requires DPoP-bound access tokens.
    public let dpopBoundAccessTokensRequired: Bool?

    public init(
        resource: URL,
        authorizationServers: [URL]? = nil,
        scopesSupported: [String]? = nil,
        bearerMethodsSupported: [String]? = ["header"],
        resourceName: String? = nil,
        resourceDocumentation: URL? = nil,
        jwksURI: URL? = nil,
        resourceSigningAlgValuesSupported: [String]? = nil,
        resourcePolicyURI: URL? = nil,
        resourceTosURI: URL? = nil,
        tlsClientCertificateBoundAccessTokens: Bool? = nil,
        authorizationDetailsTypesSupported: [String]? = nil,
        dpopSigningAlgValuesSupported: [String]? = nil,
        dpopBoundAccessTokensRequired: Bool? = nil
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
        self.bearerMethodsSupported = bearerMethodsSupported
        self.resourceName = resourceName
        self.resourceDocumentation = resourceDocumentation
        self.jwksURI = jwksURI
        self.resourceSigningAlgValuesSupported = resourceSigningAlgValuesSupported
        self.resourcePolicyURI = resourcePolicyURI
        self.resourceTosURI = resourceTosURI
        self.tlsClientCertificateBoundAccessTokens = tlsClientCertificateBoundAccessTokens
        self.authorizationDetailsTypesSupported = authorizationDetailsTypesSupported
        self.dpopSigningAlgValuesSupported = dpopSigningAlgValuesSupported
        self.dpopBoundAccessTokensRequired = dpopBoundAccessTokensRequired
    }

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case bearerMethodsSupported = "bearer_methods_supported"
        case resourceName = "resource_name"
        case resourceDocumentation = "resource_documentation"
        case jwksURI = "jwks_uri"
        case resourceSigningAlgValuesSupported = "resource_signing_alg_values_supported"
        case resourcePolicyURI = "resource_policy_uri"
        case resourceTosURI = "resource_tos_uri"
        case tlsClientCertificateBoundAccessTokens = "tls_client_certificate_bound_access_tokens"
        case authorizationDetailsTypesSupported = "authorization_details_types_supported"
        case dpopSigningAlgValuesSupported = "dpop_signing_alg_values_supported"
        case dpopBoundAccessTokensRequired = "dpop_bound_access_tokens_required"
    }
}

// MARK: - Client Metadata

/// OAuth 2.0 Dynamic Client Registration Metadata (RFC 7591).
///
/// Describes the metadata a client provides when registering with an authorization server.
///
/// - SeeAlso: [RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)
public struct OAuthClientMetadata: Codable, Sendable, Equatable {
    /// Redirect URIs for the authorization code flow.
    public let redirectURIs: [URL]?

    /// Authentication method for the token endpoint.
    /// One of `"none"`, `"client_secret_basic"`, `"client_secret_post"`, or `"private_key_jwt"`.
    public let tokenEndpointAuthMethod: String?

    /// Grant types the client will use (e.g., `["authorization_code", "refresh_token"]`).
    public let grantTypes: [String]?

    /// Response types the client will use (e.g., `["code"]`).
    public let responseTypes: [String]?

    /// Scope the client is requesting.
    public let scope: String?

    /// Human-readable name for the client.
    public let clientName: String?

    /// URL of the client's home page.
    public let clientURI: URL?

    /// URL of the client's logo image.
    public let logoURI: URL?

    /// Contact information for the client (e.g., email addresses).
    public let contacts: [String]?

    /// URL of the client's terms of service.
    public let tosURI: URL?

    /// URL of the client's privacy policy.
    public let policyURI: URL?

    /// URL of the client's JSON Web Key Set.
    public let jwksURI: URL?

    /// The client's JSON Web Key Set (inline).
    public let jwks: Value?

    /// Identifier for the client software.
    public let softwareId: String?

    /// Version of the client software.
    public let softwareVersion: String?

    /// A software statement (a signed JWT) containing client metadata.
    public let softwareStatement: String?

    public init(
        redirectURIs: [URL]? = nil,
        tokenEndpointAuthMethod: String? = nil,
        grantTypes: [String]? = ["authorization_code", "refresh_token"],
        responseTypes: [String]? = ["code"],
        scope: String? = nil,
        clientName: String? = nil,
        clientURI: URL? = nil,
        logoURI: URL? = nil,
        contacts: [String]? = nil,
        tosURI: URL? = nil,
        policyURI: URL? = nil,
        jwksURI: URL? = nil,
        jwks: Value? = nil,
        softwareId: String? = nil,
        softwareVersion: String? = nil,
        softwareStatement: String? = nil
    ) {
        self.redirectURIs = redirectURIs
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.scope = scope
        self.clientName = clientName
        self.clientURI = clientURI
        self.logoURI = logoURI
        self.contacts = contacts
        self.tosURI = tosURI
        self.policyURI = policyURI
        self.jwksURI = jwksURI
        self.jwks = jwks
        self.softwareId = softwareId
        self.softwareVersion = softwareVersion
        self.softwareStatement = softwareStatement
    }

    private enum CodingKeys: String, CodingKey {
        case redirectURIs = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case scope
        case clientName = "client_name"
        case clientURI = "client_uri"
        case logoURI = "logo_uri"
        case contacts
        case tosURI = "tos_uri"
        case policyURI = "policy_uri"
        case jwksURI = "jwks_uri"
        case jwks
        case softwareId = "software_id"
        case softwareVersion = "software_version"
        case softwareStatement = "software_statement"
    }
}

// MARK: - Client Information

/// OAuth 2.0 Dynamic Client Registration Response (RFC 7591).
///
/// Contains the client credentials assigned by the authorization server
/// in response to a registration request.
///
/// - SeeAlso: [RFC 7591 §3.2.1](https://datatracker.ietf.org/doc/html/rfc7591#section-3.2.1)
public struct OAuthClientInformation: Codable, Sendable, Equatable {
    /// The client identifier assigned by the server.
    public let clientId: String

    /// The client secret, if the client is confidential.
    public let clientSecret: String?

    /// Unix timestamp of when the client ID was issued.
    public let clientIdIssuedAt: Int?

    /// Unix timestamp of when the client secret expires (0 means it won't expire).
    public let clientSecretExpiresAt: Int?

    public init(
        clientId: String,
        clientSecret: String? = nil,
        clientIdIssuedAt: Int? = nil,
        clientSecretExpiresAt: Int? = nil
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.clientIdIssuedAt = clientIdIssuedAt
        self.clientSecretExpiresAt = clientSecretExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case clientIdIssuedAt = "client_id_issued_at"
        case clientSecretExpiresAt = "client_secret_expires_at"
    }
}

// MARK: - Token Error Response

/// OAuth 2.0 Token Error Response (RFC 6749 §5.2).
///
/// Returned by the token endpoint when a request fails.
///
/// - SeeAlso: [RFC 6749 §5.2](https://datatracker.ietf.org/doc/html/rfc6749#section-5.2)
public struct OAuthTokenErrorResponse: Codable, Sendable, Equatable {
    /// The error code (e.g., `"invalid_grant"`, `"invalid_client"`).
    public let error: String

    /// Human-readable description of the error.
    public let errorDescription: String?

    /// URI identifying a web page with error information.
    public let errorURI: String?

    public init(error: String, errorDescription: String? = nil, errorURI: String? = nil) {
        self.error = error
        self.errorDescription = errorDescription
        self.errorURI = errorURI
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
    }
}
