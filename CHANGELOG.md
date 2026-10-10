# Changelog

All notable changes to AppWrangler are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Make room for an app** — for a call, a recording, a render or a game. For 30 minutes, 1 hour, 3 hours or until you stop it, one app gets everything it needs: full speed, never capped or frozen (its own CPU rule set aside; memory limits still apply). Everything else steps back: efficiency cores at once, the Mac counts as busy from 60% and the rest then shares one core less, work that can wait is paused, hot processes are held, and idle apps are frozen if memory gets short, even if idle freezing is off. Away mode is suspended. Start it from the menu bar icon's right-click menu, an app's details, `appwrangler make-room Zoom 1h`, `appwrangler://make-room/Zoom?minutes=60`, or the MCP tool `make_room`; the panel shows the time left with **Stop**.
- **Unfreeze one app** from the menu bar icon's right-click menu (one item per frozen app, with why it was frozen) or the panel's new **Frozen** list. There's deliberately no "unfreeze all": the rest stays tamed. Something that can wait isn't paused again for 30 minutes after you unfreeze it.
- **A snowflake on the menu bar icon** (❄︎2) while apps are frozen.

### Changed
- **Prioritized** (was *High*) apps get room: while one is working, work that can wait is paused and the rest makes way. They still stay within the safety limits: if prioritized apps together would take every core while the Mac is saturated, they share all but one. The tiers now read **Prioritized**, **Normal** and **Can wait** (still `high`, `normal`, `low` for the command line and assistants).
- **Calls count as what matters:** an app playing or recording audio (Zoom, Teams, Meet in a browser) makes the rest step back while it works, and you don't count as away during a call.

## [1.5.0] — 2026-10-10

### Added
- **Adaptive Auto** (on by default; `appwrangler prefs auto_adaptive=off` to switch it off). Auto now follows what the Mac needs right now:
  - when you're plugged in and the Mac is calm and cool, a background app that's doing real work **runs free** instead of staying on the efficiency cores, so the job finishes sooner. It goes back when the Mac gets busy or the app goes quiet, and nothing runs free for two minutes after a busy spell;
  - on battery, in Low Power Mode or when the Mac is hot, background apps move to the efficiency cores after 10 s instead of 30 s;
  - idle freezing steps in at the first memory warning, one app at a time (biggest first, every 15 s) instead of waiting for critical and freezing everything at once, and holds while memory is short;
  - frozen apps resume one at a time (every 10 s) once memory has been fine for a minute;
  - apps running free show in the panel's Auto line, in the app's row, and in the activity log.
- **Priorities.** Each app or process is *High*, *Normal* or *Low* priority. When the Mac needs its resources for what you're doing (it's saturated while the app in front works, or memory is short), low priority work is moved to the efficiency cores at once and, if the need lasts, **paused**; it resumes when the Mac has had room for 30 s, and is never paused for more than 10 minutes at a stretch. The built-in Low list is short and conservative: Spotlight and photo analysis helpers, and third-party updaters (Google Software Update, Microsoft AutoUpdate…). High priority apps are never capped, held or frozen. Pick a priority in an app's details, with `appwrangler set <app> priority=low`, or through `configure_app`. A card in the panel says what was paused, with **Resume now**. Switch it off with `appwrangler prefs auto_shed=off`.
- **Auto manages command-line processes** (`auto_processes`, on by default): the ones that run hot, only while the Mac needs its resources (busy, on battery, in Low Power Mode or hot), and only on the efficiency cores. Never a cap, never frozen; never build tools, dev tools, containers, system software, protected processes or what a terminal is waiting for.
- **Away mode** (`auto_away`, `auto_away_minutes`, on by default): with no input for 5 minutes while you're plugged in, nothing is held back, so background work finishes at full speed. It's all restored within about two seconds of you being back.
- **Learning your routine** (`auto_learn`, on by default, **stays on this Mac**): which app you use in which weekday-hour. Apps you usually use around now stay at full speed 5 minutes after you leave them, aren't frozen for memory, and come back early if they were; the apps you're least likely to need soon are frozen first. Only identifiers and minutes are kept, in `patterns.json`; switch it off or forget it in Settings → General → Auto mode.

