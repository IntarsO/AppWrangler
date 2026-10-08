# Changelog

All notable changes to AppWrangler are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-10-08

The first release of AppWrangler: a ground-up rewrite of [AppPolice](https://github.com/fuyu/AppPolice) 1.1 for Apple Silicon, under a new name.

### Added
- **Every running app and process**, grouped into Apps, Menu bar & background apps, macOS system services and Processes, with a plain-language description, vendor and "safe to limit?" note for each.
- **Helpers are counted with their app** (Chrome/Electron renderers, Safari WebContent, XPC services), for display and for limits.
- **CPU limit** per app from 1% to 100% × cores, optionally only while the app is in the background. It uses a real-time duty-cycle limiter accurate to about 2%.
- **Efficiency cores only** (Darwin background policy: E-cores plus throttled disk/network I/O).
- **Memory limit** with notify / freeze / quit / force-quit actions, triggered on sustained use.
- **Low-memory protection:** freeze or quit chosen apps under system memory pressure, and resume them when it eases.
- **Conditional rules:** on battery or charger, Low Power Mode, when hot, scheduled hours and days (including overnight windows).
- **Runaway alerts** with *Limit to 50%* / *Efficiency cores* / *Ignore* actions, in the panel and as notifications.
- **Freeze / Unfreeze / Quit / Force Quit** for any app. A freeze survives "pause all limits".
- **Instant enforcement** of rule changes from the UI, the CLI or `rules.json`, and immediate reaction to launches, focus, power, thermal and memory-pressure changes. No restart needed.
- **`appwrangler` command line:** `list`, `rules`, `status`, `limit`, `ecores`, `memlimit`, `lowmem`, `enable`/`disable`/`ignore`, `unlimit`, `freeze`/`unfreeze`, `pause`/`resume`, `export`/`import`.
- **Per-app detail:** live CPU, memory, energy (W), disk I/O and threads, a 10-minute history chart, and a per-process breakdown.
- Name-pattern rules (`*Helper*`), rule import/export, an activity log, a ⌃⌥⌘P pause shortcut, the option to show CPU in the menu bar, Launch at login (`SMAppService`).
- English and Russian interface; VoiceOver labels.
- **Safety:**
  - every paused app is released on quit, crash or SIGTERM;
  - session-critical processes are protected;
  - only one instance runs at a time.
- **Tests:** 119 unit and integration tests (Swift Testing) and a 33-check end-to-end suite that drives the real app, including a real menu bar app, MCP and `kill -9` recovery.
- New icon (a lasso around a gauge) and menu bar icon, drawn in code (`scripts/make-icons.swift`).
- Builds with only the Xcode Command Line Tools (`build.sh`, `test.sh`). Optional universal build and Developer ID notarization.
- Automatic import of AppPolice 1.x saved limits and AppPolice 2.x rules.

### Fixed (compared with AppPolice 1.1)
- CPU time was read in Mach ticks as if it were nanoseconds, so on Apple Silicon the limiter practically never engaged and CPU figures were about 42× too low.
- Helper processes weren't limited, so Chrome, Electron and Safari kept running at full speed.
- A crash or quit could leave limited apps suspended indefinitely.
- Data races, deprecated spin-locks, and non-async-signal-safe signal handlers.
- A crash when an app launched without an icon, and a NULL dereference for users without a passwd entry.
- It no longer built on current macOS: it depended on a missing external framework, OS X 10.7, manual memory management and removed login-item APIs.

### Added, changed and fixed during release preparation

#### Changed
- *Only while the app is in the background* now covers efficiency cores as well as the CPU limit, is on by default for new rules, and is shown at the top of the rule editor with a warning when off. Rule summaries say "background only".
- The limiter measures apps under their limit every 250 ms and held-back apps every 100 ms (was every 50 ms), cutting AppWrangler's own CPU use roughly in half with many rules.

#### Fixed
- Auto mode now manages an app together with all its helpers, even if the app's rule has "Include helper processes" off (that option only scopes the rule's own limits). Restoring child processes no longer resets an app's own helpers.
- **Crash safety:** a watchdog process now restores paused and efficiency-core apps (and children that inherited the policy) even after `kill -9` or a system kill.
- CLI commands (`freeze`, `pause`…) only reach the AppWrangler using the same data folder. Before, a test copy's commands also paused and froze things in your real copy.
- Frozen apps or processes that quit are no longer listed as frozen, and a relaunched app doesn't come back frozen.
- Absurd numbers in rules (from files, the CLI or MCP) are clamped instead of crashing AppWrangler. MCP `list_apps` with a negative limit no longer crashes the server, batches get a proper JSON-RPC error, and missing or empty arguments are rejected.
- A command running in a terminal's foreground is no longer paused, which made the shell suspend it. Efficiency cores still apply.
- Ctrl-Z on AppWrangler run from a terminal no longer disables limiting for the rest of the session.
- `appwrangler limit` keeps a rule's "background only" setting unless `--background-only` / `--always` is given. CLI-created rules are background-only, like UI-created ones.
- The CLI and MCP report Auto mode's real default ("on").
- Auto: an app counts as in use if any of its processes is frontmost; efficiency cores start 30 s after you leave an app (not 45 s); "busy" needs readings at least ~1 s apart, and a middle-band reading breaks a streak; turning Auto off and on starts fresh.
- Low-memory actions spare apps playing or recording audio even when Auto mode is off.
- Housekeeping no longer grows with every short-lived process; the rules file is re-read only when it changed; a reused pid gets a fresh identity.
- Statistics: AppWrangler's own CPU is measured correctly across gaps, and freezes are credited for at most their first hour.
- Low-memory freeze/quit no longer hits the app you're using or one playing/recording audio, only background apps.
- An app you're using is forced back to full speed even if an earlier AppWrangler (or anything else) left it on the efficiency cores.
- If AppWrangler crashes or is killed, apps it moved to efficiency cores are now restored too, not only paused apps.
- Rules matched by bundle ID didn't apply to menu bar / background apps (`LSUIElement`) launched after AppWrangler started, because macOS doesn't announce those launches. AppWrangler now watches the running-apps list directly.
- Runaway-CPU suggestions now clear once the app quits or gets a rule, instead of lingering in the panel.
- Turning off *Efficiency cores only* now also restores processes the app had started while in efficiency mode, since macOS passes the policy on to children (e.g. shells and builds started from a terminal or AI-coding app).
- The test scripts opt out of any inherited efficiency-core policy, so timing measurements are reliable however they're launched.

