#!/bin/bash
# Preview documentation with live reload
#
# Currently uses a fork of swift-docc for live reload support:
# https://github.com/swiftlang/swift-docc/pull/1417
#
# Once the PR is merged and included in a Swift toolchain release,
# this script can be simplified to just:
#   swift package --disable-sandbox preview-documentation --target MCP
# and the swift-docc dependency can be removed from Package.swift.

set -e

cd "$(dirname "$0")/.." || exit 1

CHILD_PID=""

# Recursively kill a process and all its descendants
kill_tree() {
    local pid=$1
    # Get children before killing the parent
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

# Use HTML templates from system toolchain
DOCC_HTML_DIR="$(xcrun --find docc | sed 's|/bin/docc$|/share/docc/render|')"

# Run in background so we can track and kill it properly
DOCC_EXEC="$PWD/$DOCC_BUILD_DIR/docc" \
DOCC_HTML_DIR="$DOCC_HTML_DIR" \
swift package --disable-sandbox preview-documentation --target MCP &
CHILD_PID=$!

# Wait for the child process
wait "$CHILD_PID"
