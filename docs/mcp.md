# Using AppWrangler with AI assistants (MCP)

AppWrangler includes a **Model Context Protocol (MCP) server**, so AI assistants such as Claude Desktop, Claude Code, OpenAI Codex and agents built with the OpenAI Agents SDK can:

- **audit** what's running on your Mac and what each app is;
- **analyse** how well your rules work and how much AppWrangler has saved, and at what cost;
- **advise**: suggest settings for what's running, each with the reason, the expected benefit and a ready-to-apply change;
- **configure** any app while you talk about it ("make Slack use efficiency cores in the background"), with your approval.

The server is built into the app. There's nothing extra to install: the assistant starts it as

```
/Applications/AppWrangler.app/Contents/MacOS/AppWrangler mcp
```

It runs locally, speaks MCP over stdin/stdout, and never opens a network port. For the server to see live data and enforce changes, keep **AppWrangler running** in the menu bar. Rule changes are written to your rules file and apply within about half a second.

## Read-only or full access

| Mode | Command | Tools |
|---|---|---|
| **Read-only** (audit, analyse, advise) | `AppWrangler mcp --read-only` | `get_status`, `list_apps`, `explain_app`, `get_app_settings`, `suggest_settings`, `get_impact_stats`, `list_rules` |
| **Full** (also change settings) | `AppWrangler mcp` | the above plus `configure_app`, `set_auto_mode`, `set_cpu_limit`, `set_efficiency_cores`, `set_memory_limit`, `set_low_memory_action`, `set_rule_conditions`, `set_rule_enabled`, `remove_rule`, `freeze_app`, `pause_limits` |

In full mode, every tool that changes something is marked as such, so MCP clients ask you before running it. Tools that can freeze, quit or remove things are marked *destructive*. Start with `--read-only` if you only want insight.

## Setup

### Claude Desktop

Open **Claude → Settings → Developer → Edit Config**. This edits `~/Library/Application Support/Claude/claude_desktop_config.json`. Add:

```json
{
  "mcpServers": {
    "appwrangler": {
      "command": "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler",
      "args": ["mcp"]
    }
  }
}
```

Use `["mcp", "--read-only"]` for audit-only access. Restart Claude Desktop, and AppWrangler's tools appear in the tools menu.

### Claude Code

```bash
claude mcp add appwrangler -- /Applications/AppWrangler.app/Contents/MacOS/AppWrangler mcp
```

Add `--scope user` to make it available in every project.

### OpenAI Codex (CLI / IDE)

```bash
codex mcp add appwrangler -- /Applications/AppWrangler.app/Contents/MacOS/AppWrangler mcp
```

or add to `~/.codex/config.toml`:

```toml
[mcp_servers.appwrangler]
command = "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler"
args = ["mcp"]
```

### OpenAI Agents SDK (Python)

```python
from agents import Agent, Runner
from agents.mcp import MCPServerStdio

async with MCPServerStdio(params={
    "command": "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler",
    "args": ["mcp", "--read-only"],
}) as appwrangler:
    agent = Agent(name="Mac auditor", mcp_servers=[appwrangler],
                  instructions="Audit this Mac's resource use with AppWrangler.")
    result = await Runner.run(agent, "Which background apps waste the most battery?")
    print(result.final_output)
```

### ChatGPT

ChatGPT connects to MCP servers through *Developer Mode* or workspace connectors, which expect a **hosted (HTTP) server**, not a local program. AppWrangler deliberately only runs locally over stdio and doesn't expose control of your Mac over the network. So use Codex, the Agents SDK, or any other MCP client that can launch local servers.

## Tools

