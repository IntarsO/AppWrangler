# How AppWrangler works

This is a tour of the internals for curious users and contributors.

## Layout

| Piece | File |
| --- | --- |
| Process sampling, real-time CPU limiter, crash safety (C) | `Sources/ProcKit/ProcKit.c` |
| Groups helpers into apps, computes rates | `Sources/AppWranglerKit/Sampler.swift` |
| Rules, conditions, persistence, file watching, migration | `Sources/AppWranglerKit/Rules.swift` |
| Applies rules (behind a mockable `ProcessController`) | `Sources/AppWranglerKit/Enforcer.swift` |
| Battery / Low Power / thermal / memory-pressure monitor | `Sources/AppWranglerKit/SystemState.swift` |
| Runaway detection, history | `Runaway.swift`, `History.swift` |
| "What is this?" descriptions | `Sources/AppWranglerKit/Catalog.swift` |
| Command line | `Sources/AppWranglerKit/CLI.swift` |
| MCP server (stdio JSON-RPC) for AI assistants | `Sources/AppWranglerKit/MCP.swift` |
| JSON reports shared by CLI and MCP | `Sources/AppWranglerKit/Reports.swift` |
| Impact statistics (savings, cost, accuracy) | `Sources/AppWranglerKit/Stats.swift` |
| Sampling schedule, instant re-apply on any change | `Sources/AppWranglerKit/AppModel.swift` |
| Notifications, login item, global shortcut | `Sources/AppWranglerKit/Services.swift` |
| UI (the menu bar panel in an `NSPopover`, the main window, Settings and Help windows) | `Sources/AppWranglerKit/Views/` |
| `appwrangler://` links (widget buttons, Shortcuts) | `Sources/AppWranglerKit/AppURL.swift` |
| App-wide settings for the CLI and MCP (`prefs`) | `Sources/AppWranglerKit/Preferences.swift` |
| Auto mode (focus, E-cores, fair share, idle-app freezing) | `Sources/AppWranglerKit/AutoPilot.swift` |
| Suggestions, per-app settings, undo journal | `Suggestions.swift`, `AppSettings.swift` |
| `appwrangler mcp install` (Claude / Codex config files) | `Sources/AppWranglerKit/MCPInstaller.swift` |
| In-app Help (Markdown → HTML in a web view) | `Markdown.swift`, `Views/HelpView.swift` |
| Desktop widget (sandboxed WidgetKit extension; reads `widget.json`) | `Widget/AppWranglerWidget.swift` + `WidgetSnapshot.swift` |
| Watchdog helper (restores apps if AppWrangler dies; maps the shared tables from an inherited fd) | `Sources/AppWranglerWatchdog/main.c` → `pk_watchdog_main` |
| Entry point (app or CLI) | `Sources/AppWrangler/main.swift` → `AppWranglerMain.run()` |

Almost everything lives in the `AppWranglerKit` library, so tests can `@testable import` it; the executable is two lines.

## Measuring

`proc_listallpids` lists processes. For each new PID, the sampler caches:
- the executable path and name;
- the parent PID;
- the *responsible* PID: the app macOS considers the owner of an XPC service or helper.

One `proc_pid_rusage` call per process returns CPU time, physical footprint, disk I/O and energy together. On Apple Silicon, task CPU times are in **Mach ticks** (24 MHz, timebase 125/3), not nanoseconds, so everything is converted. The original AppPolice missed this and under-measured about 42×.

**Grouping** (`Grouping.owner`): a process joins an app if the app is responsible for it, or is an ancestor of it, **and** the process ships inside the app's bundle or is an XPC service. So Chrome renderers and Safari's WebContent join their app, while a shell started from Terminal stays separate.

**Adaptive cadence** (`AppModel`):
- Panel open: everything, every second.
- Panel closed: apps with rules or freezes, plus every app (not plain processes) while Auto mode is on, every 2 s; plus a full scan every 5 s if runaway detection is on.
- Nothing to do: no timer at all.

