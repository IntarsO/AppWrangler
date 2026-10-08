# Command-line reference

The `appwrangler` command is built into the app itself (`AppWrangler.app/Contents/MacOS/AppWrangler`). Homebrew installs it for you. Otherwise, add it to your `PATH`:

```bash
./build.sh --install --cli            # when building from source
# or link it yourself:
ln -sf /Applications/AppWrangler.app/Contents/MacOS/AppWrangler /opt/homebrew/bin/appwrangler
```

**How changes apply:**
- Rule changes are written to `rules.json`. The running app notices within about half a second and enforces them immediately, with no restart.
- If the app isn't running, rules apply when it starts.
- `freeze`, `unfreeze`, `pause`, `resume` and `free-memory` act on the running app, so they need AppWrangler to be running.

## Naming apps

`<app>` can be any of:

| Form | Example | Creates/finds a rule matched by |
|---|---|---|
| Name of a running app (any case) | `"Google Chrome"`, `slack` | its bundle ID |
| Name of an installed app that isn't running | `Safari` | its bundle ID |
| Part of a running app's name, if only one app matches | `chrome` | that app's bundle ID |
| Bundle ID | `com.google.Chrome` | bundle ID |
| Path | `/opt/homebrew/bin/node` | path |
| Pattern with `*` or `?` | `"*Helper*"` | name pattern |
| Anything else | `node` | process name (any case) |

- **Existing rules first.** An existing rule is found by its display name or match value, so `appwrangler limit Slack 40` and then `appwrangler limit Slack 60` update the same rule.
- **Ambiguous names are refused.** If a partial name matches several running apps (`code` for Xcode and Visual Studio Code), AppWrangler lists them and asks for the full name instead of guessing.
- **Critical processes are refused.** Processes critical to macOS (WindowServer, Dock, …) can't be limited, in any letter case.
- **Overly broad patterns are refused.** That covers patterns that would match nearly everything, such as `*` or `*a*`.

## Commands

### `list [--all] [--json]`
Lists running apps with CPU, memory, helper count and either their rule or a description of what they are. It measures for one second. `--all` includes plain processes. `--json` gives machine-readable output.

```text
   CPU     MEMORY  NAME                              WHAT IT IS
  27.2%    1,55 GB  Claude +16                        AI assistant (Claude)
   1.8%    5,48 GB  Brave Browser +35                 Web browser (privacy-focused)
```

### `rules`
Shows saved rules: ● enabled, ○ disabled.

### `suggest [app] [--json]`
Recommends settings for what's running: memory hogs when the Mac is short of memory (with browser tab-sleeping tips), busy unmanaged background processes, rules that slow an app while you use it, limits that are too strict, memory limits an app is always over, and rules for apps that no longer exist. Each suggestion gives the reason, the expected benefit and the command to apply it. Nothing changes until you run one. Give an app name to see only suggestions about it. [More](user-manual.md#suggestions-what-to-change).

```text
1. [medium] Slack is limited even while you use it
   Why: Its rule (CPU 30%) also applies when it's the frontmost app, which makes it feel slow and laggy.
   Benefit: Full speed while you use it, still efficient in the background.
   → Only limit it in the background:  appwrangler set Slack background_only=true
   → Hand it to Auto mode:  appwrangler set Slack use_auto=true
```

### `show <app> [--json]`
Everything about one app: what it is, whether it's safe to limit, CPU/memory/processes right now, who manages it (its own rule, Auto mode, or nothing), what Auto is doing to it, every setting, and suggestions for it.

### `set <app> key=value …`
Changes any combination of an app's settings in one command; only the settings you name change:

```bash
appwrangler set Slack efficiency_cores=on background_only=true
appwrangler set "Brave Browser" memory_limit_mb=6144 low_memory_action=freeze
appwrangler set Dropbox efficiency_cores=on power=battery schedule=09:00-18:00 weekdays=2,3,4,5,6
appwrangler set Slack use_auto=true      # remove its own CPU settings; Auto mode manages it
```

