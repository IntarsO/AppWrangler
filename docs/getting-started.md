# Getting Started with AppWrangler

This guide takes you from download to your first limit in about five minutes.

**Requirements:** a Mac running macOS 13 Ventura or later. AppWrangler is built for Apple Silicon (M1 and later). An Intel build is possible (`./build.sh --universal`), but Intel Macs have no efficiency cores.

---

## 1. Install

### Option A — Homebrew

```bash
brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler
brew install --cask appwrangler
```

This installs **AppWrangler.app** in Applications and the `appwrangler` command. `brew upgrade --cask appwrangler` updates it later. The first launch needs one confirmation, as described in step 3 of Option B.

### Option B — download a release

1. Go to [Releases](https://github.com/IntarsO/AppWrangler/releases/latest) and download `AppWrangler-x.y.z.zip`.
2. Double-click the zip to unpack it, then drag **AppWrangler.app** into your **Applications** folder.
3. **First launch:** release builds are signed but not notarized by Apple, so macOS asks for confirmation once.
   - Right-click (or Control-click) **AppWrangler.app** → **Open** → **Open**.
   - If macOS only offers *Move to Bin*: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the AppWrangler message.
   - Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/AppWrangler.app`

### Option C — build from source

You only need Apple's free Command Line Tools; full Xcode is not required.

```bash
xcode-select --install                        # once; skip if already installed
git clone https://github.com/IntarsO/AppWrangler.git
cd AppWrangler
./build.sh --install --cli --run              # build, copy to /Applications, add the `appwrangler` command, launch
```

Apps you build yourself open without any Gatekeeper prompt.

---

## 2. Find it in the menu bar

AppWrangler has no Dock icon (except while its window is open). Look for the **lasso** icon (a loop with a gauge needle inside) in the menu bar at the top right of the screen.

- **Left-click** opens the main panel.
- **Right-click** gives quick access to *Pause All Limits*, *Open in a Window*, *Settings…*, *Help & Documentation* and *Quit AppWrangler*.

> Can't see it? On a crowded menu bar macOS may hide it behind the notch. Quit a few other menu bar apps, or hold ⌘ and drag icons to make room.

---

## 3. Take a look around

The panel shows:

- **At the top:** your Mac's chip (for example *Apple M1 · 4P + 4E · 8 GB*), total CPU use, and memory use with memory pressure.
- **In the list:** everything that's running, in four sections:
  - **Apps:** the apps you use, with a Dock icon.
  - **Menu bar & background apps:** things like Dropbox or menu bar utilities.
  - **macOS system services:** parts of macOS such as Wi-Fi or Control Center (collapsed by default).
  - **Processes:** command-line tools and background daemons (collapsed by default).

Each row shows:
- the name, plus a **+N** count of helper processes that are counted together with the app;
- a **one-line description of what it is**, such as "Web browser" or "Spotlight indexing your files";
- its current **CPU** (100% = one full core) and **memory**.

Click any row to open its details:
- what it is and who makes it;
- whether it's **safe to limit**;
- a 10-minute CPU and memory chart;
- its settings.

Want it on screen all the time? The window button at the top of the panel opens the same view in a normal window, like Activity Monitor. There's also a [desktop widget](user-manual.md#desktop-widget).

---

## 4. Auto mode is already working

You don't have to set anything up. **Auto mode** is on from the start:
- The app you're using (and anything playing or recording audio) runs at full speed.
- Other apps move to the efficiency cores 30 s after you leave them.
- When the Mac is busy, background apps share the CPU fairly.

The *Auto* line at the top of the panel shows what it's doing.

The yellow **Suggestions** section, when it appears, points out anything worth changing, such as an app using more memory than your Mac has. Each suggestion has a one-click button. If your Mac is short of memory, consider turning on *freeze apps I haven't used for a while* in Settings → General → Auto mode. See the [User Manual](user-manual.md#auto-mode).

---

## 5. Set your own limit (when you need one)

For most everyday apps, Auto mode is the better choice: a fixed limit can make an app feel slow. Use your own rule for things Auto doesn't manage, such as a build tool or a background process, or to set a memory limit. Say a sync app keeps using too much CPU:

1. Click it in the list.
2. Turn on **Limit CPU** and pick **25%** (or drag the slider). New rules apply only while the app is in the background.
3. Done. The limit is enforced within half a second. The row turns orange, and a gauge icon shows it's being throttled.

From now on, the limit applies **every time the app runs**, including after you restart your Mac.

Some other things to try:
- **Efficiency cores only** keeps the app on the low-power cores. It's great for apps you want running but not hogging the fast cores.
- **Only while the app is in the background** throttles it while you're working in another app, and lets it run at full speed when you switch to it.
- **Right-click a row** for one-click limits (10/25/50/100/200%), freezing, or quitting.

To remove a limit, turn the toggle off or click **Remove Rule**.

---

## 6. Recommended settings

Open **Settings…** (bottom of the panel, or right-click the menu bar icon):

- **General → Launch AppWrangler at login.** Install the app in /Applications first.
- **General → Runaway apps.** This is on by default: AppWrangler tells you when something burns CPU in the background for a few minutes.
- **General → Notifications.** Allow notifications when macOS asks, so you see runaway and memory alerts.
- **⌃⌥⌘P** pauses or resumes all CPU limits from anywhere.

---

## 7. Optional: the command line and AI assistants

If you installed with Homebrew, used `./build.sh --cli`, or linked it yourself (see Settings → General → Command line), you can do the same from Terminal:

```bash
appwrangler status                   # what Auto is doing, what's frozen
appwrangler suggest                  # recommended settings, with the command to apply each
appwrangler show Slack               # everything about one app
appwrangler set Slack efficiency_cores=on
appwrangler help
```

To let Claude or Codex look after your Mac, run `appwrangler mcp install` (see [AI assistants](mcp.md)).

See the [CLI reference](cli.md).

---

## Uninstall

1. Right-click the menu bar icon → **Quit AppWrangler**. Every limited or frozen app is released immediately.
2. If you enabled *Launch at login*, turn it off first in Settings → General, or later in **System Settings → General → Login Items**.
3. Delete `/Applications/AppWrangler.app`.
4. Optionally remove its data and preferences:

```bash
rm -rf ~/Library/Application\ Support/AppWrangler
defaults delete io.github.intarso.AppWrangler
rm -f /opt/homebrew/bin/appwrangler /usr/local/bin/appwrangler ~/.local/bin/appwrangler
```

---

**Next:** the [User Manual](user-manual.md) explains every feature in detail, and it's built into the app: click **?** in the panel, or the **?** next to any setting. Want advice? Run `appwrangler suggest` or ask your [AI assistant](mcp.md). Something not working? See the [FAQ](faq.md).
