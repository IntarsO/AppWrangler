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
ROOT="$PWD"
APP_BIN="$ROOT/build/AppWrangler.app/Contents/MacOS/AppWrangler"
[ -x "$APP_BIN" ] || ./build.sh >/dev/null

WORK="$(mktemp -d -t appwrangler-e2e)"
export APPWRANGLER_DATA_DIR="$WORK/data"
clang -O2 -w Tests/e2e/burner.c -o "$WORK/e2e-burner"
cp "$WORK/e2e-burner" "$WORK/e2e-memhog"
clang -O2 -w -I Sources/ProcKit/include Sources/ProcKit/ProcKit.c Tests/e2e/cpu.c -o "$WORK/cpu"

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
	"$APP_BIN" -AWNotifications NO -AWRunawayEnabled NO >>"$WORK/app.log" 2>&1 &
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
