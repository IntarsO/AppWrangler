#!/bin/bash
# Render the 1280×640 social preview (GitHub → Settings → Social preview) to
# launch/assets/social-preview.png, using neutral demo data for the widget.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-launch/assets/social-preview.png}"
mkdir -p "$(dirname "$OUT")" build/widget build/social
scripts/render-widget.sh build/social/widget scripts/demo/widget.json >/dev/null
swiftc -parse-as-library -O scripts/render-social.swift -o build/social/render-social
build/social/render-social docs/images/icon.png build/social/widget/widget-large-dark.png "$OUT"
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2
