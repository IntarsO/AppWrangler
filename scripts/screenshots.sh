#!/bin/bash
#
# Neutral screenshots for the README, the manual and the launch: the panel,
# Help and Settings → Impact, showing made-up apps and numbers (debug-build
# demo mode, scripts/demo/fixture.json) — never what's running on your Mac.
# Nothing is measured or enforced, and your own AppWrangler keeps running.
#
#   scripts/screenshots.sh [output-dir]     (default: launch/assets/screens)
#
# Windows appear on screen for ~15 s without taking keyboard focus.
# The widget images come from scripts/render-widget.sh (no windows at all).
#
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-launch/assets/screens}"
./build.sh --debug >/dev/null

WORK="$(mktemp -d -t appwrangler-shots)"
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "$WORK/data" "$WORK/shots" "$OUT"
cp scripts/demo/rules.json "$WORK/data/rules.json"

APPWRANGLER_DATA_DIR="$WORK/data" build/AppWrangler.app/Contents/MacOS/AppWrangler \
	-AWDemoFixture "$PWD/scripts/demo/fixture.json" \
	-AppleLocale en_US -AppleLanguages "(en)" \
	-AWNotifications NO -AWRunawayEnabled NO -AWHotKeyEnabled NO \
	-AWOpenOnLaunch popover -AWDebugSnapshotDir "$WORK/shots" \
	-AWDebugSnapshotHelp YES -AWDebugHelpAnchor auto-mode \
	-AWDebugSnapshotSettings YES -AWDebugSettingsTab 1 &
APP=$!
sleep 15
kill -TERM "$APP" 2>/dev/null || true
wait "$APP" 2>/dev/null || true

sips -Z 760 "$WORK/shots/popover.png" --out "$OUT/panel.png" >/dev/null
sips -Z 1100 "$WORK/shots/help.png" --out "$OUT/help.png" >/dev/null
sips -Z 1100 "$WORK/shots/settings.png" --out "$OUT/impact.png" >/dev/null
scripts/render-widget.sh "$WORK/widget" scripts/demo/widget.json >/dev/null
for f in widget-small widget-medium widget-large; do cp "$WORK/widget/$f-dark.png" "$OUT/$f.png"; done
ls -1 "$OUT"
echo "Rebuild the release app with ./build.sh before installing."
