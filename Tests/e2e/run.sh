#!/bin/bash
#
# End-to-end test: runs the built AppWrangler.app in an isolated data directory,
# drives it through its CLI and checks real enforcement on real processes —
# including that rule changes apply on the fly, without restarting the app.
#
#   ./Tests/e2e/run.sh        (builds the app first if needed)
#
set -uo pipefail
cd "$(dirname "$0")/../.."
# Measurements assume normal scheduling. If whatever launched us runs on
# efficiency cores (e.g. an AppWrangler E-cores rule on your terminal app), we'd
# inherit that; opt this script and everything it starts out of it.
taskpolicy -B -p $$ 2>/dev/null || true
ROOT="$PWD"
APP_BIN="$ROOT/build/AppWrangler.app/Contents/MacOS/AppWrangler"
[ -x "$APP_BIN" ] || ./build.sh >/dev/null

WORK="$(mktemp -d -t appwrangler-e2e)"
export APPWRANGLER_DATA_DIR="$WORK/data"
clang -O2 -w Tests/e2e/burner.c -o "$WORK/e2e-burner"
cp "$WORK/e2e-burner" "$WORK/e2e-memhog"
clang -O2 -w -I Sources/ProcKit/include Sources/ProcKit/ProcKit.c Tests/e2e/cpu.c -o "$WORK/cpu"

# A real .app (LSUIElement, like a menu bar app) with a helper inside its bundle.
HOG="$WORK/E2EHog.app"
mkdir -p "$HOG/Contents/MacOS" "$HOG/Contents/Helpers"
swiftc -O Tests/e2e/TestApp.swift -o "$HOG/Contents/MacOS/E2EHog" 2>&1 | grep -v "search path" || true
cp "$WORK/e2e-burner" "$HOG/Contents/Helpers/Helper"
cat > "$HOG/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>E2EHog</string>
<key>CFBundleIdentifier</key><string>io.github.intarso.AppWrangler.e2e-hog</string>
<key>CFBundleName</key><string>E2EHog</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$HOG" 2>/dev/null

PASS=0
FAIL=0
PIDS=()
APP=""

