#!/bin/bash
#
# Record the README demo (about 30 s) and turn it into an MP4 and a GIF (≤ 8 MB).
#
#   scripts/record-demo.sh            # record, then convert
#   scripts/record-demo.sh --convert launch/assets/demo.mov   # convert an existing recording
#
# Follow launch/demo-shot-list.md while it records. The first time, macOS asks to
# allow Screen Recording for your terminal app (System Settings → Privacy & Security).
# Tip: quit apps you don't want on screen (messages, email) before you start.
#
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=launch/assets
mkdir -p "$OUT" build/demo
SECONDS_LONG="${DEMO_SECONDS:-35}"
WIDTH="${GIF_WIDTH:-900}"
FPS="${GIF_FPS:-10}"

if [ "${1:-}" = "--convert" ]; then
	MOV="${2:?usage: --convert file.mov}"
else
	MOV="$OUT/demo.mov"
	echo "Recording the whole screen for $SECONDS_LONG s, with the pointer and clicks."
	echo "Have the shot list open on another screen or printed. Starting in…"
	for i in 5 4 3 2 1; do printf '%s… ' "$i"; sleep 1; done; echo "go!"
	screencapture -v -C -k -x -V "$SECONDS_LONG" "$MOV"
	echo "Recorded $MOV"
fi

swiftc -O scripts/mov-to-media.swift -o build/demo/mov-to-media 2>/dev/null
build/demo/mov-to-media "$MOV" "$OUT/demo.mp4" "$OUT/demo.gif" "$WIDTH" "$FPS" "${TRIM_START:-0}" "${TRIM_END:-0}"

# gifski makes much smaller, better-looking GIFs; use it if it's installed (brew install gifski).
if command -v gifski >/dev/null; then
	rm -rf build/demo/frames && mkdir -p build/demo/frames
	echo "Using gifski for a better GIF…"
	build/demo/mov-to-media "$MOV" build/demo/frames.mp4 build/demo/frames.gif "$WIDTH" "$FPS" "${TRIM_START:-0}" "${TRIM_END:-0}" >/dev/null
	gifski --fps "$FPS" --width "$WIDTH" --quality 85 -o "$OUT/demo.gif" "$OUT/demo.mp4" 2>/dev/null || true
fi

BYTES=$(stat -f%z "$OUT/demo.gif")
echo "demo.gif is $((BYTES / 1024)) KB."
if [ "$BYTES" -gt $((8 * 1024 * 1024)) ]; then
	echo "Over 8 MB: try GIF_WIDTH=760 GIF_FPS=8 scripts/record-demo.sh --convert $MOV, or trim with TRIM_START/TRIM_END (seconds)."
fi
echo "Check it, then: cp $OUT/demo.gif docs/images/ and swap the README demo comment for the GIF (see launch/demo-shot-list.md)."
