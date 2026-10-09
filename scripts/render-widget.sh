#!/bin/bash
# Render the desktop widget's views (small, medium, large; light and dark) to
# PNGs without adding the widget to the desktop. Uses your current widget.json,
# or the file given (scripts/demo/widget.json for docs and launch images).
#   scripts/render-widget.sh [output-dir] [widget.json]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/widget-preview}"
mkdir -p "$OUT" build/widget
swiftc -parse-as-library -D WIDGET_PREVIEW -target arm64-apple-macos14.0 -O \
	Widget/*.swift Sources/AppWranglerKit/WidgetSnapshot.swift scripts/render-widget.swift -o build/widget/render-widget
# RENDER_LOCALE=lv_LV to see it as in another locale (default: US English, for docs).
build/widget/render-widget "$OUT" ${2:+"$2"} -AppleLocale "${RENDER_LOCALE:-en_US}" -AppleLanguages "(${RENDER_LANGUAGE:-en})"
ls "$OUT"
