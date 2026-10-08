#!/bin/bash
#
# Start a release: ./scripts/release.sh 1.4.0
#
# Turns CHANGELOG.md's "## [Unreleased]" into "## [1.4.0] — <today>", sets the
# default VERSION in build.sh, commits, tags v1.4.0 and pushes. GitHub Actions
# (.github/workflows/release.yml) then tests, builds, publishes the release and
# updates the Homebrew cask.
#
# Pushes as IntarsO when the gh CLI has that account (without switching the
# active account); otherwise with your normal git credentials.
#
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z" >&2; exit 2; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
git rev-parse "v$V" >/dev/null 2>&1 && { echo "v$V already exists" >&2; exit 1; }
grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "CHANGELOG.md has no ## [Unreleased] section" >&2; exit 1; }

sed -i '' "s/^## \[Unreleased\]\$/## [$V] — $(date +%Y-%m-%d)/" CHANGELOG.md
sed -i '' "s/^VERSION=\"\${VERSION:-[0-9.]*}\"/VERSION=\"\${VERSION:-$V}\"/" build.sh
grep -q "VERSION:-$V}" build.sh || { echo "couldn't set VERSION in build.sh" >&2; exit 1; }

git commit -qam "Release $V"
git tag -a "v$V" -m "AppWrangler $V"

if TOKEN=$(gh auth token -u IntarsO 2>/dev/null); then
	GH_TOKEN="$TOKEN" git -c credential.helper= -c "credential.helper=!f() { echo username=IntarsO; echo password=\$GH_TOKEN; }; f" \
		push origin main "v$V"
else
	git push origin main "v$V"
fi
echo "Pushed v$V — follow the build: gh run watch -R IntarsO/AppWrangler"