cleanup() {
	[ -n "$APP" ] && kill -TERM "$APP" 2>/dev/null
	for p in "${PIDS[@]}"; do kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
	wait 2>/dev/null
	rm -rf "${WORK:?}"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf "  \033[32m✔\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf "  \033[31m✘\033[0m %s\n" "$1"; }
cpu()  { "$WORK/cpu" "$@"; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }
state() { ps -o stat= -p "$1" | cut -c1; }
cli()  { "$APP_BIN" "$@" >/dev/null; }

start_app() {
	# Argument-domain defaults keep the test from prompting for notifications.
	"$APP_BIN" -AWHeadless YES -AWNotifications NO -AWRunawayEnabled NO -AWStatsFlushSeconds 1 -AWAutoEfficiencyAfter 2 -AWAutoScope io.github.intarso.AppWrangler.e2e >>"$WORK/app.log" 2>&1 &
	APP=$!
	for _ in $(seq 50); do [ -f "$APPWRANGLER_DATA_DIR/state.json" ] && return 0; sleep 0.1; done
	return 1
}

spawn() { "$WORK/$1" "${@:2}" & PIDS+=($!); LAST=$!; }

# Wait until the burner's CPU falls under a threshold; prints seconds taken.
time_until_below() {
	local pid=$1 limit=$2 start; start=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
	for i in $(seq 40); do
		if between "$(cpu 0.25 "$pid")" 0 "$limit"; then
			awk -v i="$i" 'BEGIN { printf "%.2f", i * 0.25 }'; return 0
		fi
	done
	echo "timeout"; return 1
}

echo "AppWrangler end-to-end test (data dir: $APPWRANGLER_DATA_DIR)"
pgrep -x AppWrangler >/dev/null && echo "  note: another AppWrangler is running; it uses a different data dir and won't interfere."

start_app && ok "app starts headless and writes its status file" || { bad "app didn't start"; cat "$WORK/app.log"; exit 1; }

"$APP_BIN" -AWNotifications NO >/dev/null 2>&1
[ $? -eq 0 ] && kill -0 "$APP" 2>/dev/null && ok "a second instance refuses to run alongside" || bad "single-instance lock"

# Two busy threads: fits GitHub runners (3 cores) and leaves room for limits of 50% and 150%.
spawn e2e-burner 2
B=$LAST
sleep 0.5
base=$(cpu 1 "$B")
between "$base" 1.6 2.3 && ok "burner runs free: $base cores" || bad "burner baseline $base"

# --- Rules added on the fly ---------------------------------------------------
cli limit e2e-burner 50
t=$(time_until_below "$B" 0.9)
[ "$t" != "timeout" ] && ok "new rule enforced ${t}s after 'appwrangler limit' (no restart)" || bad "limit not applied"
sleep 1.5
v=$(cpu 2 "$B")
between "$v" 0.38 0.62 && ok "holds 50% limit: $v cores" || bad "50% limit measured $v"

sleep 2
saved=$("$APP_BIN" stats today --json | python3 -c 'import json,sys; d=json.load(sys.stdin); a=[x for x in d["apps"] if x["name"]=="e2e-burner"]; print(round(a[0]["savedCPUSeconds"],1) if a else 0, round(a[0]["heldBackSeconds"]) if a else 0, d["self"]["uptimeSeconds"] > 0)')
read sv hb up <<<"$saved"
awk -v s="$sv" 'BEGIN{exit !(s>3)}' && [ "$up" = True ] && ok "impact stats: ${sv} core-s saved while held back ${hb}s (appwrangler stats)" || bad "impact stats not recorded: $saved"

cli limit e2e-burner 150
sleep 2.5
v=$(cpu 2 "$B")
between "$v" 1.3 1.7 && ok "limit changed on the fly to 150%: $v cores" || bad "150% limit measured $v"

spawn e2e-burner 2
B2=$LAST
sleep 3
v=$(cpu 2 "$B2")
between "$v" 1.3 1.7 && ok "newly launched process picked up the rule at once: $v cores" || bad "new process measured $v"
kill -KILL "$B2"; wait "$B2" 2>/dev/null

ov=$(cpu 3 "$APP")
between "$ov" 0 0.03 && ok "AppWrangler overhead while limiting: $(awk -v v="$ov" 'BEGIN{printf "%.1f%%", v*100}') CPU" || bad "overhead $ov"

# --- Pause / freeze -----------------------------------------------------------
# Drop to a low limit first so "limit lifted" is a big, unambiguous jump even
# when the Mac is busy (e.g. the crash reporter from a previous run).
cli limit e2e-burner 30
sleep 2
cli pause
sleep 1
v=$(cpu 1 "$B")
between "$v" 1.0 2.3 && ok "pause lifts CPU limits: $v cores" || bad "pause measured $v"
"$APP_BIN" status | grep -q PAUSED && ok "status reports paused" || bad "status after pause"

cli freeze e2e-burner
sleep 1
v=$(cpu 1 "$B")
between "$v" 0 0.03 && ok "freeze works while paused: $v cores" || bad "freeze while paused measured $v"
cli resume
sleep 1
v=$(cpu 1 "$B")
between "$v" 0 0.03 && ok "resuming limits keeps the app frozen" || bad "frozen app thawed by resume: $v"
cli unfreeze e2e-burner
sleep 2.5
v=$(cpu 2 "$B")
between "$v" 0.2 0.4 && ok "unfreeze restores the 30% rule: $v cores" || bad "after unfreeze measured $v"

# --- Memory -------------------------------------------------------------------
spawn e2e-memhog 0 400
M=$LAST
cli memlimit e2e-memhog 200 freeze
frozen=no
for _ in $(seq 40); do [ "$(state "$M")" = "T" ] && { frozen=yes; break; }; sleep 0.25; done
[ "$frozen" = yes ] && ok "memory limit (400 MB > 200 MB) froze the process" || bad "memory limit didn't freeze"

# --- A real app launched after AppWrangler, matched by bundle ID ------------------
open -g "$HOG" --args 300
hog_main=""; hog_helper=""
for _ in $(seq 40); do
	hog_main=$(pgrep -f "$HOG/Contents/MacOS/E2EHog" | head -1)
	hog_helper=$(pgrep -f "$HOG/Contents/Helpers/Helper" | head -1)
	[ -n "$hog_main" ] && [ -n "$hog_helper" ] && break
	sleep 0.25
done
PIDS+=("$hog_main" "$hog_helper")
"$APP_BIN" list | grep -q "E2EHog +1" && ok "real app is grouped with its in-bundle helper" || bad "E2EHog not grouped with helper"
pri() { ps -o pri= -p "$1" | tr -d ' '; }
on_e=no
for _ in $(seq 40); do [ "$(pri "$hog_main")" = 4 ] && [ "$(pri "$hog_helper")" = 4 ] && { on_e=yes; break; }; sleep 0.25; done
[ "$on_e" = yes ] && ok "Auto mode moved the background app + helper to efficiency cores" || bad "Auto didn't apply E-cores (pri $(pri "$hog_main")/$(pri "$hog_helper"))"
"$APP_BIN" status | grep -q "Auto mode: on" && ok "status reports Auto mode: $("$APP_BIN" status | grep 'Auto mode' | cut -c12-)" || bad "status lacks Auto mode"
cli limit E2EHog 50
sleep 1.5
[ "$(pri "$hog_main")" != 4 ] && ok "a manual rule takes over from Auto (E-cores released: pri $(pri "$hog_main"))" || bad "Auto E-cores kept despite manual rule"
sleep 2
v=$(cpu 2 "$hog_main" "$hog_helper")
between "$v" 0.38 0.62 && ok "bundle-ID rule limits a menu bar app + helper launched later: $v cores" || bad "bundle-ID rule on real app measured $v"
grep -q '"io.github.intarso.AppWrangler.e2e-hog"' "$APPWRANGLER_DATA_DIR/rules.json" && ok "rule stored by bundle ID" || bad "rule not stored by bundle ID"
cli memlimit E2EHog 200 quit
gone=no
for _ in $(seq 40); do kill -0 "$hog_main" 2>/dev/null || { gone=yes; break; }; sleep 0.25; done
[ "$gone" = yes ] && ok "memory limit → Quit closed the real app (helper held 300 MB)" || bad "app not quit by memory limit"
sleep 0.5
kill -0 "$hog_helper" 2>/dev/null && bad "helper left running after quit" || ok "its helper exited with it"

# --- MCP server (what Claude / OpenAI tools talk to) ----------------------------
mcp() {
	printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
		'{"jsonrpc":"2.0","method":"notifications/initialized"}' "$@" | "$APP_BIN" mcp 2>/dev/null
}
reply=$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_cpu_limit","arguments":{"app":"e2e-burner","percent":70}}}')
echo "$reply" | grep -q '"id":2' && ok "MCP server answers over stdio" || bad "no MCP reply: $reply"
sleep 2.5
v=$(cpu 2 "$B")
between "$v" 0.55 0.85 && ok "limit set through MCP is enforced by the running app: $v cores" || bad "MCP limit measured $v"
stats=$(mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_impact_stats","arguments":{"period":"today"}}}')
echo "$stats" | grep '"id":3' | python3 -c 'import json,sys; r=json.loads(sys.stdin.read())["result"]["structuredContent"]; sys.exit(0 if r["savedCPUSeconds"]>0 and r["self"]["uptimeSeconds"]>0 else 1)' \
	&& ok "MCP get_impact_stats reports savings and AppWrangler's own cost" || bad "MCP stats missing"
ro=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$APP_BIN" mcp --read-only 2>/dev/null)
echo "$ro" | grep -q set_cpu_limit && bad "read-only MCP exposes changing tools" || ok "mcp --read-only exposes only audit tools"

# --- Removal, persistence, crash safety -----------------------------------------
cli unlimit e2e-burner
sleep 1.5
v=$(cpu 1 "$B")
between "$v" 1.0 2.3 && ok "removing the rule lifts the limit: $v cores" || bad "after unlimit measured $v"

cli limit e2e-burner 40
sleep 2
kill -TERM "$APP"; wait "$APP" 2>/dev/null; APP=""
sleep 0.5
[ "$(state "$B")" != "T" ] && [ "$(state "$M")" != "T" ] && ok "quitting AppWrangler resumes every process" || bad "processes left stopped after quit"

start_app
sleep 3
v=$(cpu 2 "$B")
between "$v" 0.3 0.5 && ok "rules persist across restart and apply on launch: $v cores" || bad "after restart measured $v"

cli freeze e2e-burner
sleep 1
kill -ABRT "$APP"; wait "$APP" 2>/dev/null; APP=""
sleep 0.5
[ "$(state "$B")" != "T" ] && ok "a crash of AppWrangler still resumes frozen apps" || bad "frozen app left stopped after crash"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