Keys: `cpu_limit` (0 = off), `efficiency_cores`, `background_only`, `memory_limit_mb` (0 = off), `memory_action`, `low_memory_action`, `include_helpers`, `enabled`, `ignored`, `use_auto`, `power`, `low_power_mode_only`, `hot_only`, `schedule` (`HH:MM-HH:MM` or `off`), `weekdays`. Booleans accept `true/false`, `on/off` or `yes/no`. The [full table](user-manual.md#every-setting-of-an-app) explains each one. A rule left with nothing in it is removed, so Auto mode manages the app again.

### `status`
Shows whether AppWrangler is running, whether limits are paused, what's frozen, any apps currently flagged by [runaway alerts](user-manual.md#runaway-alerts), and how many rules are active.

### `auto [on|off]`
Turns [Auto mode](user-manual.md#auto-mode) on or off. Without an argument, shows whether it's on. `status` also shows what Auto is doing (apps managed, in use, on E-cores, capped).

### `auto freeze-idle on|off [minutes]`
When the Mac is low on memory, Auto mode freezes regular apps you haven't used for `minutes` (default 10). They resume the moment you switch to them, or when memory frees up. Messaging, calls and audio apps and menu bar apps are never frozen. Off by default. [More](user-manual.md#auto-mode).

### `undo [--force]`
Reverts the last rule change made from the command line, an AI assistant, a suggestion in the panel, a runaway alert's buttons or the right-click quick actions. Run it again to go further back (up to 50 changes).

If the rule was edited in AppWrangler's window after that change, `undo` stops rather than lose your edit. Add `--force` to undo anyway.

### `prefs [key=value …]`
Without arguments, lists the app-wide settings (Settings → General) with their current values and what each means. With `key=value` pairs, changes them:

```bash
appwrangler prefs freeze_idle=on freeze_idle_minutes=30 low_memory_level=warning
appwrangler prefs auto_efficiency_after=60 runaway_alerts=off
```

Keys: `auto`, `auto_efficiency_cores`, `auto_efficiency_after` (s), `auto_share_cpu`, `auto_busy_percent`, `freeze_idle`, `freeze_idle_minutes`, `low_memory_level` (`warning`/`critical`), `runaway_alerts`, `runaway_percent`, `runaway_minutes`, `notifications`, `menu_bar_cpu`, `pause_shortcut`. Values are checked first: nothing changes if one is invalid. `--json` prints the current values as JSON.

### `free-memory`
Freezes the apps you haven't used for a while, right now, whatever the memory pressure. Each app resumes the moment you switch to it. It never freezes the app in use, audio, busy apps, messaging and calls apps, terminals, IDEs, virtual machines or menu bar apps. [More](user-manual.md#free-memory-now).

### `mcp install|uninstall|status [--read-only] [claude-desktop|claude-code|codex]`
Adds AppWrangler's MCP server to Claude Desktop, Claude Code and OpenAI Codex, or removes it, or shows where it's configured. Each config file is backed up first. Quit Claude Desktop before installing. [More](mcp.md#the-quick-way).

### `stats [hour|today|week|month] [--json]`
Shows what AppWrangler achieved and what it cost over the last clock hour, today, the last 7 days (default) or 30 days:
- CPU time saved and estimated energy saved;
- time apps were held back, frozen or on E-cores;
- actions taken;
- AppWrangler's own CPU and memory, its efficiency ratio and limit accuracy;
- a per-app breakdown.

The running app updates the numbers every 30 seconds.

```text
AppWrangler impact — today

  CPU time saved      2.4 core-h
  Energy saved (est.) 13.1 Wh  (17.6% of battery)
  ...
  AppWrangler itself  0.2% CPU on average, 41 core-s total, 48 MB memory
  Efficiency          saved 210× more CPU time than it used
```

### `limit <app> <percent> [--background-only | --always]`
Caps CPU (100 = one core). New rules apply only while the app isn't frontmost, so it runs at full speed while you use it. `--always` applies the limit even then; `--background-only` switches back. Updating an existing rule keeps its setting unless you pass one of the flags.

```bash
appwrangler limit "Google Chrome" 150
appwrangler limit Slack 25            # background only (the default for new rules)
appwrangler limit ffmpeg 200 --always
```

### `ecores <app> on|off`
Runs the app on efficiency cores only (also slows its disk and network access).

### `memlimit <app> <MB>|off [notify|freeze|quit|forcequit]`
Sets the memory limit and what to do when it's exceeded (default `notify`).

```bash
appwrangler memlimit Docker 4096 freeze
appwrangler memlimit Docker off
```

### `lowmem <app> none|freeze|quit`
Sets what happens to the app when the whole Mac is low on memory.

### `enable <app>` / `disable <app>`
Turns a rule on or off without deleting it.

### `ignore <app>`
Excludes the app from runaway suggestions and automatic actions.

### `unlimit <app>`
Deletes the app's rule. Its limits are lifted immediately.

### `freeze <app>` / `unfreeze <app>`
Suspends or resumes a running app and its helpers now. Needs AppWrangler running. Fails (exit code 1) if no running app or process has that name. A command in a terminal's foreground is never frozen.

### `pause` / `resume`
Pauses or resumes all CPU limits. Frozen apps stay frozen.

### `export [file]` / `import <file>`
Saves rules as JSON (to stdout if no file is given), or merges rules from a file. A rule for the same app replaces the existing one.

### `help`
Shows usage.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Bad arguments, unknown app/rule, or AppWrangler not running (for `freeze`/`pause`…) |

## Environment

| Variable | Effect |
|---|---|
| `APPWRANGLER_DATA_DIR` | Use a different data folder (rules, status). Used by the test suite; an app started with it runs fully independently. |

## Scripting examples

```bash
# Freeze a noisy sync client while recording audio, then let it catch up
appwrangler freeze Dropbox && record-podcast.sh; appwrangler unfreeze Dropbox

# Back up rules nightly (e.g. from cron or launchd)
appwrangler export ~/Backups/appwrangler-rules-$(date +%F).json

# Top 5 CPU users as JSON
appwrangler list --all --json | jq '.[0:5] | .[] | {name, cpuPercent}'
```
