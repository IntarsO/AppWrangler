//
//  MCP.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Model Context Protocol server: lets AI assistants (Claude Desktop, Claude
//  Code, OpenAI Codex, the OpenAI Agents SDK, …) audit what's running, analyse
//  AppWrangler's impact, and propose or apply limits.
//
//      AppWrangler mcp              all tools (clients ask you before each change)
//      AppWrangler mcp --read-only  audit/analysis tools only
//
//  Transport: JSON-RPC 2.0, one message per line on stdin/stdout. Logs go to stderr.
//

import AppKit

final class MCPServer {
	static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

	let readOnly: Bool
	private let directory: URL
	private let runningApps: () -> [RunningApp]
	private let postToApp: (String, String?) -> Bool
	private let sampleSeconds: Double
	/// Builds the suggestion engine's input (tests substitute a fixed one).
	private let suggestionInput: (RuleStore, [RunningApp], Double) -> SuggestionInput

	init(readOnly: Bool, directory: URL = DataDirectory.url,
		 runningApps: @escaping () -> [RunningApp] = { Array(RunningApps.collect().values) },
		 postToApp: @escaping (String, String?) -> Bool = CLI.postToApp,
		 sampleSeconds: Double = 1,
		 suggestionInput: ((RuleStore, [RunningApp], Double) -> SuggestionInput)? = nil) {
		self.readOnly = readOnly
		self.directory = directory
		self.runningApps = runningApps
		self.postToApp = postToApp
		self.sampleSeconds = sampleSeconds
		self.suggestionInput = suggestionInput ?? { store, apps, seconds in
			SuggestionInput.current(groups: Reports.sampleGroups(apps: apps, seconds: seconds), store: store,
									frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
		}
	}

	// MARK: Entry point

	/// Run over stdin/stdout until stdin closes.
	static func serve(readOnly: Bool) -> Never {
		let server = MCPServer(readOnly: readOnly)
		FileHandle.standardError.write("AppWrangler MCP server ready (\(readOnly ? "read-only" : "full access")).\n".data(using: .utf8)!)
		// Read on a background thread; handle on the main thread so NSWorkspace's
		// running-apps list keeps updating between requests.
		Thread.detachNewThread {
			while let line = readLine(strippingNewline: true) {
				let semaphore = DispatchSemaphore(value: 0)
				DispatchQueue.main.async {
					if let reply = server.handle(line) {
						FileHandle.standardOutput.write((reply + "\n").data(using: .utf8)!)
					}
					semaphore.signal()
				}
				semaphore.wait()
			}
			exit(0)
		}
		RunLoop.main.run()
		exit(0)
	}

	// MARK: JSON-RPC

	/// Handle one line; returns the response line, or nil for notifications.
	func handle(_ line: String) -> String? {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		guard let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
			return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
		}
		guard let message = parsed as? [String: Any] else {
			return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request (batches aren't supported)"]])
		}
		let id = message["id"]
		guard let method = message["method"] as? String else {
			if let id { return error(id, -32600, "Invalid request") }
			return nil
		}
		let params = message["params"] as? [String: Any] ?? [:]
		// Notifications (no id) get no reply.
		guard let id else { return nil }

		switch method {
		case "initialize":
			let requested = params["protocolVersion"] as? String ?? ""
			let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
			return result(id, [
				"protocolVersion": version,
				"capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
				"serverInfo": ["name": "appwrangler", "title": "AppWrangler",
							   "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
				"instructions": Self.instructions(readOnly: readOnly),
			])
		case "ping":
			return result(id, [:])
		case "tools/list":
			return result(id, ["tools": tools.map(\.descriptor)])
		case "tools/call":
			guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
				return error(id, -32602, "Unknown tool: \(params["name"] as? String ?? "?")")
			}
			let args = params["arguments"] as? [String: Any] ?? [:]
			let missing = tool.required.filter { key in
				guard let v = args[key] else { return true }
				return (v as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == true
			}
			guard missing.isEmpty else {
				return error(id, -32602, "Missing required argument(s): \(missing.joined(separator: ", "))")
			}
			let outcome = tool.run(args)
			var body: [String: Any] = ["content": [["type": "text", "text": outcome.text]], "isError": outcome.isError]
			if let structured = outcome.structured { body["structuredContent"] = structured }
			return result(id, body)
		case "prompts/list":
			return result(id, ["prompts": Self.prompts.map(\.descriptor)])
		case "prompts/get":
			guard let name = params["name"] as? String, let prompt = Self.prompts.first(where: { $0.name == name }) else {
				return error(id, -32602, "Unknown prompt")
			}
			let args = params["arguments"] as? [String: String] ?? [:]
			return result(id, ["description": prompt.description,
							   "messages": [["role": "user", "content": ["type": "text", "text": prompt.text(args)]]]])
		default:
			return error(id, -32601, "Method not found: \(method)")
		}
	}

	private func result(_ id: Any, _ value: [String: Any]) -> String {
		encode(["jsonrpc": "2.0", "id": id, "result": value])
	}

	private func error(_ id: Any, _ code: Int, _ message: String) -> String {
		encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
	}

	private func encode(_ object: [String: Any]) -> String {
		let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
		return String(decoding: data, as: UTF8.self)
	}

	// MARK: Tools

	struct Outcome {
		var text: String
		var structured: [String: Any]?
		var isError = false
	}

	/// Each call does something new (undo walks back further; free memory freezes again).
	static let notIdempotent: Set<String> = ["undo_last_change", "free_memory"]

	struct Tool {
		let name: String
		let title: String
		let description: String
		let properties: [String: Any]
		let required: [String]
		let readOnly: Bool
		let destructive: Bool
		let run: ([String: Any]) -> Outcome

		var descriptor: [String: Any] {
			[
				"name": name, "title": title, "description": description,
				"inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
				"annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
								"idempotentHint": readOnly || (!destructive && !MCPServer.notIdempotent.contains(name)), "openWorldHint": false],
			]
		}
	}

	private func store() -> RuleStore {
		RuleStore(directory: directory, defaults: Migration.legacyDefaults)
	}

	/// Run a CLI command against a fresh rule store and capture its output.
	private func cli(_ args: [String]) -> Outcome {
		let s = store()
		var lines: [String] = []
		let code = CLI.run(args, store: s, apps: runningApps(), print: { lines.append($0) }, postToApp: postToApp, source: "mcp")
		s.saveNow()
		let text = lines.joined(separator: "\n").replacingOccurrences(of: "  (AppWrangler isn't running — applies when it starts)", with: " (AppWrangler isn't running; applies when it starts)")
		return Outcome(text: text.isEmpty ? (code == 0 ? "Done." : "Failed.") : text, isError: code != 0)
	}

	private static let appProperty: [String: Any] = [
		"type": "string",
		"description": "App name (\"Google Chrome\"), bundle ID (com.google.Chrome), process name (node), path, or pattern (\"*Helper*\").",
	]

	private lazy var tools: [Tool] = {
		var all: [Tool] = [
			Tool(name: "get_status", title: "AppWrangler status",
				 description: "Whether AppWrangler is running, paused, what's frozen or flagged as a runaway, the Mac's chip, cores and memory, and battery/thermal/memory-pressure state.",
				 properties: [:], required: [], readOnly: true, destructive: false) { [unowned self] _ in
				let status = Reports.status(store: self.store())
				return Outcome(text: Reports.json(status), structured: status)
			},
			Tool(name: "list_apps", title: "List running apps",
				 description: "Measure running apps for about a second and return each one's CPU %, memory, energy, disk I/O, helper count, a plain description of what it is, how safe it is to limit, and its current rule. Sorted by CPU.",
				 properties: ["include_processes": ["type": "boolean", "description": "Also include command-line tools and background processes (default false)."],
							  "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Return at most this many (default 40)."]],
				 required: [], readOnly: true, destructive: false) { [unowned self] args in
				let limit = min(max(args["limit"] as? Int ?? 40, 1), 500)
				let rows = Reports.apps(store: self.store(), apps: self.runningApps(),
										includeProcesses: args["include_processes"] as? Bool ?? false,
										limit: limit, seconds: self.sampleSeconds)
				return Outcome(text: Reports.json(rows), structured: ["apps": rows])
			},
			Tool(name: "explain_app", title: "Explain an app",
				 description: "What a running app or process is, who makes it, whether it's safe to limit, its current usage and rule.",
				 properties: ["app": Self.appProperty], required: ["app"], readOnly: true, destructive: false) { [unowned self] args in
				let target = (args["app"] as? String ?? "").lowercased()
				let rows = Reports.apps(store: self.store(), apps: self.runningApps(), includeProcesses: true, seconds: self.sampleSeconds)
				let matches = rows.filter {
					($0["name"] as? String)?.lowercased() == target || ($0["bundleID"] as? String)?.lowercased() == target
						|| ($0["name"] as? String)?.lowercased().contains(target) == true
				}
				guard !matches.isEmpty else { return Outcome(text: "No running app or process matches \"\(target)\".", isError: true) }
				return Outcome(text: Reports.json(Array(matches.prefix(5))), structured: ["matches": Array(matches.prefix(5))])
			},
			Tool(name: "get_impact_stats", title: "Impact statistics",
				 description: "What AppWrangler achieved and cost: CPU time and estimated energy saved, time apps were held back/frozen/on E-cores, actions taken, AppWrangler's own CPU and memory, efficiency ratio, limit accuracy, per-app and per-day breakdowns. Savings are estimates.",
				 properties: ["period": ["type": "string", "enum": ["hour", "today", "week", "month"], "description": "Default week. 'hour' = the last clock hour."]],
				 required: [], readOnly: true, destructive: false) { [unowned self] args in
				let days = ["hour": 0, "today": 1, "week": 7, "month": 30][args["period"] as? String ?? "week"] ?? 7
				let stats = Reports.stats(directory: self.directory, days: days)
				return Outcome(text: Reports.json(stats), structured: stats)
			},
			Tool(name: "suggest_settings", title: "Suggest settings",
				 description: "Analyse what's running, memory and swap, the saved rules and the last week's impact, and recommend settings. Each suggestion has a severity, the reason, the expected benefit, an optional manual tip (e.g. a browser setting), and ready-to-call actions (tool + arguments, plus the equivalent CLI command). Changes nothing — present the suggestions and apply only the ones the user agrees to.",
				 properties: ["app": ["type": "string", "description": "Only suggestions about this app (name, bundle ID or part of the name)."],
							  "focus": ["type": "string", "enum": ["memory", "cpu", "battery", "rules", "auto"], "description": "Only this kind of suggestion."]],
				 required: [], readOnly: true, destructive: false) { [unowned self] args in
				let store = self.store()
				let input = self.suggestionInput(store, self.runningApps(), self.sampleSeconds)
				var list = Suggestions.make(input, app: (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 })
				if let focus = args["focus"] as? String { list = list.filter { $0.category.rawValue == focus } }
				let rows = list.map(\.json)
				let summary = list.isEmpty ? "No suggestions — everything looks well tuned right now."
					: "\(list.count) suggestion\(list.count == 1 ? "" : "s"): " + list.prefix(5).map(\.title).joined(separator: "; ")
				var structured: [String: Any] = ["summary": summary, "suggestions": rows, "autoMode": input.autoEnabled ? "on" : "off"]
				if self.readOnly { structured["note"] = "This server is read-only: show the user the CLI commands instead of calling the actions." }
				return Outcome(text: summary + "\n\n" + Reports.json(structured), structured: structured)
			},
			Tool(name: "get_app_settings", title: "App settings",
				 description: "Everything about one app: what it is, whether it's safe to limit, live CPU/memory/energy, every current setting (same keys configure_app takes, with an explanation of each), who manages it (its own rule, Auto mode, or nothing), what Auto is doing to it, and suggestions for it. Use this when the user talks about a specific app.",
				 properties: ["app": Self.appProperty], required: ["app"], readOnly: true, destructive: false) { [unowned self] args in
				let target = args["app"] as? String ?? ""
				let store = self.store()
				let apps = self.runningApps()
				guard let report = Reports.appSettings(target, store: store, apps: apps, input: self.suggestionInput(store, apps, self.sampleSeconds)) else {
					let groups = Reports.sampleGroups(apps: apps, seconds: 0.2)
					return Outcome(text: Reports.notFound(target, in: groups) + ". Check the name with list_apps.", isError: true)
				}
				return Outcome(text: Reports.json(report), structured: report)
			},
			Tool(name: "get_preferences", title: "App-wide settings",
				 description: "AppWrangler's app-wide settings (Settings → General): Auto mode and its timings, idle-app freezing, the low-memory level, runaway alerts, notifications, menu bar CPU and the pause shortcut — with what each means.",
				 properties: [:], required: [], readOnly: true, destructive: false) { _ in
				let prefs: [String: Any] = ["settings": PreferenceSettings.current(),
											"help": Dictionary(uniqueKeysWithValues: PreferenceSettings.specs.map { ($0.key, $0.help) })]
				return Outcome(text: Reports.json(prefs), structured: prefs)
			},
			Tool(name: "list_rules", title: "List rules",
				 description: "All saved per-app rules (limits, conditions, actions), including for apps that aren't running.",
				 properties: [:], required: [], readOnly: true, destructive: false) { [unowned self] _ in
				let rules = Reports.rules(store: self.store())
				return Outcome(text: Reports.json(rules), structured: ["rules": rules])
			},
		]
		guard !readOnly else { return all }
		all += [
			Tool(name: "configure_app", title: "Configure an app",
				 description: "Change any combination of an app's settings in one call; only the settings you pass change. Creates a rule if needed, and removes it when nothing is left (Auto mode then manages the app). Applies immediately. Use get_app_settings first to see the current values, and ask the user before changing anything.",
				 properties: Self.configureProperties, required: ["app"], readOnly: false, destructive: true) { [unowned self] args in
				self.configure(args)
			},
			Tool(name: "set_cpu_limit", title: "Set CPU limit",
				 description: "Cap an app's CPU (and its helpers'). 100 = one full core. Applies immediately and whenever the app runs.",
				 properties: ["app": Self.appProperty,
							  "percent": ["type": "number", "minimum": 1, "description": "Limit in percent of one core."],
							  "background_only": ["type": "boolean", "description": "Only limit while the app isn't frontmost."]],
				 required: ["app", "percent"], readOnly: false, destructive: false) { [unowned self] args in
				var cli = ["limit", args["app"] as? String ?? "", self.number(args["percent"])]
				if let b = args["background_only"] as? Bool { cli.append(b ? "--background-only" : "--always") }
				return self.cli(cli)
			},
			Tool(name: "set_efficiency_cores", title: "Efficiency cores only",
				 description: "Run an app on the efficiency cores with throttled disk/network I/O (saves energy, never pauses the app).",
				 properties: ["app": Self.appProperty, "enabled": ["type": "boolean"]],
				 required: ["app", "enabled"], readOnly: false, destructive: false) { [unowned self] args in
				self.cli(["ecores", args["app"] as? String ?? "", (args["enabled"] as? Bool ?? true) ? "on" : "off"])
			},
			Tool(name: "set_memory_limit", title: "Set memory limit",
				 description: "When the app's memory footprint stays above the limit: notify, freeze, quit or forcequit. Omit megabytes to remove the limit.",
				 properties: ["app": Self.appProperty,
							  "megabytes": ["type": "number", "minimum": 16],
							  "action": ["type": "string", "enum": ["notify", "freeze", "quit", "forcequit"], "description": "Default notify."]],
				 required: ["app"], readOnly: false, destructive: true) { [unowned self] args in
				guard args["megabytes"] != nil else { return self.cli(["memlimit", args["app"] as? String ?? "", "off"]) }
				return self.cli(["memlimit", args["app"] as? String ?? "", self.number(args["megabytes"]), args["action"] as? String ?? "notify"])
			},
			Tool(name: "set_low_memory_action", title: "Low-memory action",
				 description: "What to do with the app when the whole Mac runs low on memory: none, freeze (resumed when memory frees up) or quit.",
				 properties: ["app": Self.appProperty, "action": ["type": "string", "enum": ["none", "freeze", "quit"]]],
				 required: ["app", "action"], readOnly: false, destructive: true) { [unowned self] args in
				self.cli(["lowmem", args["app"] as? String ?? "", args["action"] as? String ?? "none"])
			},
			Tool(name: "set_rule_conditions", title: "Set rule conditions",
				 description: "Restrict when an app's existing rule applies: power source, Low Power Mode, when the Mac is hot, and/or a daily schedule.",
				 properties: ["app": Self.appProperty,
							  "power": ["type": "string", "enum": ["any", "battery", "charger"]],
							  "low_power_mode_only": ["type": "boolean"],
							  "hot_only": ["type": "boolean"],
							  "schedule": ["type": "object", "description": "Omit to leave unchanged; {\"enabled\": false} to remove.",
										   "properties": ["enabled": ["type": "boolean"],
														  "start": ["type": "string", "pattern": "^\\d{1,2}:\\d{2}$"],
														  "end": ["type": "string", "pattern": "^\\d{1,2}:\\d{2}$"],
														  "weekdays": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7],
																	   "description": "1 = Sunday … 7 = Saturday; empty = every day."]]]],
				 required: ["app"], readOnly: false, destructive: false) { [unowned self] args in
				self.setConditions(args)
			},
			Tool(name: "set_rule_enabled", title: "Enable or disable a rule",
				 description: "Turn an app's rule on or off without deleting it.",
				 properties: ["app": Self.appProperty, "enabled": ["type": "boolean"]],
				 required: ["app", "enabled"], readOnly: false, destructive: false) { [unowned self] args in
				self.cli([(args["enabled"] as? Bool ?? true) ? "enable" : "disable", args["app"] as? String ?? ""])
			},
			Tool(name: "remove_rule", title: "Remove rule",
				 description: "Delete an app's rule; its limits are lifted immediately.",
				 properties: ["app": Self.appProperty], required: ["app"], readOnly: false, destructive: true) { [unowned self] args in
				self.cli(["unlimit", args["app"] as? String ?? ""])
			},
			Tool(name: "freeze_app", title: "Freeze or unfreeze an app",
				 description: "Suspend a running app and its helpers now (frozen = 0 CPU, memory kept), or resume it. Needs AppWrangler running.",
				 properties: ["app": Self.appProperty, "frozen": ["type": "boolean"]],
				 required: ["app", "frozen"], readOnly: false, destructive: true) { [unowned self] args in
				self.cli([(args["frozen"] as? Bool ?? true) ? "freeze" : "unfreeze", args["app"] as? String ?? ""])
			},
			Tool(name: "set_auto_mode", title: "Auto mode",
				 description: "Auto mode keeps the focused app (and anything playing/recording audio) at full speed, moves other apps to efficiency cores after a short time in the background (30 s by default), and shares the CPU fairly between background apps only when the Mac is busy. Apps with their own CPU/E-core rule are not affected. Optionally (freeze_idle_apps) it also freezes regular apps you haven't used for idle_minutes while the Mac is low on memory; they resume the moment you switch to them or memory frees up. Messaging, calls and audio apps are never frozen.",
				 properties: ["enabled": ["type": "boolean", "description": "Auto mode on or off."],
							  "freeze_idle_apps": ["type": "boolean", "description": "Freeze idle apps when the Mac is low on memory (opt-in)."],
							  "idle_minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "How long an app must be unused before it may be frozen (default 10)."]],
				 required: [], readOnly: false, destructive: false) { [unowned self] args in
				var outcomes: [Outcome] = []
				if let on = args["enabled"] as? Bool { outcomes.append(self.cli(["auto", on ? "on" : "off"])) }
				if let freeze = args["freeze_idle_apps"] as? Bool {
					var a = ["auto", "freeze-idle", freeze ? "on" : "off"]
					if let m = args["idle_minutes"] as? Int { a.append(String(m)) }
					outcomes.append(self.cli(a))
				} else if let m = args["idle_minutes"] as? Int {
					outcomes.append(self.cli(["auto", "freeze-idle", UserDefaults.standard.bool(forKey: Prefs.autoFreezeIdle) ? "on" : "off", String(m)]))
				}
				guard !outcomes.isEmpty else { return Outcome(text: "Give enabled, freeze_idle_apps and/or idle_minutes.", isError: true) }
				return Outcome(text: outcomes.map(\.text).joined(separator: "\n"), isError: outcomes.contains { $0.isError })
			},
			Tool(name: "set_preferences", title: "Change app-wide settings",
				 description: "Change any of AppWrangler's app-wide settings (see get_preferences for the keys and ranges). Only the keys you pass change; nothing changes if a value is invalid. Applies immediately. Ask the user first.",
				 properties: Self.preferenceProperties, required: [], readOnly: false, destructive: false) { [unowned self] args in
				guard !args.isEmpty else { return Outcome(text: "Give at least one setting (see get_preferences).", isError: true) }
				do {
					let now = try PreferenceSettings.set(args)
					_ = self.postToApp("prefs", nil)
					return Outcome(text: "Saved. " + Reports.json(now), structured: ["settings": now])
				} catch {
					return Outcome(text: "\(error)", isError: true)
				}
			},
			Tool(name: "undo_last_change", title: "Undo last change",
				 description: "Revert the most recent rule change made through this server, the command line, a suggestion or a quick action in the app (up to the last 50, one per call). Returns what was restored. If the rule was edited elsewhere since, it refuses unless force is true — ask the user first. Auto-mode on/off isn't covered: use set_auto_mode.",
				 properties: ["force": ["type": "boolean", "description": "Undo even though the rule was changed elsewhere since (that change is lost)."]],
				 required: [], readOnly: false, destructive: true) { [unowned self] args in
				let s = self.store()
				let entry: ChangeJournal.Entry, message: String
				switch ChangeJournal.undoLast(store: s, force: args["force"] as? Bool ?? false) {
				case .nothing: return Outcome(text: "Nothing to undo.", structured: ["undone": false])
				case .conflict(_, let m): return Outcome(text: m, structured: ["undone": false, "conflict": true], isError: true)
				case .undone(let e, let m): entry = e; message = m
				}
				return Outcome(text: message, structured: ["undone": true, "app": entry.app, "message": message,
														   "settings": entry.before.map { AppSettings.settings($0) } ?? [:],
														   "rule": entry.before?.summary ?? "none"])
			},
			Tool(name: "free_memory", title: "Free memory now",
				 description: "Freeze regular apps the user hasn't used for a while (Auto mode's idle time, 10 min by default), whatever the memory pressure, so macOS can compress or swap their memory. Each resumes the moment the user switches to it. Never the app in use, audio, messaging/calls or menu bar apps. Needs AppWrangler running. Ask the user first.",
				 properties: [:], required: [], readOnly: false, destructive: true) { [unowned self] _ in
				self.cli(["free-memory"])
			},
			Tool(name: "pause_limits", title: "Pause or resume all limits",
				 description: "Pause all CPU limits (frozen apps stay frozen) or resume them. Needs AppWrangler running.",
				 properties: ["paused": ["type": "boolean"]], required: ["paused"], readOnly: false, destructive: false) { [unowned self] args in
				self.cli([(args["paused"] as? Bool ?? true) ? "pause" : "resume"])
			},
		]
		return all
	}()

	private func number(_ value: Any?) -> String {
		if let i = value as? Int { return String(i) }
		if let d = value as? Double { return String(d) }
		if let s = value as? String { return s }
		return ""
	}

	static let preferenceProperties: [String: Any] = {
		var p: [String: Any] = [:]
		for spec in PreferenceSettings.specs {
			switch spec.kind {
			case .bool: p[spec.key] = ["type": "boolean", "description": spec.help]
			case .number(let r): p[spec.key] = ["type": "number", "minimum": r.lowerBound, "maximum": r.upperBound, "description": spec.help]
			case .choice(let names): p[spec.key] = ["type": "string", "enum": names.keys.sorted(), "description": spec.help]
			}
		}
		return p
	}()

	static let configureProperties: [String: Any] = {
		var p: [String: Any] = ["app": appProperty]
		let help = Dictionary(uniqueKeysWithValues: RuleChanges.keys.map { ($0.key, $0.help) })
		func prop(_ key: String, _ schema: [String: Any]) { p[key] = schema.merging(["description": help[key] ?? ""]) { a, _ in a } }
		prop("cpu_limit", ["type": "number", "minimum": 0])
		prop("efficiency_cores", ["type": "boolean"])
		prop("background_only", ["type": "boolean"])
		prop("memory_limit_mb", ["type": "number", "minimum": 0])
		prop("memory_action", ["type": "string", "enum": ["notify", "freeze", "quit", "forcequit"]])
		prop("low_memory_action", ["type": "string", "enum": ["none", "freeze", "quit"]])
		prop("include_helpers", ["type": "boolean"])
		prop("enabled", ["type": "boolean"])
		prop("ignored", ["type": "boolean"])
		prop("use_auto", ["type": "boolean"])
		prop("power", ["type": "string", "enum": ["any", "battery", "charger"]])
		prop("low_power_mode_only", ["type": "boolean"])
		prop("hot_only", ["type": "boolean"])
		prop("schedule", ["type": "string", "pattern": "^(off|\\d{1,2}:\\d{2}-\\d{1,2}:\\d{2})$"])
		prop("weekdays", ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7]])
		return p
	}()

	private func configure(_ args: [String: Any]) -> Outcome {
		let s = store()
		let apps = runningApps()
		let target = args["app"] as? String ?? ""
		let current = RuleTargets.resolve(target, store: s, apps: apps, create: false)?.conditions.schedule ?? Schedule()
		let changes: RuleChanges
		do { changes = try RuleChanges.parse(args, current: current) } catch { return Outcome(text: "\(error)", isError: true) }
		let auto = UserDefaults.standard.bool(forKey: Prefs.autoEnabled)
		let pending = AppState.read() == nil ? " (AppWrangler isn't running; applies when it starts)" : ""
		let previous = RuleTargets.resolve(target, store: s, apps: apps, create: false)
		switch AppSettings.configure(target, changes: changes, store: s, apps: apps, source: "mcp") {
		case .failed(let message):
			return Outcome(text: message, isError: true)
		case .removed(let rule):
			let text = "\(rule.displayName): rule removed — " + (auto ? "Auto mode manages it now." : "no limits (Auto mode is off).") + pending
			return Outcome(text: text, structured: ["app": rule.displayName, "rule": "none", "managedBy": auto ? "auto" : "nothing",
													"previous": AppSettings.settings(previous), "undo": "undo_last_change"])
		case .saved(let rule, let before):
			let managed = AppSettings.managedBy(nil, rule: rule, autoEnabled: auto)
			return Outcome(text: "\(rule.displayName): \(rule.summary) (was: \(before))" + pending,
						   structured: ["app": rule.displayName, "rule": rule.summary, "before": before,
										"settings": AppSettings.settings(rule), "previous": AppSettings.settings(previous),
										"hadRule": previous != nil, "managedBy": managed, "undo": "undo_last_change"])
		}
	}

	private func setConditions(_ args: [String: Any]) -> Outcome {
		let s = store()
		let target = args["app"] as? String ?? ""
		guard let existing = RuleTargets.resolve(target, store: s, apps: runningApps(), create: false) else {
			return Outcome(text: "No rule for \"\(target)\". Create one first (e.g. configure_app).", isError: true)
		}
		var values = args.filter { ["power", "low_power_mode_only", "hot_only"].contains($0.key) }
		if let sched = args["schedule"] as? [String: Any] {
			values["schedule"] = sched.filter { ["enabled", "start", "end"].contains($0.key) }
			if let days = sched["weekdays"] { values["weekdays"] = days }
		}
		let changes: RuleChanges
		do { changes = try RuleChanges.parse(values, current: existing.conditions.schedule) } catch { return Outcome(text: "\(error)", isError: true) }
		var rule = existing
		changes.apply(to: &rule)
		ChangeJournal.record(before: existing, after: rule, source: "mcp", store: s)
		s.upsert(rule)
		s.saveNow()
		return Outcome(text: "\(rule.displayName): \(rule.summary)", structured: ["rule": rule.displayName, "summary": rule.summary])
	}

	// MARK: Prompts

	struct Prompt {
		let name: String
		let description: String
		let arguments: [[String: Any]]
		let text: ([String: String]) -> String
		var descriptor: [String: Any] { ["name": name, "description": description, "arguments": arguments] }
	}

	static let prompts: [Prompt] = [
		Prompt(name: "audit_mac", description: "Audit this Mac's resource use and how well AppWrangler's rules are working, and suggest improvements.",
			   arguments: [["name": "focus", "description": "battery, performance or memory (optional)", "required": false]]) { args in
			let focus = args["focus"].map { " Focus on \($0)." } ?? ""
			return """
			Audit my Mac's resource usage with AppWrangler.\(focus)
			1. Call get_status, suggest_settings, list_apps (include_processes: true), list_rules and get_impact_stats (period: week).
			2. Identify what uses the most CPU, memory and energy — especially in the background — and explain in plain words what each of those apps is.
			3. Judge whether my existing rules are working: compare wanted vs allowed CPU, time held back, savings, and AppWrangler's own cost and limit accuracy.
			4. Recommend specific changes (start from suggest_settings; add your own: new limits, efficiency cores, memory or low-memory actions, conditions such as "only on battery"), each with the reason and expected benefit. Prefer leaving apps to Auto mode over fixed limits that also apply while I use them. Avoid apps marked protected, and be careful with ones marked caution.
			Show them as a numbered list. Don't apply any change until I confirm; then apply exactly the ones I pick (configure_app) and confirm what changed. If configure_app isn't available (read-only server), give me the `appwrangler` commands to run instead.
			"""
		},
		Prompt(name: "tune_app", description: "Look at one app, explain what it is and how it's managed, and suggest the best settings for it.",
			   arguments: [["name": "app", "description": "App name, e.g. Slack", "required": true]]) { args in
			let app = args["app"] ?? "the app I name"
			return """
			Help me tune \(app) with AppWrangler.
			1. Call get_app_settings for \(app) (and suggest_settings with app: \(app)).
			2. Tell me in plain words what it is, how much CPU, memory and energy it uses now, whether it's safe to limit, and who manages it (its own rule, Auto mode, or nothing).
			3. Recommend settings for how I use it (e.g. full speed while focused, efficiency cores in the background, a memory warning, a low-memory freeze unless it's a messaging/calls app), with the reason and expected benefit for each.
			Don't change anything until I confirm; then apply exactly what I agree to with configure_app and show the before → after. If configure_app isn't available (read-only server), give me the `appwrangler set` command instead.
			"""
		},
		Prompt(name: "explain_impact", description: "Summarise in plain words what AppWrangler has saved and what it cost.",
			   arguments: [["name": "period", "description": "today, week or month", "required": false]]) { args in
			"Call get_impact_stats (period: \(args["period"] ?? "week")) and explain in plain words what AppWrangler saved (CPU time, estimated energy, battery share), which apps benefited most, what it cost to run, and how efficient it was. Mention that savings are estimates."
		},
	]

	static func instructions(readOnly: Bool) -> String {
		"""
		AppWrangler limits per-app CPU, runs apps on efficiency cores, and enforces memory limits on this Mac. \
		Auto mode (see get_status → autoMode) keeps the focused app at full speed and manages background apps; \
		prefer it over fixed limits that also apply while an app is in use. \
		Use get_status, list_apps, explain_app, list_rules and get_impact_stats to audit and analyse. \
		When the user asks for advice, call suggest_settings; when they talk about a specific app, call get_app_settings for it \
		and offer the matching configure_app changes (one call can change any of its settings). \
		If the user wants to revert, call undo_last_change (once per change). \
		CPU percentages are per core (100 = one full core). Savings in get_impact_stats are estimates. \
		\(readOnly ? "This server is read-only." : "Changes apply immediately to the running app; ask the user before changing rules, and never limit apps marked protected.")
		"""
	}
}
