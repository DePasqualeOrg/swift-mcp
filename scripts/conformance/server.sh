#!/bin/bash
set -e

cd "$(dirname "$0")/../../Examples/ConformanceTests"

echo "Building ConformanceServer..."
if ! swift build --product ConformanceServer; then
    echo "Failed to build ConformanceServer"
    exit 1
fi

echo "Starting ConformanceServer on http://localhost:8080/mcp ..."
swift run ConformanceServer &
SERVER_PID=$!

cleanup() {
    echo "Stopping server (PID $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server to be ready by polling health endpoint
echo "Waiting for server to be ready..."
MAX_ATTEMPTS=60
ATTEMPT=0
until curl -sf http://localhost:8080/health > /dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
        echo "Server failed to start after $MAX_ATTEMPTS attempts"
        exit 1
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server process died unexpectedly"
        exit 1
    fi
    sleep 1
done
echo "Server is ready"

echo "Running server conformance tests..."
if npx @modelcontextprotocol/conformance server --url http://localhost:8080/mcp --spec-version 2025-11-25; then
    echo ""
    echo "Server conformance tests: PASSED"
else
    echo ""
    echo "Server conformance tests: FAILED"
    exit 1
fi