### Changed
- **The menu bar panel is now an overview.** It shows:
  - CPU and memory charts for the last 10 minutes (a dashed line for the share on efficiency cores; shading while the Mac was short of memory);
  - the Auto line with its switch;
  - the five busiest apps and the last few things AppWrangler did.

  The full list of apps moved to the main window: click **All apps**. The window is unchanged.
- **Cards for what AppWrangler just did.** When Auto freezes an idle app, a memory rule acts, or a background app runs away, the panel shows a card for 30 seconds from when you see it. **OK** leaves it to Auto, **Set manually…** opens that app's settings in the main window, and **Leave *app* alone** keeps it out of Auto. Nothing needs a click: Auto handles it by default.
- **The panel opens by itself** (for 30 seconds, without taking keyboard focus, at most once every two minutes) when a card appears. Turn it off in Settings → General → Notifications or with `appwrangler prefs show_panel_on_action=off`.
- **Auto comes first for every app.** An app's details in the main window start with *Auto (recommended)*, *Custom rule* or *Leave alone*, and the manual editor only shows for a custom rule. The right-click menu and the runaway banner lead with Auto too. When Auto can't handle something (a command-line process, or Auto is off), cards and suggestions offer the gentle option, efficiency cores, and *Set manually…*; the 25% or 50% cap is under *Custom rule*.
- In the app, a CPU suggestion needs a few minutes of history, so a one-second spike from a short-lived process isn't flagged. The command line and MCP are unchanged.
- Clicking an app under *Busiest apps* opens it, expanded, in the main window.
- Russian is no longer kept complete: new text shows in English.

### Added (for contributors)
- Tests for the chart history and the cards, and for adaptive Auto (running free, battery, cooldown, early and gradual memory handling).
- **The GitHub wiki is generated from the docs.** `scripts/sync-wiki.py` builds it (and checks every link); a workflow publishes it when `WIKI_SYNC` is `on`.

## [1.4.1] — 2026-10-09

### Added
- **One-click install in Claude Desktop:** each release now includes an MCP bundle, `AppWrangler-mcp-X.Y.Z.mcpb`. Double-click it to add AppWrangler's tools to Claude Desktop. It uses your installed app when there is one. See [docs/mcp.md](docs/mcp.md#claude-desktop-one-click-bundle).
- AppWrangler is ready for the official MCP Registry (`server.json`, name `io.github.IntarsO/appwrangler`).

### Changed
- **README:**
  - a clearer pitch;
  - Homebrew install first, with the notarization note up front;
  - an honest comparison with App Tamer, AppPolice and Activity Monitor;
  - download links go to the latest release.
- In Impact, "Memory freed" shows "—" instead of "Zero KB" when nothing was freed.

### Added (for contributors)
- **Screenshots without your own apps:** debug builds have a demo mode (`-AWDemoFixture scripts/demo/fixture.json`) that shows made-up apps and numbers, with nothing measured or enforced. `scripts/screenshots.sh` uses it.
- `scripts/render-social.sh` renders the 1280×640 social preview.
- `scripts/record-demo.sh` records the README demo and turns it into an MP4 and a GIF with Apple's frameworks only.
- `scripts/check-links.sh` checks every external link in the docs.
- `scripts/render-widget.sh` takes an optional `widget.json` and renders in English by default.

## [1.4.0] — 2026-10-08

### Added
- **Memory in Impact.** Impact (and `appwrangler stats`, MCP `get_impact_stats`) shows:
  - time the Mac was short of memory, and peak swap;
  - how much macOS had to read back from swap (also per hour of memory shortage);
  - how many apps were frozen for memory, and the memory they held.

  Compare days with idle freezing on and off to see whether it helps your Mac.
- **One-command releases.** `scripts/release.sh X.Y.Z` tags a release. GitHub Actions then tests, builds, publishes it with notes from the CHANGELOG, and updates the Homebrew cask. A manual dry run builds without publishing.

### Changed
- **The watchdog is its own process, `AppWranglerWatchdog`,** so `killall -9 AppWrangler` can no longer take it down too and leave apps frozen.
- **Rule edits from several places are merged.** Edits from the window, the CLI and AI assistants at the same moment are applied under a lock, instead of the last writer replacing the file.

