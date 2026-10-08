# FAQ & Troubleshooting

### macOS says AppWrangler "can't be opened" or "is damaged"
Release builds are signed but not notarized by Apple. For the first launch:
- right-click the app → **Open** → **Open**; or
- go to **System Settings → Privacy & Security → Open Anyway**; or
- run `xattr -dr com.apple.quarantine /Applications/AppWrangler.app`.

Builds you make yourself with `./build.sh` aren't affected.

### I can't find the menu bar icon
AppWrangler has no Dock icon; it lives in the menu bar (a lasso loop with a needle inside). On MacBooks with a notch, a full menu bar can hide icons behind the notch. Quit a few other menu bar apps, or rearrange icons by ⌘-dragging. `appwrangler status` tells you whether it's running.

### An app I limited is unusable / really slow when I use it
Its rule applies even while the app is in front. Open the app's settings and turn on **Only while the app is in the background**, which is the default for new rules. Better still, remove the CPU and efficiency-core settings and let [Auto mode](user-manual.md#auto-mode) handle it: full speed while you use it, efficient in the background. Also check memory limits whose action is *Freeze*; a frozen app doesn't respond at all.

### What should I limit? Can AppWrangler tell me?
Yes. Run `appwrangler suggest`, or ask your AI assistant for suggestions (see [AI assistants](mcp.md)). You get concrete recommendations for what's running right now: what to change, why, the expected benefit, and the command to apply it. `appwrangler show <app>` explains one app and all its settings. See [Suggestions](user-manual.md#suggestions-what-to-change).

