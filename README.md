<p align="center">
  <img src="docs/images/icon.png" width="128" alt="AppWrangler icon">
</p>

<h1 align="center">AppWrangler</h1>

<p align="center">
  <b>Keep every app on your Mac in check — CPU, efficiency cores and memory, per app.</b><br>
  A free, open-source menu bar app for Apple Silicon Macs.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-black" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--2.0-green" alt="GPL-2.0"></a>
</p>

<p align="center">
  <a href="https://buymeacoffee.com/intarsolbit"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>
</p>

---

AppWrangler shows **every running app and process** with a plain-language explanation of what it is, and lets you set limits for each one. Changes take effect **immediately**, with no restart.

| | |
|---|---|
| 🪄 **Auto mode** | On by default. The app you're using runs at full speed. Background apps move to efficiency cores, and only when your Mac is busy do they share the CPU fairly, so everything stays usable. Optionally, when memory runs out, it freezes apps you haven't used for a while, and they resume the moment you switch back. |
| 🎛 **CPU limit** | Cap an app *and all of its helper processes* (Chrome tabs, Electron helpers, Safari web content…) at any share of the CPU. Optionally limit it only while it's in the background. |
| 🍃 **Efficiency cores only** | Move an app onto the Apple Silicon E-cores, with slower disk and network access. It stays usable while saving battery and heat. |
| 🧠 **Memory limit** | When an app's memory stays above your limit, get notified, or freeze, quit or force-quit it. |
| 🚨 **Low-memory protection** | When your Mac runs short of memory, automatically freeze or quit apps you've marked as expendable, and resume them afterwards. |
| ⏱ **Conditions** | Make any rule apply only on battery or on the charger, in Low Power Mode, when the Mac is hot, or during set hours and days. |
| 🔥 **Runaway alerts** | "Chrome Helper has used 150% CPU for 3 minutes" — an alert in the panel and a notification with *Limit*, *E-cores* and *Ignore* buttons. |
| ❄️ **Freeze, quit, force quit** | Suspend any app instantly and resume it later. |
| 📊 **Impact & efficiency** | See how much CPU time and battery it saved — per app, per day — and what AppWrangler itself cost to run. |
| 💡 **Suggestions** | "Brave uses more than your 8 GB of RAM — here's what to do." Concrete recommendations for what's running, right in the panel, each with the reason, the benefit and a one-click fix. `appwrangler undo` takes back changes made from a suggestion, the command line or an AI assistant. |
| 🤖 **AI assistants (MCP)** | Talk to Claude, OpenAI Codex or your own agents about your Mac: they audit it, explain any app, suggest settings and, with your OK, configure each app for you. Set up with one command: `appwrangler mcp install`. |
| ⌨️ **Command line** | `appwrangler suggest`, `appwrangler show Slack`, `appwrangler set Slack efficiency_cores=on`, `appwrangler stats`, … |
| 🖥 **Desktop widget** | CPU, memory, Auto mode, the busiest apps and suggestions on your desktop or in Notification Center (macOS 14+), with **Pause**, **Auto** and **Free memory** buttons. |
| 📖 **Built-in help** | The full manual inside the app, searchable and offline, with a **?** next to every setting. |

It uses well under 1% of one core. It never connects to the network.

<p align="center">
  <img src="docs/images/panel.png" width="380" alt="The AppWrangler panel: CPU and memory meters, Auto mode status, suggestions for this Mac (Brave uses more than the Mac's 8 GB of RAM — turn on Memory Saver, or freeze it in the background when memory runs out), and running apps with their rules">
  &nbsp;
  <img src="docs/images/help.png" width="440" alt="The built-in Help window showing the User Manual's Auto mode chapter, with topics and search in the sidebar">
</p>
<p align="center">
  <img src="docs/images/widget-small.png" width="170" alt="Small desktop widget: CPU and memory rings, Auto mode status and CPU time saved today">
  &nbsp;
  <img src="docs/images/widget-medium.png" width="364" alt="Medium desktop widget: CPU and memory rings, Auto status, the three busiest apps and the top suggestion">
</p>

## Get started

1. **Install** with [Homebrew](https://brew.sh):
   ```bash
   brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler
   brew install --cask appwrangler
   ```
   Or download the zip from [Releases](https://github.com/IntarsO/AppWrangler/releases), or build it with Apple's free Command Line Tools: `./build.sh --install --run`.
2. **Click the lasso icon** in the menu bar to see what's running and what each item is.
3. **Click an app** and turn on **Limit CPU**, **Efficiency cores only** or **Memory limit**. That's it — the limit is active now and every time the app runs.

👉 Read the full **[Getting Started guide](docs/getting-started.md)**.

## Documentation

- [Getting Started](docs/getting-started.md): install, first limit, launch at login, uninstall
- [User Manual](docs/user-manual.md): every feature and setting explained (also built into the app: **?** → Help)
- [Command-line reference](docs/cli.md)
- [AI assistants via MCP](docs/mcp.md): Claude Desktop, Claude Code, OpenAI Codex, Agents SDK
- [FAQ & Troubleshooting](docs/faq.md)
- [How it works](docs/how-it-works.md): architecture, for the curious and for contributors

## Built on AppPolice

AppWrangler is a fork of **[AppPolice](https://github.com/fuyu/AppPolice)** by Maksym Stefanchuk (2013–2015), a menu bar app that let you throttle an app's CPU with a slider. That project inspired AppWrangler, and its source is where AppWrangler began.

The original no longer built on modern macOS and its limiter didn't work on Apple Silicon. AppWrangler is a ground-up rewrite (Swift + C) that keeps the idea and adds:

- an Apple Silicon–correct real-time CPU limiter that covers helper processes;
- efficiency-core mode;
- memory limits and low-memory protection;
- conditional rules;
- runaway detection;
- "what is this?" descriptions;
- a CLI;
- a test suite.

See [NOTICE.md](NOTICE.md) and the [CHANGELOG](CHANGELOG.md) for details. AppPolice 1.x limits and AppPolice 2.x rules are imported automatically.

## Support the project

AppWrangler is free and always will be. If it saves your battery or your sanity, you can [buy me a coffee ☕](https://buymeacoffee.com/intarsolbit). Thank you!

## Building and contributing

```bash
xcode-select --install     # Command Line Tools — full Xcode is not required
./build.sh                 # → build/AppWrangler.app
./test.sh                  # unit + integration tests
./Tests/e2e/run.sh         # end-to-end tests against the built app
```

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md). Please report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

AppWrangler is free software, licensed under the **GNU General Public License v2** ([LICENSE](LICENSE)), the same license as AppPolice. Original AppPolice code © 2013–2015 Maksym Stefanchuk; AppWrangler © 2026 AppWrangler contributors.
