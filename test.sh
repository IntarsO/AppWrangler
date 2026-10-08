#!/bin/bash
#
# Run the test suite with only the Command Line Tools.
#
#   ./test.sh                 all unit + limiter integration tests
#   ./test.sh --filter Rules  only matching tests
#
# The CLT ship Swift Testing but don't auto-load its macro plugin, so point the
# compiler at it explicitly (full Xcode doesn't need this; we skip it there).
set -euo pipefail
cd "$(dirname "$0")"

EXTRA=()
DEV="$(xcode-select -p 2>/dev/null || true)"
PLUGIN="$DEV/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$DEV" == *CommandLineTools* && -f "$PLUGIN" ]]; then
	EXTRA=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi

swift test "${EXTRA[@]}" "$@" 2>&1 | grep -v "ld: warning: search path"
exit "${PIPESTATUS[0]}"
