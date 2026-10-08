#!/bin/bash
#
# Render the README/manual screenshots into docs/images/: panel.png, help.png
# and the widget (widget-small.png, widget-medium.png).
# Uses the debug build's capture hook (no Screen Recording permission needed) and a
# throwaway data folder with sample rules.
#
# Note: AppWrangler's windows open on your screen for ~8 seconds and may take
# keyboard focus — don't type in other apps while it runs.
#
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh --debug >/dev/null

WORK="$(mktemp -d -t appwrangler-shots)"
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "$WORK/data" docs/images
cat > "$WORK/data/rules.json" <<'JSON'
[
 {"matchKind":"bundleID","matchValue":"com.apple.Safari","displayName":"Safari","cpuLimitEnabled":true,"cpuLimit":150,"onlyWhenInactive":true,"memoryLimitEnabled":true,"memoryLimitMB":4096,"memoryAction":"notify"},
 {"matchKind":"pattern","matchValue":"*Helper*","displayName":"All helpers","backgroundMode":true,"conditions":{"power":"battery"}},
 {"matchKind":"name","matchValue":"photoanalysisd","displayName":"photoanalysisd","pressureAction":"freeze","cpuLimitEnabled":true,"cpuLimit":25}
]
JSON

APPWRANGLER_DATA_DIR="$WORK/data" build/AppWrangler.app/Contents/MacOS/AppWrangler \
	-AWNotifications NO -AWRunawayEnabled NO -AWOpenOnLaunch popover \
	-AWDebugSnapshotDir "$WORK" -AWDebugSnapshotHelp YES -AWDebugHelpAnchor auto-mode &
APP=$!
sleep 9
kill -TERM "$APP" 2>/dev/null || true
sips -Z 760 "$WORK/popover.png" --out docs/images/panel.png >/dev/null
sips -Z 1100 "$WORK/help.png" --out docs/images/help.png >/dev/null

# The widget, rendered from the views directly (uses the current widget.json, or sample data).
scripts/render-widget.sh "$WORK/widget" >/dev/null
cp "$WORK/widget/widget-small-dark.png" docs/images/widget-small.png
cp "$WORK/widget/widget-medium-dark.png" docs/images/widget-medium.png
ls -1 docs/images/panel.png docs/images/help.png docs/images/widget-small.png docs/images/widget-medium.png
echo "Rebuild the release app with ./build.sh before installing."