For everyday apps, the best setting is usually *none*: let [Auto mode](user-manual.md#auto-mode) manage them.

### AppWrangler disappeared from Claude Desktop's tools
Claude Desktop rewrites its settings file while it's open, so an entry added while it was running can be lost. Quit Claude Desktop, run `appwrangler mcp install claude-desktop`, and open it again. `appwrangler mcp status` shows where AppWrangler is configured.

### My Mac has little memory and everything swaps. What helps most?
Turn on **freezing idle apps** in Auto mode: Settings → General → Auto mode, or `appwrangler auto freeze-idle on`. When memory runs out, apps you haven't used for a while are frozen and resume the moment you switch to them. Messaging, calls and audio apps are never frozen. For browsers, also turn on their tab-sleeping feature; `appwrangler suggest` tells you where it is.

### I applied a suggestion and want it back
`appwrangler undo` reverts the last change (repeat for earlier ones), or ask your AI assistant to "undo that".

### Where's the manual?
Inside the app: click the **?** in the panel's footer, or the **?** next to any setting to jump to its explanation. It's also on [GitHub](user-manual.md).

### The limited app feels choppy or beachballs
CPU limiting works by pausing and resuming the app many times a second. At very low limits, apps with a UI can feel jerky. Options:
- Raise the limit a little, or use **Only while the app is in the background**.
- Use **Efficiency cores only** instead. It never pauses the app.
- Shorten **Settings → General → Throttle cycle length** (e.g. 20 ms) for smoother motion, at the cost of a few more wakeups.

### A row shows a yellow warning / "Can't control this process"
That process belongs to another user (often `root` or a system account). Normal apps, AppWrangler included, may only control your own processes. These are shown for information only, with *Include other users' processes*.

### "Critical to macOS — AppWrangler won't limit it"
Freezing or throttling WindowServer, loginwindow, the Dock, Control Center, launchd and similar processes would hang your session, so they're protected.

### Spotlight / iCloud / Photos analysis is using lots of CPU. Can I limit it?
Usually yes. `mds_stores`, `mdworker`, `photoanalysisd`, `mediaanalysisd`, `cloudd` and `bird` run as your user. Look in **Processes**, or search for "Spotlight", "iCloud" or "Photos".
- `photoanalysisd` and `mediaanalysisd` are safe to slow down; they catch up later.
- Limiting Spotlight or iCloud just makes indexing and sync slower.

Processes owned by `root` (e.g. `kernel_task`, `backupd`'s privileged parts) can't be limited.

### Everything I start from a terminal is slow after I put the terminal on efficiency cores
macOS passes the efficiency-core (background) policy on to processes an app starts. If Terminal, iTerm or an AI coding app (Claude, Cursor…) is on *Efficiency cores only*, the shells, builds and tests it launches run on the E-cores too. Turn the setting off for that app; AppWrangler then restores those child processes as well. Or keep it on deliberately for background-friendly terminals.

### "Efficiency cores only" doesn't seem to do anything
- The app has to do real CPU work for it to matter. Watch its CPU in the detail chart.
- On Intel Macs there are no efficiency cores; the setting only lowers priority and I/O.
- If AppWrangler couldn't apply it, the Activity log says so.

### The memory limit didn't stop the app from using more memory
macOS doesn't allow hard memory caps on other apps. AppWrangler *reacts* when the app stays over the limit for two measurements (about 4 seconds with the panel closed) by notifying you, freezing, quitting or force-quitting it. Choose **Freeze** or **Quit** if you want it enforced.

### An app is stuck "not responding" after AppWrangler stopped
That shouldn't happen any more. AppWrangler releases paused and efficiency-core apps when it quits, crashes or is killed. A small watchdog process (a second "AppWrangler" in Activity Monitor) restores everything even after `kill -9`, then exits. If an app is ever left suspended anyway:

```bash
kill -CONT <pid-of-the-app>          # or: killall -CONT "App Name"
```

Or simply quit and reopen the app.

### Why are there two AppWrangler processes?
The second, tiny one is the watchdog described above. It uses no CPU and exits together with AppWrangler.

### I limited a command in Terminal and nothing happens
A program running in a terminal's foreground can't be paused for CPU limiting: the shell would treat it as suspended (like Ctrl-Z) and detach it. AppWrangler skips CPU limits and freezing for such jobs and logs it in the Activity log. Efficiency cores still apply. Run the command in the background (`command &`) if you need a CPU limit.

### Launch at login doesn't work
Install AppWrangler in `/Applications` first, then toggle the setting. If macOS shows an error, check **System Settings → General → Login Items** and allow AppWrangler there.

### I don't get notifications
Allow them in **System Settings → Notifications → AppWrangler**, and check **Settings → General → Notifications** in AppWrangler.

### Runaway alerts are annoying
Raise the threshold or duration, or turn them off (**Settings → General → Runaway apps**). For a single app, choose **Ignore this app** on the alert.

### Does AppWrangler slow my Mac down?
It uses well under 1% of one core: about 0.2–0.5% with Auto mode and runaway alerts on (the defaults), and about 50 MB of memory. With the panel closed, it measures your apps (not every process) every 2 s for Auto mode, plus a light full scan every 5 s for runaway alerts. With Auto and runaway alerts off and no rules, it doesn't sample at all. Settings → Impact shows its actual cost on your Mac.

### Does it collect any data?
No. AppWrangler makes no network connections and has no analytics. Rules and preferences stay on your Mac.

### Can I run two copies?
No. A second instance exits immediately, because two copies would fight over the same apps. (Tests use a separate data folder via `APPWRANGLER_DATA_DIR`.)

### How do I move my rules to another Mac?
Use Settings → App Rules → share button → **Export Rules…**, then **Import Rules…** on the other Mac. Or use `appwrangler export` / `appwrangler import`.

### I used AppPolice before. Do I lose my limits?
No. On first launch AppWrangler imports AppPolice 2.x rules and AppPolice 1.x saved limits.

### Why does AppWrangler need to be outside the App Store sandbox?
The macOS sandbox forbids pausing or re-prioritising other apps, which is AppWrangler's whole job. It asks for no special permissions (no Accessibility, no Full Disk Access, no admin password).
