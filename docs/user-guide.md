# AppWrangler User Guide

- [Key ideas](#key-ideas)
- [Auto mode](#auto-mode)
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
- [Impact: how much it helped](#impact)
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

## Auto mode

**Auto mode is on by default and needs no setup.** It keeps every app usable while you're using it, and efficient while you're not:

| Situation | What Auto does |
|---|---|
| The app you're using | Full speed, on the performance cores. Switching to an app restores it instantly. |
| An app you left a moment ago | Stays at full speed for 15 s, so quick switching back and forth never stutters. |
| Apps playing or recording audio | Treated as in use, even in the background: music, video calls, dictation tools like Whispr. |
| Other apps in the background | After 30 s in the background they move to the **efficiency cores**. They keep working (sync, notifications, downloads), just using far less power. |
| The Mac is busy (above 75% CPU, or 50% on battery) | Background apps **share** whatever CPU the foreground isn't using. Light apps keep what they use; heavy ones split the rest; each keeps a minimum so nothing freezes. One core is always kept free for the app you're using. When the Mac calms down, the caps go away. |

So AppWrangler adapts to **how many apps you're running and how hard they work**. With little running, nothing is held back. With a lot going on, the apps in the background share fairly, and the one in front stays fast.

The panel header shows what Auto is doing, e.g. *"Auto · 12 apps · 1 in use · 9 on E-cores · 0 capped · Mac not busy"*. Each row says how Auto is treating that app (*"Auto · efficiency cores (in background)"*).

**Auto and your own rules:**
- An app with its own **CPU limit** or **Efficiency cores** setting follows that rule; Auto leaves it alone.
- A rule with only memory or low-memory settings still lets Auto handle the app's CPU.
- To keep Auto away from an app completely, give it a rule and turn on **Ignore this app**.
- Plain processes (command-line tools, builds) and macOS services aren't managed by Auto.

Settings → General → **Auto mode** lets you change:
- the 30 s delay;
- whether background apps use efficiency cores;
- whether the CPU is shared when the Mac is busy, and above which load.

The **Auto** switch in the panel header turns it off; `appwrangler auto on|off` works too.

> **Tip:** prefer Auto over fixed limits for everyday apps. A fixed limit like "Slack 25%" applies even while you use Slack (unless *Only while the app is in the background* is on) and makes it feel broken. Auto gives you the efficiency without the slowness.

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

### Only while the app is in the background

**On by default for new rules.** The rule's CPU limit and efficiency-core setting apply only while the app isn't the one you're using. When you bring it to the front it runs at full speed on the performance cores; when you switch away, the rule applies again. Turn it off only for apps you never want at full speed. The editor warns that this can make them feel slow.

### Limit CPU

Caps the app's combined CPU use. Choose anything from 1% up to 100% × the number of cores, using the slider, the number field, or the preset buttons.

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
- The app you're using, and any app playing or recording audio, is never frozen or quit for this. Only background apps are.
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

## Impact

**Settings → Impact** shows what AppWrangler has achieved, and what it cost to run, for **Today**, **7 days** or **30 days**. The same numbers are available from `appwrangler stats` and the [MCP server](mcp.md). The panel footer shows "saved … today".

**How it helped:**

| Number | How it's measured |
|---|---|
| **CPU time saved** | While an app is held back, the limiter measures how much CPU it *wanted* and how much it *got*; the difference adds up. A frozen app is credited with the CPU it was using when frozen. Shown in core-minutes or core-hours (1 core-hour = one core busy for an hour). |
| **Energy saved (est.)** | CPU saved × that app's own measured watts per core (1.5 W/core until it's been measured). On a MacBook it's also shown as a share of a full battery. |
| **Apps held back** | Time apps wanted more than their limit. |
| **Apps frozen / on efficiency cores** | Time spent in those states. |
| **Memory freed** | Memory released by memory-limit *Quit/Force quit* actions. |
| **Actions** | Memory-limit actions, low-memory actions and runaway alerts. |

A daily bar chart shows CPU time saved per day.

**What AppWrangler cost:**
- its average CPU use and total CPU time;
- its memory (average and peak);
- **limit accuracy:** how closely held-back apps stayed at their limit, e.g. ±1.5%;
- an **efficiency ratio:** "saved N× more CPU time than it used".

These are measured only while AppWrangler is actively watching or limiting apps. When there's nothing to do, it doesn't run at all.

**Per app:**
- CPU and energy saved;
- average **wanted → allowed** CPU;
- time held back and frozen.

Statistics are kept for 35 days in `stats.json` next to your rules, and are written every 30 seconds and on quit. **Reset Statistics…** clears them.

> These are estimates. "Wanted" comes from the limiter's measurement of how much the app uses whenever it's allowed to run. An app that would have finished its work sooner isn't modelled, so treat the numbers as a good indication rather than an exact meter.

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
| Impact statistics | `~/Library/Application Support/AppWrangler/stats.json` (35 days) |
| Status for the CLI | `~/Library/Application Support/AppWrangler/state.json` |
| Preferences | `defaults read io.github.intarso.AppWrangler` |

On first launch AppWrangler imports rules from AppPolice 2.x (`~/Library/Application Support/AppPolice/`) and limits saved by AppPolice 1.x.

The interface is available in **English** and **Russian** and follows your macOS language. Descriptions of specific apps and processes are in English.
