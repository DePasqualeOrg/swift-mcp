#!/bin/bash
# Verify documentation builds without warnings

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
