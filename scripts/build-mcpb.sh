#!/bin/bash
#
# Build AppWrangler's MCP server as an MCP bundle (.mcpb) for Claude Desktop
# (double-click to install), the official MCP Registry and Smithery:
#
#   scripts/build-mcpb.sh            # uses VERSION from build.sh (or $VERSION)
#
# Output: build/AppWrangler-mcp-<version>.mcpb and build/server.json (the registry
# entry with the bundle's SHA-256 filled in). Run ./build.sh first, or this
# builds the binary itself. Validated with Anthropic's official mcpb tool when
# Node is available.
#
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(sed -n 's/^VERSION="\${VERSION:-\([0-9.]*\)}".*/\1/p' build.sh)}"
[ -n "$VERSION" ] || { echo "couldn't work out the version" >&2; exit 1; }
ARCHS=(--arch arm64)

swift build -c release "${ARCHS[@]}" 2>&1 | grep -v "ld: warning: search path" | grep -E "error" && exit 1
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/AppWrangler"

STAGE=build/mcpb
rm -rf "$STAGE" && mkdir -p "$STAGE/server"
cp "$BIN" "$STAGE/server/AppWrangler"
sips -Z 256 docs/images/icon.png --out "$STAGE/icon.png" >/dev/null
sed "s/__VERSION__/$VERSION/" Resources/mcpb-manifest.json > "$STAGE/manifest.json"

# The binary carries the app's identity (an embedded Info.plist); sign it standalone.
if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign --force --options runtime --timestamp --identifier io.github.intarso.AppWrangler \
		--sign "$SIGN_IDENTITY" "$STAGE/server/AppWrangler"
else
	codesign --force --sign - --identifier io.github.intarso.AppWrangler "$STAGE/server/AppWrangler"
fi

OUT="build/AppWrangler-mcp-$VERSION.mcpb"
rm -f "$OUT"
if command -v npx >/dev/null; then
	npx -y @anthropic-ai/mcpb@latest validate "$STAGE/manifest.json"
	npx -y @anthropic-ai/mcpb@latest pack "$STAGE" "$OUT"
else
	echo "(npx not found: packing with zip, without validation)"
	(cd "$STAGE" && zip -qr -X "../$(basename "$OUT")" manifest.json icon.png server)
fi

SHA=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/" server.json > build/server.json
echo "Built $OUT"
echo "SHA-256 $SHA"
