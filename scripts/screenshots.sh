#!/bin/bash
#
# Render README/doc screenshots of the panel and Settings window into docs/images/.
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
	-AWDebugSnapshotDir "$PWD/docs/images" -AWDebugSnapshotSettings YES &
APP=$!
sleep 8
kill -TERM "$APP" 2>/dev/null || true
ls -1 docs/images/popover.png docs/images/settings.png
echo "Rebuild the release app with ./build.sh before installing."
