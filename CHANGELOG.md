# Changelog

All notable changes to AppWrangler are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Rules matched by bundle ID didn't apply to menu bar / background apps (`LSUIElement`) launched after AppWrangler started, because macOS doesn't announce those launches. AppWrangler now watches the running-apps list directly.
- Runaway-CPU suggestions now clear once the app quits or gets a rule, instead of lingering in the panel.

### Added
- `appwrangler status` lists apps currently flagged as using a lot of CPU in the background.
- End-to-end tests against a real menu bar app with an in-bundle helper: grouping, bundle-ID limits on an app launched later, and memory limit → Quit closing the app and its helper (23 checks).

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
- **Tests:** 61 unit and integration tests (Swift Testing) and an 18-check end-to-end suite.
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