## [1.3.0] — 2026-10-08

### Added
- **Widget buttons and a large size.** The medium and large widget have **Pause/Resume**, **Auto** and **Free memory** buttons. The large size shows five apps and up to three suggestions.
- **Free memory now:** freeze the apps you haven't used for a while, right away. Each resumes when you switch to it. From the widget, `appwrangler free-memory`, `appwrangler://free-memory` or MCP `free_memory`.
- **More `appwrangler://` links:** `pause`, `resume`, `toggle-pause`, `auto/on|off|toggle`, `free-memory`, for Shortcuts and scripts.
- **App-wide settings from the CLI and AI assistants:** `appwrangler prefs [key=value …]` and MCP `get_preferences` / `set_preferences`. This covers Auto timings, idle freezing, the low-memory level, runaway alerts, notifications, menu bar CPU and the pause shortcut.
- `appwrangler undo --force`, and MCP `undo_last_change` with `force`.
- Right-click **Copy Bundle ID**.

### Changed
- **Safer freezing:**
  - A freeze ends as soon as the setting that caused it is turned off (a memory-limit rule removed, disabled or no longer set to *Freeze*; low-memory freezing switched off).
  - Low-memory freezes are lifted only after memory has been fine for a minute.
  - Nothing new is frozen while limits are paused.
  - Commands in a terminal's foreground are never frozen.
- **Idle freezing skips** apps still doing work (above 5% CPU), terminals, code editors and IDEs, and virtual machines and containers.
- **App names resolve the same way everywhere** (CLI, MCP, suggestions):
  - bundle IDs and installed apps that aren't running get bundle-ID rules;
  - a unique part of a running app's name works;
  - ambiguous names list the candidates instead of guessing;
  - processes critical to macOS (any letter case) and patterns like `*` are refused;
  - process-name rules ignore case.
- **Older CLI commands share one path with `set`:** `limit`, `ecores`, `memlimit`, `lowmem`, `enable`/`disable` and `ignore` get the same checks and undo history, and remove rules that end up empty.
- **Undo:**
  - It stops rather than overwrite a rule edited in the app since.
  - It never creates a duplicate rule.
  - It now also covers runaway-alert buttons, right-click quick limits and imports.
  - The history file is locked between processes, and set aside rather than wiped if it's unreadable.
- **`freeze`/`unfreeze` fail clearly** for a name that isn't running.
- **`mcp install`:**
  - merges into an existing entry (keeping `env` and other fields) and follows symlinked configs;
  - keeps the original backup;
  - retries if `~/.claude.json` changes underneath it;
  - handles Codex configs with Windows line endings, comments, quoted keys, sub-tables and multi-line arrays, and refuses inline entries instead of duplicating them.
- Suggested shell commands are quoted safely.
- Suggestions no longer propose slowing down compilers and build tools.
- Test copies of AppWrangler (on another data folder) no longer refresh the desktop widget. Memory-pressure changes refresh it at most once a minute.
- **Right-click Force Quit** now asks for confirmation.
- **Copy Name** copies the name.
- **Docs:**
  - Getting Started introduces Auto mode first.
  - The User Manual covers the new features, the data files, every General setting, links, and the watchdog's `killall -9` caveat.

### Fixed
- An app frozen by a memory limit stayed frozen after the rule was removed or changed.
- Re-checking a partial sample could briefly let a frozen app run.
- After switching to an app with several windows or processes, Auto could keep it slowed for a moment.
- `mcp` with a mistyped option waited silently instead of reporting the error.
- The end-to-end tests' dummy processes now get a unique name per run, so no rule on the Mac can match them and skew the timings.
- The MCP `undo_last_change` tool was marked non-destructive and idempotent.

## [1.2.0] — 2026-10-08

### Added
- **Desktop and Notification Center widget** (macOS 14+), in small and medium sizes.
  - It shows CPU and memory (with swap), what Auto mode is doing, paused or frozen apps, CPU time saved today, the three busiest apps and the top suggestion.
  - Clicking it opens AppWrangler's window.
  - It's a sandboxed WidgetKit extension that only reads the `widget.json` the app writes every minute, and it's built with the Command Line Tools like the rest of the app.
