#!/bin/bash
# Render the desktop widget's views (small, medium; light and dark) to PNGs
# using the current widget.json, without adding the widget to the desktop.
#   scripts/render-widget.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/widget-preview}"
mkdir -p "$OUT" build/widget
swiftc -parse-as-library -D WIDGET_PREVIEW -target arm64-apple-macos14.0 -O \
	Widget/*.swift Sources/AppWranglerKit/WidgetSnapshot.swift scripts/render-widget.swift -o build/widget/render-widget
build/widget/render-widget "$OUT"
ls "$OUT"
