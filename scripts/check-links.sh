#!/bin/bash
# Check every external link in the README and docs (relative links between
# docs are covered by the unit tests). Prints only problems.
#   scripts/check-links.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
for url in $(grep -ohE 'https?://[^ )>"`'"'"']+' README.md docs/*.md CHANGELOG.md CONTRIBUTING.md | sed 's/[.,;:]*$//' | sort -u); do
	case "$url" in *localhost*|*example.com*|*'<'*) continue ;; esac
	code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 20 -A 'Mozilla/5.0 (link check)' "$url")
	case "$code" in
		2*|3*) ;;
		403|429) echo "?  $code $url (blocks scripts; check by hand)" ;;
		*) echo "✘  $code $url"; FAIL=1 ;;
	esac
done
[ "$FAIL" = 0 ] && echo "All links OK." || exit 1
