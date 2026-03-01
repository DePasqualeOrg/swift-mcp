# MCP Conformance Tests

Swift implementations of MCP client and server for running against the official [MCP conformance test suite](https://github.com/modelcontextprotocol/conformance).

## Server Tests

Tests the MCP Swift SDK server implementation (40/40 passing).

```bash
scripts/conformance/server.sh
```

## Client Tests

Tests the MCP Swift SDK client implementation (23/24 scenarios passing, 259/261 checks passing; 1 expected failure in baseline).

```bash
scripts/conformance/client.sh
```

## Test Coverage

### Server (40 checks)
Tools, resources, prompts, completions, logging, SSE streaming, sampling, elicitation, DNS rebinding protection

### Client (24 scenarios)

| Category | Scenarios | Checks |
|----------|-----------|--------|
| Core | initialize, tools_call | 2 |
| Elicitation | elicitation-sep1034-client-defaults | 5 |
| SSE | sse-retry | 3 |
| Auth: Metadata | auth/metadata-{default,var1,var2,var3} | 52 |
| Auth: CIMD | auth/basic-cimd | 13 |
| Auth: Scopes | auth/scope-{www-authenticate,scopes-supported,omitted,step-up,retry-limit} | 72 |
| Auth: Token Auth | auth/token-endpoint-auth-{basic,post,none} | 54 |
| Auth: Pre-reg | auth/pre-registration | 13 |
| Auth: Resource | auth/resource-mismatch | 2 |
| Auth: Backcompat | auth/2025-03-26-oauth-{endpoint-fallback,metadata-backcompat} | 19 |
| Auth: M2M | auth/client-credentials-{jwt,basic} | 16 |

### Expected Failures

Listed in `conformance-baseline.yml`:

- `auth/cross-app-access-complete-flow` – Requires RFC 8693 token exchange (not yet implemented)
