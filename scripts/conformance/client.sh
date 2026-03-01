#!/bin/bash
set -e

cd "$(dirname "$0")/../../Examples/ConformanceTests"

echo "Building ConformanceClient..."
swift build --product ConformanceClient

# Use the pre-built binary directly instead of "swift run" to avoid
# build-graph checks on each of the parallel invocations.
CLIENT_BIN="$(swift build --product ConformanceClient --show-bin-path)/ConformanceClient"

echo "Running all client conformance tests..."
npx @modelcontextprotocol/conformance client \
    --command "$CLIENT_BIN" \
    --suite all \
    --timeout 60000 \
    --expected-failures conformance-baseline.yml
