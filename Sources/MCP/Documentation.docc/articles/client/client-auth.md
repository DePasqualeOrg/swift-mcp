# Authentication

Add OAuth 2.0 authentication to MCP client connections

## Overview

MCP supports OAuth 2.0 authorization per the [MCP Authorization Specification](https://modelcontextprotocol.io/specification/draft/basic/authorization). The SDK handles discovery, authorization, token refresh, and 401/403 retry automatically through ``HTTPClientTransport``'s `authProvider` parameter.

Authentication is opt-in – transports work without auth by default.

## Transport Integration

``HTTPClientTransport`` offers two mechanisms for adding authentication:

| Parameter | Use Case |
| --- | --- |
| `authProvider` | Full OAuth 2.0 lifecycle with automatic discovery, token refresh, and 401/403 handling |
| `requestModifier` | Static tokens, API keys, or custom headers |

When both are provided, `authProvider` runs first and sets the `Authorization: Bearer` header, then `requestModifier` runs and can override any headers.

## Authorization Code Flow (Interactive)

``DefaultOAuthProvider`` handles the full OAuth 2.0 authorization code flow with PKCE for applications with a user present – desktop apps, CLI tools, or mobile apps that can open a browser.

```swift
import MCP

let provider = DefaultOAuthProvider(
    serverURL: URL(string: "https://api.example.com/mcp")!,
    clientMetadata: OAuthClientMetadata(
        redirectURIs: [URL(string: "http://127.0.0.1:3000/callback")!],
        clientName: "My MCP Client"
    ),
    storage: InMemoryTokenStorage(),
    redirectHandler: { url in
        // Open the authorization URL in a browser
        await openBrowser(url)
    },
    callbackHandler: {
        // Wait for the OAuth callback and return the authorization code
        try await waitForCallback()
    }
)

let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    authProvider: provider
)

let client = Client(name: "MyApp", version: "1.0.0")
try await client.connect(transport: transport)
```

The provider manages the complete lifecycle automatically:

1. **Discovery**: Fetches Protected Resource Metadata (RFC 9728) and Authorization Server Metadata (RFC 8414)
2. **Client registration**: Registers via CIMD (SEP-991) or Dynamic Client Registration (RFC 7591)
3. **Authorization**: Builds the authorization URL with PKCE, opens it via `redirectHandler`, and waits for the callback
4. **Token exchange**: Exchanges the authorization code for tokens
5. **Token refresh**: Proactively refreshes tokens 60 seconds before expiry
6. **Error recovery**: Invalidates credentials and retries on `invalid_client` or `invalid_grant` errors

## Client Credentials Flow (Machine-to-Machine)

``ClientCredentialsProvider`` is for non-interactive flows where no user is present – background services, CI/CD pipelines, and server-to-server integrations.

```swift
let provider = ClientCredentialsProvider(
    serverURL: URL(string: "https://api.example.com/mcp")!,
    clientId: "background-worker",
    clientSecret: "secret",
    storage: InMemoryTokenStorage(),
    scopes: "tools:read tools:execute"
)

let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    authProvider: provider
)
```

The client authenticates directly with the authorization server using pre-registered credentials. No browser interaction is needed.

## Private Key JWT (Machine-to-Machine)

``PrivateKeyJWTProvider`` authenticates using JWT assertions (RFC 7523) instead of a client secret. This is the recommended method for machine-to-machine flows because no secret is transmitted over the network.

The provider delegates JWT creation to an `assertionProvider` callback, which receives the audience URL and returns a signed JWT. This keeps the SDK dependency-free – use any JWT library (jwt-kit, CryptoKit, etc.):

```swift
let provider = PrivateKeyJWTProvider(
    serverURL: URL(string: "https://api.example.com/mcp")!,
    clientId: "enterprise-client",
    storage: InMemoryTokenStorage(),
    assertionProvider: { audience in
        try signJWT(clientId: "enterprise-client", audience: audience, key: privateKey)
    },
    scopes: "mcp:read mcp:write"
)
```

For workload identity scenarios where the JWT is obtained from a cloud identity provider or secrets manager, use the ``staticAssertionProvider(_:)`` helper:

```swift
let provider = PrivateKeyJWTProvider(
    serverURL: URL(string: "https://api.example.com/mcp")!,
    clientId: "workload-client",
    storage: InMemoryTokenStorage(),
    assertionProvider: staticAssertionProvider(prebuiltJWT)
)
```

The assertion provider should produce a JWT with these claims:

| Claim | Value |
| --- | --- |
| `iss` | The client ID |
| `sub` | The client ID |
| `aud` | The audience URL passed to the callback |
| `exp` | Expiration time (typically 5 minutes from now) |
| `iat` | Issued-at time |
| `jti` | A unique identifier (e.g., UUID) to prevent replay |

## Token Storage

All three providers require a ``TokenStorage`` implementation to persist tokens and client registration information.

### InMemoryTokenStorage

``InMemoryTokenStorage`` stores tokens in memory. Suitable for testing and short-lived processes:

```swift
let storage = InMemoryTokenStorage()
```

### KeychainTokenStorage

``KeychainTokenStorage`` stores tokens securely in the Apple Keychain. Available on Apple platforms only:

```swift
let storage = KeychainTokenStorage(service: "com.myapp.mcp")
```

To share tokens between your app and its extensions, provide an access group:

```swift
let storage = KeychainTokenStorage(
    service: "com.myapp.mcp",
    accessGroup: "TEAMID.com.myapp.shared"
)
```

### Custom Storage

Implement the ``TokenStorage`` protocol for other persistence strategies (e.g., a database, encrypted file, or platform-specific secure storage):

```swift
actor MyTokenStorage: TokenStorage {
    func getTokens() async throws -> OAuthTokens? {
        // Read tokens from your storage
    }

    func setTokens(_ tokens: OAuthTokens) async throws {
        // Write tokens to your storage
    }

    func getClientInfo() async throws -> OAuthClientInformation? {
        // Read client registration info
    }

    func setClientInfo(_ info: OAuthClientInformation) async throws {
        // Write client registration info
    }

    func removeTokens() async throws {
        // Delete stored tokens
    }

    func removeClientInfo() async throws {
        // Delete stored client info
    }
}
```

## Simple Token Authentication

For cases that don't need the full OAuth lifecycle – such as static API keys or pre-obtained tokens – use `requestModifier`:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://api.example.com/mcp")!,
    requestModifier: { request in
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
)
```

Unlike `authProvider`, `requestModifier` does not handle 401/403 responses or token refresh.

## See Also

- <doc:server-auth>
- <doc:client-setup>
- <doc:transports>
- ``OAuthClientProvider``
- ``DefaultOAuthProvider``
- ``ClientCredentialsProvider``
- ``PrivateKeyJWTProvider``
- ``TokenStorage``
- ``InMemoryTokenStorage``
- ``KeychainTokenStorage``
