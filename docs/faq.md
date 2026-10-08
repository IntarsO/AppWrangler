# FAQ & Troubleshooting

### macOS says AppWrangler "can't be opened" or "is damaged"
Release builds are signed but not notarized by Apple. For the first launch:
- right-click the app → **Open** → **Open**; or
- go to **System Settings → Privacy & Security → Open Anyway**; or
- run `xattr -dr com.apple.quarantine /Applications/AppWrangler.app`.

Builds you make yourself with `./build.sh` aren't affected.

### I can't find the menu bar icon
AppWrangler has no Dock icon; it lives in the menu bar (a lasso loop with a needle inside). On MacBooks with a notch, a full menu bar can hide icons behind the notch. Quit a few other menu bar apps, or rearrange icons by ⌘-dragging. `appwrangler status` tells you whether it's running.

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

### "Efficiency cores only" doesn't seem to do anything
- The app has to do real CPU work for it to matter. Watch its CPU in the detail chart.
- On Intel Macs there are no efficiency cores; the setting only lowers priority and I/O.
- If AppWrangler couldn't apply it, the Activity log says so.

### The memory limit didn't stop the app from using more memory
macOS doesn't allow hard memory caps on other apps. AppWrangler *reacts* when the app stays over the limit for two measurements (about 4 seconds with the panel closed) by notifying you, freezing, quitting or force-quitting it. Choose **Freeze** or **Quit** if you want it enforced.

### An app is stuck "not responding" after AppWrangler was force-killed
AppWrangler releases every app it paused when it quits, crashes or receives a normal `kill`. The one thing it can't intercept is `kill -9` (SIGKILL) of AppWrangler itself, e.g. from Activity Monitor's **Force Quit** at an unlucky moment. If an app is left suspended:

```bash
kill -CONT <pid-of-the-app>          # or: killall -CONT "App Name"
```

Or simply quit and reopen the app.

### Launch at login doesn't work
Install AppWrangler in `/Applications` first, then toggle the setting. If macOS shows an error, check **System Settings → General → Login Items** and allow AppWrangler there.

### I don't get notifications
Allow them in **System Settings → Notifications → AppWrangler**, and check **Settings → General → Notifications** in AppWrangler.

### Runaway alerts are annoying
Raise the threshold or duration, or turn them off (**Settings → General → Runaway apps**). For a single app, choose **Ignore this app** on the alert.

### Does AppWrangler slow my Mac down?
It uses about 0.1–0.3% of one core while limiting apps or scanning for runaways, and about 50 MB of memory. With the panel closed it only measures apps that have rules, and if there's nothing to do it doesn't measure at all.

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