## Enforcing

**CPU limit:** the C limiter duty-cycles a whole process group with `SIGSTOP`/`SIGCONT`.
- Each period (50 ms by default), it measures the group's real CPU use over the real elapsed time.
- It estimates the group's *demand* (its usage while running) and sets the share of the period the group may run to `limit / demand`.
- A slow integral term corrects for signal latency.
- The limiter thread is a Mach **time-constraint (real-time)** thread. When a throttled app saturates every P-core, even top-QoS threads wake about 6 ms late on Apple Silicon, which made a 0.5 ms run slice into 6 ms and low limits overshoot 4×. Measured on an M1 against a multi-threaded load, it holds within about 2%.

**Efficiency cores:** `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` puts the process in the background band: E-cores only, with throttled disk and network I/O. This is undone when the rule goes away.

**Freeze:** a limiter group flagged *frozen* stays stopped, including any newly added helpers. Pausing limits doesn't thaw it.

**The `Enforcer`** works out which groups should be limited, frozen or in efficiency mode for the current snapshot, rules and `SystemState`:
- It only calls the limiter when a group's parameters change, so steady state never interrupts a duty cycle.
- Memory checks only count *new* samples. Re-applying on a focus change doesn't add a strike.
- All side effects go through the `ProcessController` protocol, which tests replace with a fake.

**Instant re-apply:** any of these triggers a pass straight away:
- rule edits from the UI;
- `rules.json` changes (the data folder is watched with a `DispatchSource`; the store ignores its own writes and never overwrites a pending local edit);
- CLI commands, sent as distributed notifications;
- app launch or quit, and focus changes;
- power-source changes (IOKit), Low Power Mode, thermal state, and memory pressure (`DispatchSource.makeMemoryPressureSource`).

## Safety net

The C module keeps a lock-free table of every PID it has stopped. Several things all resume them:
- a handler for `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT` (`SIGTSTP` only resumes paused apps; the limiter carries on after `SIGCONT`);
- the crash signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGTRAP`);
- `atexit`;
- normal termination.

The handler is async-signal-safe: atomics, `kill` and `setpriority` only.

The tables live in an unnamed shared-memory object, shared with a **watchdog**. At launch AppWrangler forks, and the child execs the small `AppWranglerWatchdog` helper, which maps the same tables from the inherited file descriptor and waits on a pipe. It's a separate executable so it has its own process name: `killall AppWrangler` can't take it down too. Development builds without the helper fall back to a plain fork. When AppWrangler dies in any way, including `SIGKILL`, the pipe closes. The watchdog then resumes every stopped pid and restores efficiency-core pids and their children, then exits. Release is terminal: it sets a shutdown flag that the limiter checks before *and after* each stop, so a stop racing with the exit can't leave an app suspended.

Session-critical processes are on a protected list. An `flock` on the data folder ensures one instance.

## Testing

| Suite | What it covers |
|---|---|
| `Tests/AppWranglerKitTests` (Swift Testing, `./test.sh`) | Enforcer logic against a fake controller; rules, precedence, patterns, conditions and schedules; import/merge; migration; grouping; runaway detection; CLI parsing; the catalog; localization coverage; and **real** limiter integration tests on `/usr/bin/yes` burners |
| `Tests/e2e/run.sh` | Runs the built `.app` with an isolated `APPWRANGLER_DATA_DIR` and drives it through the CLI. It checks: on-the-fly rule changes (time to enforcement), new processes picking up rules, pause/freeze interplay, the memory limit, persistence across restart, release on quit and crash, single instance, and overhead |

With only the Command Line Tools, `swift test` can't find the Swift Testing macro plugin; `test.sh` passes its path. Likewise SwiftUI's `@State` macro isn't available, so the views use a small `@Local` property wrapper built on `@StateObject` (`Views/Local.swift`).
