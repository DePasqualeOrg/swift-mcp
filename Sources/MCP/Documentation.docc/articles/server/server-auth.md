# Authentication

Protect MCP servers with OAuth 2.0 token validation

## Overview

MCP supports OAuth 2.0 authorization per the [MCP Authorization Specification](https://modelcontextprotocol.io/specification/draft/basic/authorization). On the server side, the SDK validates incoming bearer tokens and serves Protected Resource Metadata. The application provides a ``TokenVerifier`` to decide how tokens are validated.

Authentication is opt-in – servers work without auth by default.

## Configuration

``ServerAuthConfig`` defines the server's OAuth-protected resource identity:

```swift
let authConfig = ServerAuthConfig(
    resource: URL(string: "https://api.example.com/mcp")!,
    authorizationServers: [URL(string: "https://auth.example.com")!],
    tokenVerifier: MyTokenVerifier(),
    scopesSupported: ["tools:read", "tools:execute"],
    resourceName: "My MCP Server"
)
```

- `resource`: This server's canonical URL, used for audience validation
- `authorizationServers`: Authorization servers that can issue tokens for this resource
- `tokenVerifier`: Your application-provided token validator
- `scopesSupported`: Scopes this resource supports (included in metadata and 401 responses)

## Token Validation

Implement the ``TokenVerifier`` protocol to define how your server validates bearer tokens. The SDK extracts the token from the `Authorization` header and delegates validation to your implementation. It then checks expiration and audience (RFC 8707) separately.

```swift
struct MyTokenVerifier: TokenVerifier {
    func verifyToken(_ token: String) async -> AuthInfo? {
        // Validate the token using your preferred strategy:
        // - JWT verification (decode and check signature)
        // - Token introspection (call the authorization server)
        // - Database lookup
        guard let record = await tokenStore.find(token) else {
            return nil  // Invalid or unrecognized token
        }
        return AuthInfo(
            token: token,
            clientId: record.clientId,
            scopes: record.scopes,
            expiresAt: record.expiresAt,
            resource: record.resource
        )
    }
}
```

Return `nil` for invalid tokens. The SDK handles the 401 response.

## Authenticating Requests

Use ``authenticateRequest(_:config:)`` in your HTTP framework's route handler to validate incoming requests before passing them to the MCP transport:

```swift
// In your HTTP framework handler:
func handleMCPRequest(_ httpRequest: MCP.HTTPRequest) async -> MCP.HTTPResponse {
    let result = await authenticateRequest(httpRequest, config: authConfig)
    switch result {
        case .authenticated(let authInfo):
            // Pass authInfo to the transport so handlers can access it
            return await transport.handleRequest(httpRequest, authInfo: authInfo)
        case .unauthorized(let errorResponse):
            // Return the 401 response with WWW-Authenticate header
            return errorResponse
    }
}
```

## Protected Resource Metadata Endpoint

Clients discover your server's authorization requirements through the Protected Resource Metadata endpoint (RFC 9728). Route `GET /.well-known/oauth-protected-resource{/path}` to ``protectedResourceMetadataResponse(config:)``:

```swift
// Determine the route path for your resource URL
let prmPath = protectedResourceMetadataPath(for: authConfig.resource)
// e.g., "/.well-known/oauth-protected-resource/mcp"

// In your HTTP framework:
router.get(prmPath) { _ in
    protectedResourceMetadataResponse(config: authConfig)
}
```

## Scope Enforcement

For endpoints that require specific scopes, check the scopes in ``AuthInfo`` and return a 403 response using ``insufficientScopeResponse(scope:description:config:)``:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    if let authInfo = context.authInfo {
        if !authInfo.scopes.contains("tools:execute") {
            // The client's auth provider will automatically
            // re-authorize with the required scope
            throw insufficientScopeResponse(
                scope: "tools:execute",
                description: "Tool execution requires the tools:execute scope",
                config: authConfig
            )
        }
    }
    // Handle the request...
    return CallTool.Result(content: [.text("Done")])
}
```

When a client with an `authProvider` receives a 403 with a `WWW-Authenticate` header, it automatically re-authorizes with the required scope and retries the request.

## Accessing Auth Info in Handlers

When the server is configured with authentication, request handlers can access the validated ``AuthInfo`` through the context:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    if let authInfo = context.authInfo {
        print("Client: \(authInfo.clientId)")
        print("Scopes: \(authInfo.scopes)")
    }
    return CallTool.Result(content: [.text("Done")])
}
```

## See Also

- <doc:client-auth>
- <doc:server-setup>
- <doc:server-advanced>
- <doc:transports>
- ``ServerAuthConfig``
- ``TokenVerifier``
- ``AuthInfo``
- ``AuthenticationResult``
