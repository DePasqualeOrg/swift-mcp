# MCP Conformance Tests

Swift implementations of MCP client and server for running against the official [MCP conformance test suite](https://github.com/modelcontextprotocol/conformance).

## Server Tests

Tests the MCP Swift SDK server implementation.

**Start the server:**

```bash
cd Examples/ConformanceTests
swift build
swift run ConformanceServer
```

**In a separate terminal session, run the tests:**

```bash
cd Examples/ConformanceTests
npx @modelcontextprotocol/conformance server --url http://localhost:8080/mcp
```

**Status:** 27/27 passing

## Client Tests

Tests the MCP Swift SDK client implementation.

```bash
cd Examples/ConformanceTests

for scenario in initialize tools_call elicitation-sep1034-client-defaults sse-retry; do
  npx @modelcontextprotocol/conformance client \
    --command "swift run ConformanceClient" \
    --scenario "$scenario"
done
```

**Status:** 10/10 passing (auth scenarios will be tested after OAuth is implemented)

## Test Coverage

### Server (27 tests)
Tools, resources, prompts, completions, logging, SSE streaming, sampling

### Client (10 tests)
| Scenario | Tests | Description |
|----------|-------|-------------|
| initialize | 1 | Basic MCP initialization |
| tools_call | 1 | Tool discovery and invocation |
| elicitation-sep1034-client-defaults | 5 | Bidirectional elicitation with schema defaults |
| sse-retry | 3 | SSE reconnection with Last-Event-ID |

### Not Yet Implemented
- auth/* (17 tests): Requires OAuth support