| Tool | What it does |
|---|---|
| `get_status` | Is AppWrangler running or paused, what's frozen or flagged as a runaway; chip, cores, memory; battery, Low Power, thermal and memory-pressure state |
| `list_apps` | Measures running apps (about 1 s). Per app: CPU %, memory, energy (W), disk I/O, helper count, a plain description, vendor, how safe it is to limit, and its current rule |
| `explain_app` | The same details for one app or process, found by name or bundle ID |
| `get_impact_stats` | CPU and energy saved, time held back / frozen / on E-cores, actions taken, AppWrangler's own CPU and memory, efficiency ratio, limit accuracy, per-app and per-day breakdowns (`hour` / `today` / `week` / `month`) |
| `list_rules` | All rules with their limits, conditions and actions |
| `suggest_settings` | Recommended settings (see [below](#suggestions-and-per-app-settings)). Optional `app` (only that app) and `focus` (`memory`, `cpu`, `battery`, `rules`, `auto`). Changes nothing |
| `get_app_settings` | `app`: what it is, whether it's safe to limit, live usage, **every setting** (with the keys `configure_app` takes and what each means), who manages it (own rule / Auto / nothing), what Auto is doing to it, and suggestions for it |
| `configure_app` | `app` plus any combination of `cpu_limit`, `efficiency_cores`, `background_only`, `memory_limit_mb`, `memory_action`, `low_memory_action`, `include_helpers`, `enabled`, `ignored`, `use_auto`, `power`, `low_power_mode_only`, `hot_only`, `schedule` (`"09:00-18:00"` / `"off"`), `weekdays`. Only what you pass changes ([all settings](user-manual.md#every-setting-of-an-app)) |
| `set_auto_mode` | `enabled`: Auto mode on or off ([how it works](user-manual.md#auto-mode)) |
| `set_cpu_limit` | `app`, `percent` (100 = one core), optional `background_only` |
| `set_efficiency_cores` | `app`, `enabled` |
| `set_memory_limit` | `app`, `megabytes`, `action` (`notify`/`freeze`/`quit`/`forcequit`); omit `megabytes` to remove the limit |
| `set_low_memory_action` | `app`, `action` (`none`/`freeze`/`quit`) |
| `set_rule_conditions` | `app` plus any of `power` (`any`/`battery`/`charger`), `low_power_mode_only`, `hot_only`, `schedule` (`{start: "09:00", end: "17:30", weekdays: [2,3,4,5,6]}`) |
| `set_rule_enabled` | Turn a rule on or off |
| `remove_rule` | Delete a rule and lift its limits |
| `freeze_app` | `app`, `frozen` (true to suspend, false to resume) |
| `pause_limits` | `paused` (frozen apps stay frozen) |

The older single-purpose tools (`set_cpu_limit`, `set_memory_limit`, …) still work; `configure_app` does all of them in one call.

The server also offers ready-made **prompts**:
- `audit_mac` audits resource use and how well your rules work, and suggests improvements. It takes an optional focus: battery, performance or memory. It doesn't apply anything until you confirm.
- `tune_app` looks at one app (`app`), explains what it is and how it's managed, recommends settings, and applies the ones you agree to.
- `explain_impact` explains, in plain words, what AppWrangler saved and what it cost.

## Suggestions and per-app settings

`suggest_settings` checks what's running, memory and swap, your rules and last week's statistics ([what it looks for](user-manual.md#suggestions-what-to-change)). Every suggestion carries ready-to-call actions, so the assistant can apply exactly the one you pick:

```json
{
  "id": "memory-hog:bundle:com.brave.Browser",
  "severity": "high",
  "category": "memory",
  "app": "Brave Browser",
  "title": "Brave Browser uses 9.7 GB — more than this Mac's 8 GB of RAM",
  "reason": "Your Mac is short of memory and Brave Browser is one of the biggest users.",
  "benefit": "Less swapping, so the app you're using stays responsive.",
  "tip": "Turn on the browser's tab sleeping: brave://settings/system → Memory Saver.",
  "actions": [{
    "label": "Freeze it in the background when memory runs out",
    "tool": "configure_app",
    "arguments": {"app": "Brave Browser", "low_memory_action": "freeze"},
    "cli": "appwrangler set \"Brave Browser\" low_memory_action=freeze"
  }]
}
```

When you talk about a particular app, the assistant calls `get_app_settings` for it and can change any of its settings with one `configure_app` call. The same information and changes are available without AI: `appwrangler suggest`, `appwrangler show <app>` and `appwrangler set <app> key=value …` ([CLI](cli.md)).

## Things to ask

- *"Use AppWrangler to audit my Mac. What's using my battery in the background?"*
- *"How much has AppWrangler saved this week, and is it worth what it costs to run?"*
- *"Are my limits too strict anywhere? Compare what each app wanted with what it got."*
- *"Put Slack and WhatsApp on efficiency cores, but only on battery."*
- *"What is mds_stores and is it safe to limit?"*
- *"Any suggestions? My Mac feels slow."*
- *"How is Slack set up, and what would you change?"*
- *"Make Slack run on efficiency cores only while it's in the background."*
- *"Warn me when Brave goes over 6 GB, and freeze it in the background if memory runs out."*
- *"Hand WhatsApp back to Auto mode."*

## Privacy & safety

- Everything stays on your Mac. The server only reads process information and AppWrangler's own files, and writes your rules file (and AppWrangler's Auto-mode preference, for `set_auto_mode`).
- What the AI sees (app names, usage figures, rules) is sent to whichever AI service your client uses, as with anything you share in a chat.
- The server has the same powers as the `appwrangler` command line, and processes critical to macOS stay protected.
- `--read-only` removes every tool that can change anything.