#### Added
- **Last-hour statistics and efficiency-core energy savings.** The Impact view, `appwrangler stats hour` and MCP `get_impact_stats` (`period: hour`) show the last clock hour. Energy saved now includes an estimate for apps running on efficiency cores, based on a measured ≈4.5× P-core/E-core energy ratio.
- `appwrangler status` and MCP `get_status` show what Auto mode is doing to each app.
- **Auto mode** (on by default):
  - the focused app, a just-left app (15 s grace) and apps playing or recording audio always run at full speed;
  - other apps move to efficiency cores after 30 s in the background;
  - only when the Mac is busy (75%, or 50% on battery) do background apps share the free CPU (max-min fairness with a per-app floor and a core kept free for the foreground).

  Apps with their own CPU / E-core rule, ignored apps, processes and macOS services are left alone. Shown in the panel header and rows, in Settings → General, via `appwrangler auto on|off` and `status`, and via the MCP `set_auto_mode` tool.
- **MCP server for AI assistants.** `AppWrangler mcp [--read-only]` lets Claude Desktop, Claude Code, OpenAI Codex, the OpenAI Agents SDK and other MCP clients audit running apps, analyse impact statistics, and propose or apply rules. It has 5 read-only and 9 approval-gated tools, plus `audit_mac` / `explain_impact` prompts. See docs/mcp.md.
- **Impact statistics.** CPU time saved, estimated energy saved (also as % of battery), time apps were held back, frozen or on E-cores, and actions taken, per app and per day, kept for 35 days. Also AppWrangler's own CPU and memory, its efficiency ratio and limit accuracy. Shown in Settings → Impact (with a daily chart), the panel footer, and `appwrangler stats [today|week|month] [--json]`.
- `-AWHeadless YES` runs without a menu bar icon; the end-to-end test uses it so its copy doesn't appear next to yours.
- `appwrangler status` lists apps currently flagged as using a lot of CPU in the background.
- End-to-end tests against a real menu bar app with an in-bundle helper: grouping, bundle-ID limits on an app launched later, and memory limit → Quit closing the app and its helper (23 checks).
