# AppWrangler User Guide

- [Key ideas](#key-ideas)
- [The main panel](#the-main-panel)
- [Rules](#rules)
  - [Limit CPU](#limit-cpu)
  - [Efficiency cores only](#efficiency-cores-only)
  - [Memory limit](#memory-limit)
  - [When the Mac is low on memory](#when-the-mac-is-low-on-memory)
  - [When to apply (conditions)](#when-to-apply-conditions)
  - [Helper processes](#helper-processes)
  - [Ignoring an app](#ignoring-an-app)
- [Freeze, quit and force quit](#freeze-quit-and-force-quit)
- [Pausing all limits](#pausing-all-limits)
- [Runaway alerts](#runaway-alerts)
- [Settings window](#settings-window)
- [Safety](#safety)
- [Where your data lives](#where-your-data-lives)

---

## Key ideas

**CPU percentages are per core.** As in Activity Monitor, 100% means one CPU core fully busy. An 8-core Mac has 800% in total, so a limit of 50% means "half of one core" and 200% means "two cores' worth".

**Apps are measured together with their helpers.** Modern apps run as many processes. Chrome and Electron apps (Slack, Discord, VS Code…) start a renderer per window or tab, and Safari's web pages run as separate *WebContent* processes. AppWrangler folds these into the app they belong to: the **+N** next to a name is the number of helpers. Limits and memory figures cover the whole group, unless you turn off [helper processes](#helper-processes).

**Rules follow the app.** A rule is saved for the app, not for one running copy. It applies immediately, again every time the app launches, and after you restart your Mac. Rules are matched by bundle ID (for apps), path, process name, or a name pattern.

**Nothing needs a restart.** Changing a rule in the panel, in Settings, from the [command line](cli.md), or by editing `rules.json` takes effect within about half a second. So do switching apps, plugging in or unplugging, Low Power Mode, the Mac heating up, and memory pressure changing.

---

## The main panel

Click the menu bar icon.

| Area | What it shows |
|---|---|
| Header | Chip and core layout (e.g. *4P + 4E*), total CPU, memory used and memory pressure, and an **Active / Paused** switch. A line appears when you're on battery, in Low Power Mode, or the Mac is hot. |
| Suggestions | Orange banner with [runaway alerts](#runaway-alerts), if any. |
| Search | Matches names, bundle IDs and descriptions. Try "browser", "sync" or "Spotlight". |
| Sort | By CPU, Memory, Energy or Name. Rows don't reorder while your pointer is over the list or a row is open, so they don't jump around. |
| Sections | **Apps**, **Menu bar & background apps**, **macOS system services**, **Processes**. Click a header to collapse or expand it. Searching shows matches in every section. |
| Footer | Number of active rules, **Settings…**, **Quit**. |

**Row badges:**

| Badge | Meaning |
|---|---|
| Gauge (orange) | CPU limit active (grey while paused) |
| Leaf (green) | Running on efficiency cores only |
| Memory chip (purple) | Memory limit set |
| Snowflake (cyan) | Frozen |
| Warning (yellow) | Can't be controlled (belongs to another user) |

**Click a row** to open its details:

- **What it is:**
  - the kind (App, Background app, macOS service, Process) and the vendor;
  - a description;
  - a safety note: *Safe to limit*, *Limit with care*, or *Critical to macOS*;
  - the bundle ID and path. You can select and copy them.
- **Live stats:** CPU, memory, energy (watts), disk read/write per second, threads.
- **Chart:** CPU and memory over the last 10 minutes, with peaks. History is collected while AppWrangler is measuring the app: always for apps with rules, otherwise while the panel is open.
- **Throttling status**, e.g. *"Throttling: using 25%, allowed to run 12% of the time"*.
- **The rule editor** (described below) and buttons for **Freeze**, **Quit**, **Force Quit** and **Remove Rule**.
- **Processes (N):** every process in the group, with its own CPU and memory.

**Right-click a row** for quick actions:
- *Limit CPU → 10/25/50/100/200%*, or *No CPU limit*;
- *Efficiency cores only*;
- *Freeze/Unfreeze*, *Quit*, *Force Quit*;
- *Remove Rule*;
- *Show in Finder*, *Copy Name*.

---

## Rules

### Limit CPU

Caps the app's combined CPU use. Choose anything from 1% up to 100% × the number of cores, using the slider, the number field, or the preset buttons.

- **Only while the app is in the background**: the limit switches off the moment you bring the app to the front and back on when you switch away. It's ideal for apps that should be snappy while you use them but quiet otherwise.

How it works: AppWrangler lets the app run for part of each short cycle (50 ms by default) and pauses it for the rest, adjusting the split continuously to hit your target. A heavily limited app may feel less smooth; if that bothers you, try *Efficiency cores only* instead.

### Efficiency cores only

Puts the app in macOS's *background* scheduling class. On Apple Silicon this runs it on the efficiency cores and slows its disk and network access.

- The app is **never paused**, so it stays responsive, just slower at heavy work.
- It's great for sync clients, updaters, chat apps and build tools.
- It combines well with a CPU limit.
- It's undone automatically when you remove the rule or quit AppWrangler.

### Memory limit

macOS doesn't let one app hard-cap another's memory. Instead, AppWrangler watches the app's **memory footprint** (the "Memory" column in Activity Monitor) and acts when it stays above your limit for two measurements in a row, so a brief spike doesn't count:

| Action | What happens |
|---|---|
| Notify me | A notification and an Activity log entry |
| Freeze (suspend) | The app and its helpers are suspended until you unfreeze them |
| Quit app | Asks the app to quit normally, as Quit from the Dock would |
| Force quit | Ends it immediately. Unsaved work is lost |

The action happens once each time the app goes over the limit. It can trigger again after memory drops below 90% of the limit.

### When the Mac is low on memory

Separate from the per-app limit: this decides what happens to an app when **the whole Mac** runs short of memory, i.e. when macOS reports memory pressure.

- **Freeze until memory frees up** suspends the app while pressure is high, and resumes it automatically when it eases.
- **Quit app** quits it once.

By default this happens at *critical* pressure. In Settings → General you can make it happen earlier, at *warning* pressure.

### When to apply (conditions)

Open **When to apply** to restrict when a rule is in force:

| Condition | Example use |
|---|---|
| Power: *Only on battery* / *Only when plugged in* | Keep Dropbox on E-cores only when unplugged |
| Only in Low Power Mode | Tighten everything when you've switched Low Power Mode on |
| Only when the Mac is hot | Limit a game or render job when the Mac reports serious thermal pressure |
| Only during these hours | Throttle Slack 09:00–17:00 on weekdays. Windows can cross midnight (e.g. 22:00–06:00), and the early-morning part counts as the previous day |

All the conditions you turn on must hold. Rules switch the moment a condition changes, e.g. when you pull the charger. If a rule is waiting for its conditions, the app's detail view says so.

### Helper processes

**Include helper processes** (on by default) applies limits, efficiency mode and memory accounting to the app's renderers, XPC services and other helpers too. Turn it off to affect only the main process.

### Ignoring an app

**Ignore this app in suggestions and automatic actions** keeps an app out of [runaway alerts](#runaway-alerts) and switches off all of its limits, without deleting the rule. *Ignore this app* on a runaway notification does the same thing.

### How rules are matched

When more than one rule could apply, the most specific wins: **bundle ID → path → process name → name pattern**.

- Rules created from the panel use the bundle ID for apps, and the path or name for plain processes.
- In Settings you can add a **name pattern** such as `*Helper*` or `com.google.*`:
  - `*` matches anything and `?` matches one character;
  - case is ignored;
  - the pattern is checked against names and bundle IDs.

---

## Freeze, quit and force quit

- **Freeze** suspends the app and all its helpers immediately. It uses no CPU while frozen; its memory stays allocated, and macOS can compress it. **Unfreeze** resumes it exactly where it was. A frozen app shows a spinning cursor if you click its windows; that's expected.
- **Quit** asks the app to quit normally, so it can save. AppWrangler first lifts any limit, so the app can respond.
- **Force Quit** ends it immediately, after asking you to confirm.

Freezes are deliberately *not* undone by [pausing](#pausing-all-limits). They are undone when you unfreeze, when memory pressure eases (for low-memory freezes), or when AppWrangler quits.

---

## Pausing all limits

Use the **Active/Paused** switch in the header, *Pause All Limits* in the right-click menu, `appwrangler pause`, or **⌃⌥⌘P** from anywhere. This lets every CPU-limited app run freely until you resume. Frozen apps stay frozen. The menu bar icon dims while paused.

---

## Runaway alerts

When an app **you haven't made a rule for** averages more than 80% CPU (adjustable) for 3 minutes (adjustable) while **not in front**, AppWrangler shows a suggestion in the panel and sends a notification with three buttons:

- **Limit to 50%** creates a CPU-limit rule.
- **Use efficiency cores** creates an efficiency-cores rule.
- **Ignore this app** never suggests it again.

Each app is suggested at most once an hour. Turn alerts off, or change the thresholds, in Settings → General → Runaway apps. While alerts are on, AppWrangler does a light scan every 5 seconds in the background, costing about 0.2% of one core.

---

## Settings window

**App Rules:** every rule, including ones for apps that aren't running.

- **+** adds a rule for a running app, an app chosen from disk, a process name, or a name pattern. **−** deletes the selected rule.
- The checkbox next to each rule enables or disables it.
- The share button **imports or exports** rules as JSON, for backups or another Mac. Importing merges: a rule for the same app replaces the existing one.
- On the right you can edit the rule's name and *Match by* field, plus all its limits and conditions.

**General:**

| Setting | Default | Notes |
|---|---|---|
| Launch AppWrangler at login | off | Install in /Applications first |
| Refresh while window is open | 1 s | How often the panel updates |
| Check rules in background every | 2 s | How quickly rules react when the panel is closed |
| Include other users' processes | off | View only; they can't be limited |
| Show CPU usage in the menu bar | off | Total CPU % next to the icon |
| Runaway apps | on, 80%, 3 min | See above |
| Treat the Mac as low on memory at | Critical | Or *Warning* to act earlier |
| Throttle cycle length | 50 ms | Shorter is smoother for limited apps; longer means fewer wakeups |
| Pause all CPU limits | — | Same as the header switch |
| Pause/resume shortcut ⌃⌥⌘P | on | Global shortcut |
| Notifications | on | Memory, low-memory and runaway alerts |

**Activity:** a log of what AppWrangler did: limits paused, apps frozen, memory limits hit, rules reloaded, permission problems.

**About:** version, links to the documentation, source code, issue tracker and the original AppPolice.

---

## Safety

- **Nothing stays frozen if AppWrangler stops.** Quitting, a crash, or a normal `kill` releases every app AppWrangler had paused. Only `kill -9` of AppWrangler itself can't be caught; see the [FAQ](faq.md#an-app-is-stuck-not-responding-after-appwrangler-was-force-killed) for how to recover.
- **Critical processes are protected.** WindowServer, loginwindow, the Dock, Control Center, launchd and other session-critical processes can't be limited or frozen.
- **Your processes only.** Like any normal app, AppWrangler can only control processes running as your user.
- **One instance at a time**, so two copies never fight over the same apps.
- **No network access, no analytics.** AppWrangler never connects to the internet. Links in About only open when you click them.

---

## Where your data lives

| What | Where |
|---|---|
| Rules | `~/Library/Application Support/AppWrangler/rules.json` (plain JSON; edits apply immediately) |
| Status for the CLI | `~/Library/Application Support/AppWrangler/state.json` |
| Preferences | `defaults read io.github.intarso.AppWrangler` |

On first launch AppWrangler imports rules from AppPolice 2.x (`~/Library/Application Support/AppPolice/`) and limits saved by AppPolice 1.x.

The interface is available in **English** and **Russian** and follows your macOS language. Descriptions of specific apps and processes are in English.
