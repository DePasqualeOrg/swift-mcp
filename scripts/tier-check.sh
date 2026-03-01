#!/bin/bash
set -euo pipefail

REPO="DePasqualeOrg/swift-mcp"
PORT="8080"
OUTPUT="terminal"
DAYS=""
BRANCH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo) REPO="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$(dirname "$0")/../Examples/ConformanceTests"

echo "Building conformance server and client..."
swift build --product ConformanceServer --product ConformanceClient

CLIENT_BIN="$(swift build --product ConformanceClient --show-bin-path)/ConformanceClient"

echo "Starting ConformanceServer on http://localhost:${PORT}/mcp ..."
swift run ConformanceServer --port "$PORT" &
SERVER_PID=$!

cleanup() {
    echo "Stopping server (PID $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Waiting for server to be ready..."
MAX_ATTEMPTS=60
ATTEMPT=0
until curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; do
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

echo "Running tier-check..."
npx @modelcontextprotocol/conformance tier-check \
    --repo "$REPO" \
    --conformance-server-url "http://localhost:${PORT}/mcp" \
    --client-cmd "$CLIENT_BIN" \
    ${DAYS:+--days "$DAYS"} \
    ${BRANCH:+--branch "$BRANCH"} \
    --output "$OUTPUT"
