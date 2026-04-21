#!/bin/bash
# Preview documentation with live reload on http://localhost:8080/documentation/mcp.
#
# Unlike `swift package preview-documentation`, this script loads the symbol
# graphs for every library target so cross-target symbol links (e.g.
# ``/MCPCore/MCPError`` in MCP's articles) resolve correctly. The preview
# plugin only supports a single --target at a time, so we invoke `docc preview`
# directly, passing the parent symbol-graph directory that contains every
# target's extracted graphs.
#
# Currently uses a fork of swift-docc for live-reload support:
# https://github.com/swiftlang/swift-docc/pull/1417
# Once that lands in a Swift toolchain release, swap `$DOCC` for `xcrun docc`
# and drop the swift-docc dependency from Package.swift.
#
# docc preview watches the `.docc` catalog for changes to Markdown files,
# so editing articles reloads automatically. Source (Swift) changes do NOT
# trigger re-extraction of symbol graphs — rerun the script after editing
# doc comments in Swift source.

set -e

cd "$(dirname "$0")/.." || exit 1

CHILD_PID=""

kill_tree() {
    local pid=$1
    local children
    children=$(pgrep -P "$pid" 2>/dev/null) || true
    for child in $children; do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
    trap - EXIT INT TERM HUP
    if [ -n "$CHILD_PID" ]; then
        kill_tree "$CHILD_PID"
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup EXIT INT TERM HUP

# Build the forked docc if needed
DOCC_BUILD_DIR="../swift-docc/.build/debug"
if [ ! -f "$DOCC_BUILD_DIR/docc" ]; then
    echo "Building swift-docc fork..."
    swift build --package-path ../swift-docc --product docc
fi
DOCC="$PWD/$DOCC_BUILD_DIR/docc"

# HTML render templates from the system toolchain
DOCC_HTML_DIR="$(xcrun --find docc | sed 's|/bin/docc$|/share/docc/render|')"

# Extract symbol graphs for every library target by running a combined docs
# build. The archive output is discarded; we only need the side-effect of
# populating .build/.../extracted-symbols/.
echo "Extracting symbol graphs..."
swift package generate-documentation \
    --enable-experimental-combined-documentation \
    --target MCPCore --target MCP --target MCPTool --target MCPPrompt \
    > /dev/null

# Locate the extracted-symbols parent directory.
PACKAGE_NAME=$(swift package dump-package | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
SYMBOL_GRAPH_DIR=$(find .build -type d -path "*/extracted-symbols/$PACKAGE_NAME" -print -quit)
if [ -z "$SYMBOL_GRAPH_DIR" ]; then
    echo "Failed to locate extracted-symbols directory under .build." >&2
    exit 1
fi

CATALOG="Sources/MCP/Documentation.docc"

echo "Starting preview server..."
DOCC_HTML_DIR="$DOCC_HTML_DIR" \
"$DOCC" preview "$CATALOG" \
    --additional-symbol-graph-dir "$SYMBOL_GRAPH_DIR" \
    --fallback-display-name MCP \
    --fallback-bundle-identifier MCP &
CHILD_PID=$!

wait "$CHILD_PID"
