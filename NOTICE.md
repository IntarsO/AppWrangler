# Notice

## AppWrangler is a fork of AppPolice

AppWrangler is derived from, and inspired by, **AppPolice** by **Maksym Stefanchuk**:

- Upstream: https://github.com/fuyu/AppPolice
- Copyright © 2013–2015 Maksym Stefanchuk
- License: GNU General Public License, version 2

AppPolice introduced the idea AppWrangler builds on: a minimal menu bar app that throttles a running app's CPU usage by suspending and resuming it. AppWrangler keeps that idea, the duty-cycle limiting approach, and support for AppPolice's saved per-app limits.

## What changed

As required by section 2(a) of the GPL v2, here is a summary of the modifications. **Starting 2026-10-08, the AppPolice 1.1 code base was replaced by a ground-up rewrite** under the new name AppWrangler:

- The Objective-C app, its XIB interface and the external ChromeMenu framework were replaced with Swift/SwiftUI (`Sources/AppWranglerKit`) and a new C module (`Sources/ProcKit`).
- The CPU limiter (`proc_cpulim.c`) was rewritten. The new one:
  - is correct on Apple Silicon (Mach-tick time base);
  - limits whole process groups, i.e. apps with their helpers;
  - runs on a real-time thread with a feedback controller;
  - has an async-signal-safe crash release path.
- New features were added: efficiency-core mode, memory limits, low-memory protection, conditional rules, runaway detection, process descriptions, a command-line interface, history charts, tests and documentation.
- New name, bundle identifier (`io.github.intarso.AppWrangler`) and artwork.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

## License

AppWrangler as a whole is distributed under the **GNU General Public License, version 2** ([LICENSE](LICENSE)), the license of the work it derives from.

- Copyright © 2013–2015 Maksym Stefanchuk (AppPolice)
- Copyright © 2026 AppWrangler contributors

The original AppPolice 1.x sources are not part of this repository; get them from the upstream link above.

## Third-party components

AppWrangler has no third-party code dependencies. It uses only Apple system frameworks (AppKit, SwiftUI, Foundation, IOKit, ServiceManagement, UserNotifications, Carbon HIToolbox) and the C library.
