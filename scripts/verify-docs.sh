#!/bin/bash
# Verify documentation builds without warnings.
#
# Uses a `docc` binary built from swift-docc's main branch (pulled via
# Package.swift) rather than Apple's toolchain `xcrun docc`. This is a
# workaround for swift-docc issue #1257 / fix PR #1327 (merged 2025-11-12):
# in combined-documentation mode, absolute cross-target symbol links like
# ``/MCPCore/MCPError`` are mis-resolved as relative paths when the package
# contains public extensions of dependency-module types. The fix is on
# swift-docc main but has not shipped in a released Xcode toolchain yet.
#
# TODO: once Apple ships a Swift-DocC release containing PR #1327, drop the
# build step below and the DOCC_EXEC / DOCC_HTML_DIR overrides — the plugin
# will use the toolchain docc by default.

set -e
cd "$(dirname "$0")/.."

# Discover library product targets from Package.swift, skipping test/macro/executable targets
TARGETS=$(swift package dump-package | python3 -c "
import json, sys
pkg = json.load(sys.stdin)
targets = set()
for p in pkg['products']:
    if p['type'].get('library') is not None:
        targets.update(p['targets'])
for t in sorted(targets):
    print(t)
")

if [ -z "$TARGETS" ]; then
    echo "No targets found."
    exit 1
fi

# Build docc from the swift-docc main-branch checkout pulled via Package.swift.
swift package resolve > /dev/null
SWIFT_DOCC_DIR=$(find .build/checkouts -maxdepth 1 -type d -name swift-docc -print -quit)
if [ -z "$SWIFT_DOCC_DIR" ]; then
    echo "Failed to locate swift-docc checkout under .build/checkouts/." >&2
    exit 1
fi

DOCC_BIN="$SWIFT_DOCC_DIR/.build/debug/docc"
if [ ! -x "$DOCC_BIN" ]; then
    echo "Building docc from $SWIFT_DOCC_DIR..."
    swift build --package-path "$SWIFT_DOCC_DIR" --product docc
fi

# Locate the HTML render templates shipped with the toolchain's docc so the
# built docc can emit a static-host-compatible archive without warnings.
export DOCC_EXEC="$DOCC_BIN"
export DOCC_HTML_DIR="$(xcrun --find docc | sed 's|/bin/docc$|/share/docc/render|')"

# Build all library targets together with combined documentation so that
# articles can use absolute symbol links (e.g. ``/MCPCore/MCPError``) to
# reference symbols in sibling targets.
TARGET_ARGS=()
while IFS= read -r TARGET; do
    TARGET_ARGS+=(--target "$TARGET")
done <<< "$TARGETS"

echo "Building combined documentation for: $(echo "$TARGETS" | tr '\n' ' ')"
if ! swift package generate-documentation \
    --enable-experimental-combined-documentation \
    "${TARGET_ARGS[@]}" \
    --warnings-as-errors; then
    echo "Documentation build failed with warnings."
    exit 1
fi

echo "All documentation builds passed."
