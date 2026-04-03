#!/bin/bash
# Verify documentation builds without warnings

cd "$(dirname "$0")/.."

TARGETS=$(swift package dump-package | python3 -c "
import json, sys
pkg = json.load(sys.stdin)
for t in pkg['targets']:
    if t['type'] == 'regular':
        print(t['name'])
")

if [ -z "$TARGETS" ]; then
    echo "No targets found."
    exit 1
fi

FAILED=0

while IFS= read -r TARGET; do
    echo "Building documentation for $TARGET..."
    if ! swift package generate-documentation --target "$TARGET" --warnings-as-errors; then
        FAILED=1
    fi
    echo ""
done <<< "$TARGETS"

if [ "$FAILED" -ne 0 ]; then
    echo "Documentation build failed with warnings."
    exit 1
fi

echo "All documentation builds passed."
