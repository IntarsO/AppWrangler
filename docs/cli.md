# Command-line reference

The `appwrangler` command is built into the app itself (`AppWrangler.app/Contents/MacOS/AppWrangler`). To add it to your `PATH`:

```bash
./build.sh --install --cli            # when building from source
# or link it yourself:
ln -sf /Applications/AppWrangler.app/Contents/MacOS/AppWrangler /opt/homebrew/bin/appwrangler
```

**How changes apply:**
- Rule changes are written to `rules.json`. The running app notices within about half a second and enforces them immediately, with no restart.
- If the app isn't running, rules apply when it starts.
- `freeze`, `unfreeze`, `pause` and `resume` act on the running app, so they need AppWrangler to be running.

## Naming apps

`<app>` can be any of:

| Form | Example | Creates/finds a rule matched by |
|---|---|---|
| Name of a running app (any case) | `"Google Chrome"`, `slack` | its bundle ID |
| Bundle ID | `com.google.Chrome` | bundle ID |
| Path | `/opt/homebrew/bin/node` | path |
| Pattern with `*` or `?` | `"*Helper*"` | name pattern |
| Anything else | `node` | process name |

An existing rule is found by its display name or match value, so `appwrangler limit Slack 40` and then `appwrangler limit Slack 60` update the same rule.

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

### `status`
Shows whether AppWrangler is running, whether limits are paused, what's frozen, any apps currently flagged by [runaway alerts](user-guide.md#runaway-alerts), and how many rules are active.

### `auto [on|off]`
Turns [Auto mode](user-guide.md#auto-mode) on or off. Without an argument, shows whether it's on. `status` also shows what Auto is doing (apps managed, in use, on E-cores, capped).

### `stats [today|week|month] [--json]`
Shows what AppWrangler achieved and what it cost over today, the last 7 days (default) or 30 days:
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
Suspends or resumes a running app and its helpers now. Needs AppWrangler running.

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
