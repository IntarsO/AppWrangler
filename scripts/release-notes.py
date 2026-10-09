#!/usr/bin/env python3
# Release notes for GitHub: the CHANGELOG section for a version, plus how to
# install it and the zip's checksum.
#   scripts/release-notes.py 1.4.0 build/AppWrangler-1.4.0.zip > notes.md
import hashlib, re, sys

version, zip_path = sys.argv[1], sys.argv[2]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {version}")
body = match.group(1).strip()
sha = hashlib.sha256(open(zip_path, "rb").read()).hexdigest()
zip_name = zip_path.rsplit("/", 1)[-1]

print(f"""{body}

## Install

- **Homebrew:** `brew upgrade --cask appwrangler`. New installs: `brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler && brew install --cask appwrangler`.
- **Download:** get **{zip_name}** below and replace the app in Applications. Your rules and statistics are kept. The first time, **right-click → Open**, because it's signed but not notarized.

- **Claude Desktop:** download **AppWrangler-mcp-{version}.mcpb** below and double-click it to add AppWrangler's tools to Claude. It uses the installed app when there is one ([details](https://github.com/IntarsO/AppWrangler/blob/main/docs/mcp.md#claude-desktop-one-click-bundle)).

**Requirements:** macOS 13 or later, on Apple Silicon (the widget needs macOS 14).

**SHA-256** `{sha}  {zip_name}`

Full history: [CHANGELOG](https://github.com/IntarsO/AppWrangler/blob/main/CHANGELOG.md). AppWrangler is free software under the GNU GPL v2. ☕ [Buy me a coffee](https://buymeacoffee.com/intarsolbit)""")