- `appwrangler://window`, `appwrangler://settings` and `appwrangler://help/<page>#<section>` links open those parts of AppWrangler.
- `scripts/render-widget.sh` renders the widget's views to PNGs for checking layout changes.
- In macOS's monochrome widget style, the widget's rings, status and app icons take your accent colour.
- Screenshots of the panel, Help window and widget in the User Manual, also shown in the in-app Help.

### Fixed
- In the Help window, narrow table columns were squeezed to one letter per line.
- Build numbers are now `YYYYMMDD.HHMM`. A single large number made WidgetKit reject the widget ("Bundle version did not match").
- `build.sh --install` and the end-to-end tests now keep only the installed copy registered with macOS, and stop an old widget process, so the widget always runs the installed build.

## [1.1.0] — 2026-10-08

### Added
- **Auto mode can free up memory (opt-in).** When the Mac is low on memory, it freezes regular apps you haven't used for a while (10 min by default), biggest first.
  - They resume the moment you switch to them, or when memory frees up.
  - It never freezes the app in use, audio apps, messaging and calls apps, or menu bar apps.
  - Turn it on in Settings → General → Auto mode, with `appwrangler auto freeze-idle on`, or with MCP `set_auto_mode`.
- **Open the panel in a window** that stays open, like Activity Monitor: use the window button in the panel or *Open in a Window* in the menu. It has a Dock icon while open, and reopens at launch if it was open when you quit.
- **Suggestions in the panel**, with one-click buttons to apply them and **×** to hide one for a week.
- **Suggestions use recent averages.** The running app shares 10-minute per-app averages (`usage.json`), so a short CPU spike isn't flagged as a problem.
- **Undo.**
  - `appwrangler undo` and MCP `undo_last_change` revert the last rule change made from the CLI, an AI assistant or a suggestion (up to 50).
  - `configure_app` results include the `previous` settings.
- **`appwrangler mcp install | uninstall | status`** sets up Claude Desktop, Claude Code and OpenAI Codex in one step. It backs up each file first and refuses to edit Claude Desktop's settings while it's open, because Claude Desktop would overwrite them.
- **Homebrew cask:**
  - `brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler`
  - `brew install --cask appwrangler`
- **CI:** GitHub Actions builds the app and runs the unit tests on every push.
- An app frozen because memory was low (by Auto or by its rule) now resumes as soon as you switch to it.
- **Suggestions.**
  - `appwrangler suggest` and the MCP tool `suggest_settings` recommend settings for what's running:
    - memory hogs when the Mac is short of memory, with browser tab-sleeping tips;
    - busy unmanaged background processes;
    - rules that slow an app while you use it;
    - limits that held an app back most of the week;
    - memory limits an app is always over;
    - rules for apps that no longer exist.
  - Each suggestion gives the reason, the expected benefit and ready-to-apply actions (MCP call and CLI command).
- **Every setting of an app in one place.** `appwrangler show <app>` and MCP `get_app_settings` show:
  - what the app is and its live usage;
  - every setting;
  - who manages it (its own rule, Auto mode, or nothing);
  - suggestions for it.
- **Change any setting in one step.** `appwrangler set <app> key=value …` and MCP `configure_app` change any combination of settings, including `use_auto` to hand an app back to Auto mode.
- **MCP prompt `tune_app`** for a guided conversation about one app.
- **In-app Help.**
  - The User Manual, Getting Started, CLI, AI-assistant and FAQ pages are built into the app: searchable, offline, light and dark.
  - Open them from the **?** in the panel, the menu bar menu, Settings → About, or ⌘?.
  - **?** buttons next to settings open the manual at the right section.
- Standard keyboard shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z in text fields, ⌘W, ⌘,) now work in AppWrangler's windows.

### Fixed
- The panel could extend past the right edge of the screen when the menu bar icon was near it. It now stays inside the screen.
- `test.sh` failed under full Xcode (bash 3.2 and an empty argument list).

### Changed
- The User Guide is now the **User Manual** (`docs/user-manual.md`), with new chapters on suggestions, per-app settings, AI assistants and in-app Help.

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
