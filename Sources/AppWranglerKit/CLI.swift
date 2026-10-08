//
//  CLI.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  `appwrangler` command line, built into the app binary:
//      AppWrangler.app/Contents/MacOS/AppWrangler limit Safari 50
//  Rule edits go to rules.json, which the running app watches and applies
//  immediately; freeze/pause go to the running app as distributed notifications.
//

import AppKit
import ProcKit

enum RunningApps {
	/// Apps registered with the window server, keyed by pid.
	static func collect() -> [pid_t: RunningApp] {
		let me = getpid()
		let running = NSWorkspace.shared.runningApplications.filter {
			$0.activationPolicy != .prohibited && $0.processIdentifier != me && !$0.isTerminated
		}
		let bundlePaths = Set(running.compactMap { $0.bundleURL?.path })
		var map: [pid_t: RunningApp] = [:]
		for app in running {
			let path = app.bundleURL?.path
			// An app nested in another app's bundle is that app's helper.
			if let path, bundlePaths.contains(where: { $0 != path && path.hasPrefix($0 + "/") }) { continue }
			// Some apps (e.g. WhatsApp) put invisible bidi marks in their names.
			let name = (app.localizedName
				?? path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
				?? "pid \(app.processIdentifier)")
				.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").union(.whitespaces))
			let kind: AppKind
			if app.activationPolicy == .regular {
				kind = .app
			} else if path?.hasPrefix("/System/") == true || app.bundleIdentifier?.hasPrefix("com.apple.") == true {
				kind = .system
			} else {
				kind = .background
			}
			map[app.processIdentifier] = RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
													name: name, bundlePath: path, kind: kind)
		}
		return map
	}
}

enum CLI {
	static let commands: Set<String> = [
		"help", "list", "rules", "status", "stats", "auto", "limit", "unlimit", "ecores", "memlimit", "lowmem",
		"enable", "disable", "ignore", "freeze", "unfreeze", "pause", "resume", "export", "import",
		"suggest", "show", "set", "undo", "free-memory", "prefs",
	]

	static func isInvocation(_ args: [String]) -> Bool {
		guard args.count > 1 else { return false }
		return commands.contains(args[1]) || ["-h", "--help"].contains(args[1])
	}

	/// Entry point from main.swift.
	static func main(_ args: [String]) -> Int32 {
		let store = RuleStore(defaults: Migration.legacyDefaults)
		let code = run(Array(args.dropFirst()), store: store, apps: Array(RunningApps.collect().values),
					   print: { Swift.print($0) }, postToApp: postToApp)
		store.saveNow()
		return code
	}

	static func postToApp(_ command: String, _ target: String?) -> Bool {
		guard AppState.read() != nil else { return false }
		var info: [String: String] = ["command": command, "dataDir": IPC.dataDirKey]
		if let target { info["target"] = target }
		DistributedNotificationCenter.default().postNotificationName(IPC.command, object: nil, userInfo: info, deliverImmediately: true)
		return true
	}

	/// Testable core: no globals, output via `print`.
	/// - Parameter source: who made the change ("cli", "mcp"), for the undo journal.
	static func run(_ args: [String], store: RuleStore, apps: [RunningApp],
					print: (String) -> Void, postToApp: (String, String?) -> Bool, source: String = "cli") -> Int32 {
		guard let command = args.first else { print(usage); return 1 }
		if let target = args.dropFirst().first, target.trimmingCharacters(in: .whitespaces).isEmpty {
			print("error: the app name can't be empty")
			return 1
		}
		let rest = Array(args.dropFirst())

		func fail(_ message: String) -> Int32 { print("error: " + message); return 1 }

		/// Find (or create) the rule for a user-supplied app name.
		func ruleFor(_ target: String, create: Bool) -> AppRule? {
			RuleTargets.resolve(target, store: store, apps: apps, create: create)
		}

		/// Change settings through the same path as `set` (checks, undo journal,
		/// empty rules removed so Auto mode takes over again).
		func change(_ target: String, _ values: [String: Any], _ describe: (AppRule) -> String) -> Int32 {
			let current = ruleFor(target, create: false)?.conditions.schedule ?? Schedule()
			let changes: RuleChanges
			do { changes = try RuleChanges.parse(values, current: current) } catch { return fail("\(error)") }
			switch AppSettings.configure(target, changes: changes, store: store, apps: apps, source: source) {
			case .failed(let message):
				return fail(message)
			case .removed(let rule):
				print("\(rule.displayName): rule removed — " + (UserDefaults.standard.bool(forKey: Prefs.autoEnabled) ? "Auto mode manages it" : "no limits"))
				return 0
			case .saved(let rule, _):
				print(describe(rule) + (AppState.read() == nil ? "  (AppWrangler isn't running — applies when it starts)" : ""))
				return 0
			}
		}

		func save(_ rule: AppRule, _ message: String) -> Int32 {
			ChangeJournal.record(before: store.rules.first { $0.id == rule.id }, after: rule.sanitized(), source: source, store: store)
			store.upsert(rule)
			store.saveNow()
			print(message + (AppState.read() == nil ? "  (AppWrangler isn't running — applies when it starts)" : ""))
			return 0
		}

		switch command {
		case "help", "-h", "--help":
			print(usage)
			return 0

		case "rules":
			if store.rules.isEmpty { print("No rules."); return 0 }
			for r in store.rules.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
				print("\(r.enabled ? "●" : "○") \(r.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(r.summary)   [\(r.matchKind.rawValue): \(r.matchValue)]")
			}
			return 0

		case "list":
			let all = rest.contains("--all")
			let json = rest.contains("--json")
			if json {
				print(Reports.json(Reports.apps(store: store, apps: apps, includeProcesses: all)))
				return 0
			}
			let appMap = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
			let sampler = Sampler()
			let request = SampleRequest(apps: appMap, includeAll: true, includeOtherUsers: false, withThreads: false, matcher: GroupMatcher())
			_ = sampler.sampleNow(request)
			usleep(1_000_000)
			var groups = sampler.sampleNow(request).groups.filter { all || $0.kind != .process }
			groups.sort { $0.cpu > $1.cpu }
			print("   CPU     MEMORY  NAME                              WHAT IT IS")
			for g in groups {
				let name = g.name + (g.processes.count > 1 ? " +\(g.processes.count - 1)" : "")
				let what = store.rule(for: g).map { "[" + $0.summary + "]" } ?? ProcessCatalog.describe(g).summary
				let mem = Fmt.bytes(g.footprint)
				print(String(format: "%6.1f%%", g.cpu * 100) + "  " + String(repeating: " ", count: max(0, 9 - mem.count)) + mem
					  + "  " + name.padding(toLength: 32, withPad: " ", startingAt: 0) + "  " + what)
			}
			return 0

		case "status":
			if let state = AppState.read() {
				print("AppWrangler is running (pid \(state.pid))\(state.paused ? ", limits PAUSED" : "").")
				if !state.frozen.isEmpty { print("Frozen: " + state.frozen.joined(separator: ", ")) }
				if let auto = state.auto { print("Auto mode: " + auto) }
				if let apps = state.autoApps, !apps.isEmpty {
					for (name, what) in apps.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
						print("  " + name.padding(toLength: 24, withPad: " ", startingAt: 0) + what)
					}
				}
				if let runaway = state.runaway, !runaway.isEmpty {
					print("Using a lot of CPU in the background: " + runaway.joined(separator: ", "))
				}
			} else {
				print("AppWrangler isn't running.")
			}
			print("\(store.rules.filter(\.isActive).count) active rules — data in \(store.fileURL.deletingLastPathComponent().path)")
			return 0

		case "auto":
			let d = UserDefaults.standard
			if rest.first == "freeze-idle" {
				guard rest.count >= 2, ["on", "off"].contains(rest[1]) else { return fail("usage: auto freeze-idle on|off [minutes]") }
				if rest.count >= 3 {
					guard let m = Int(rest[2]), (1...1440).contains(m) else { return fail("minutes must be 1–1440") }
					d.set(m, forKey: Prefs.autoFreezeIdleMinutes)
				}
				d.set(rest[1] == "on", forKey: Prefs.autoFreezeIdle)
				d.synchronize()
				_ = postToApp("prefs", nil)
				let minutes = d.integer(forKey: Prefs.autoFreezeIdleMinutes)
				print(rest[1] == "on"
					  ? "Auto mode will freeze apps you haven't used for \(minutes) min when the Mac is low on memory. They resume when you switch to them or memory frees up; messaging, calls and audio apps are never frozen."
					  : "Auto mode won't freeze idle apps.")
				return 0
			}
			guard let mode = rest.first, ["on", "off"].contains(mode) else {
				let on = d.bool(forKey: Prefs.autoEnabled)
				let freeze = d.bool(forKey: Prefs.autoFreezeIdle)
				print("Auto mode is \(on ? "on" : "off"); freezing idle apps when memory is low is \(freeze ? "on (after \(d.integer(forKey: Prefs.autoFreezeIdleMinutes)) min)" : "off").")
				print("Use: auto on|off, auto freeze-idle on|off [minutes]")
				return 0
			}
			UserDefaults.standard.set(mode == "on", forKey: Prefs.autoEnabled)
			UserDefaults.standard.synchronize()
			_ = postToApp("prefs", nil)
			print(mode == "on"
				  ? "Auto mode on: the app you're using runs at full speed; background apps go to efficiency cores and share the CPU when the Mac is busy."
				  : "Auto mode off: only your rules apply.")
			return 0

		case "stats":
			let days = rest.contains("hour") ? 0 : rest.contains("today") ? 1 : rest.contains("month") ? 30 : 7
			let statsStore = StatsStore(directory: store.fileURL.deletingLastPathComponent())
			let s = days == 0 ? statsStore.summary(hours: 1) : statsStore.summary(days: days)
			if rest.contains("--json") {
				print(Reports.json(Reports.stats(directory: store.fileURL.deletingLastPathComponent(), days: days)))
				return 0
			}
			let label = days == 0 ? "last hour" : days == 1 ? "today" : "last \(days) days"
			print("AppWrangler impact — \(label)")
			print("")
			print("  CPU time saved      \(Fmt.coreTime(s.total.savedCPUSeconds))")
			let energy = s.total.totalSavedEnergyJ
			print("  Energy saved (est.) \(Fmt.energy(energy))" + (Battery.capacityWh.map { energy > 0 ? String(format: "  (%.1f%% of battery)", energy / 3600 / $0 * 100) : "" } ?? ""))
			print("    by efficiency cores \(Fmt.energy(s.total.efficiencySavedJ))   by limits/freezes \(Fmt.energy(s.total.savedEnergyJ))")
			print("  Apps held back      \(Fmt.duration(s.total.heldBackSeconds))")
			print("  Apps frozen         \(Fmt.duration(s.total.frozenSeconds))")
			print("  On efficiency cores \(Fmt.duration(s.total.efficiencySeconds))")
			print("  Actions             \(s.total.memoryActions) memory-limit, \(s.total.lowMemoryActions) low-memory, \(s.runawayAlerts) runaway alerts")
			let m = s.memory
			if m.measuredSeconds > 0 {
				print("")
				print("  Short of memory     \(Fmt.duration(m.shortSeconds)) (\(Int(m.shortSeconds / max(m.measuredSeconds, 1) * 100))% of the time), critical \(Fmt.duration(m.criticalSeconds))")
				print("  Swap                peak \(Fmt.bytes(UInt64(m.swapPeakBytes))), read back \(Fmt.bytes(UInt64(m.swapInBytes)))"
					  + (m.swapInPerShortHour.map { " (\(Fmt.bytes(UInt64($0)))/h while short)" } ?? ""))
				print("  Frozen for memory   \(m.freezes) apps holding \(Fmt.bytes(UInt64(m.frozenBytes))), \(Fmt.duration(m.frozenAppSeconds)) in total")
			}
			print("")
			print("  AppWrangler itself  \(Fmt.percent(s.averageSelfCPU)) CPU on average, \(Fmt.coreTime(s.selfCPUSeconds)) total, \(Fmt.bytes(UInt64(s.averageFootprint))) memory")
			if let ratio = s.efficiencyRatio { print(String(format: "  Efficiency          saved %.0f× more CPU time than it used", ratio)) }
			if let acc = s.accuracyError { print(String(format: "  Limit accuracy      ±%.1f%%", acc * 100)) }
			if !s.apps.isEmpty {
				print("")
				print("  APP                         SAVED         ENERGY     WANTED → ALLOWED   HELD BACK")
				for row in s.apps {
					let a = row.impact
					let wa = a.limitedSeconds > 0 ? Fmt.percent(a.averageWanted) + " → " + Fmt.percent(a.averageAllowed) : "—"
					print("  " + a.name.padding(toLength: 26, withPad: " ", startingAt: 0) + "  "
						  + Fmt.coreTime(a.savedCPUSeconds).padding(toLength: 12, withPad: " ", startingAt: 0) + "  "
						  + Fmt.energy(a.totalSavedEnergyJ).padding(toLength: 9, withPad: " ", startingAt: 0) + "  "
						  + wa.padding(toLength: 17, withPad: " ", startingAt: 0) + "  "
						  + (a.heldBackSeconds > 0 ? Fmt.duration(a.heldBackSeconds) : "—"))
				}
			}
			print("")
			print("  Savings are estimates (see docs/user-manual.md#impact). Updated by the running app every 30 s.")
			return 0

		case "suggest":
			let json = rest.contains("--json")
			let app = rest.first { !$0.hasPrefix("--") }
			let input = SuggestionInput.current(groups: Reports.sampleGroups(apps: apps), store: store,
												frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
			let list = Suggestions.make(input, app: app)
			print(json ? Reports.json(list.map(\.json)) : Suggestions.text(list))
			return 0

		case "show":
			guard let target = rest.first(where: { !$0.hasPrefix("--") }) else { return fail("usage: show <app> [--json]") }
			let input = SuggestionInput.current(groups: Reports.sampleGroups(apps: apps), store: store,
												frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
			guard let report = Reports.appSettings(target, store: store, apps: apps, input: input) else {
				return fail(Reports.notFound(target, in: input.groups))
			}
			if rest.contains("--json") { print(Reports.json(report)); return 0 }
			print(showText(report))
			return 0

		case "set":
			guard rest.count >= 2 else {
				return fail("usage: set <app> key=value …   keys: " + RuleChanges.keys.map(\.key).joined(separator: ", "))
			}
			let current = ruleFor(rest[0], create: false)?.conditions.schedule ?? Schedule()
			let changes: RuleChanges
			do { changes = try RuleChanges.parse(cli: Array(rest.dropFirst()), current: current) } catch { return fail("\(error)") }
			switch AppSettings.configure(rest[0], changes: changes, store: store, apps: apps, source: source) {
			case .failed(let message):
				return fail(message)
			case .removed(let rule):
				print("\(rule.displayName): rule removed — " + (UserDefaults.standard.bool(forKey: Prefs.autoEnabled) ? "Auto mode manages it" : "no limits"))
				return 0
			case .saved(let rule, let before):
				print("\(rule.displayName): \(rule.summary)  (was: \(before))"
					  + (AppState.read() == nil ? "  (AppWrangler isn't running — applies when it starts)" : ""))
				return 0
			}

		case "limit":
			guard rest.count >= 2, let percent = Double(rest[1].replacingOccurrences(of: "%", with: "")), percent.isFinite, percent >= 1 else {
				return fail("usage: limit <app> <percent> [--background-only | --always]")
			}
			var values: [String: Any] = ["cpu_limit": percent]
			// Keep the rule's existing setting unless asked; new rules are background-only.
			if rest.contains("--background-only") { values["background_only"] = true }
			if rest.contains("--always") { values["background_only"] = false }
			return change(rest[0], values) { "\($0.displayName): CPU limited to \(Int($0.cpuLimit))%" }

		case "ecores":
			guard rest.count >= 2, ["on", "off"].contains(rest[1].lowercased()) else { return fail("usage: ecores <app> on|off") }
			let on = rest[1].lowercased() == "on"
			return change(rest[0], ["efficiency_cores": on]) { "\($0.displayName): efficiency cores \(on ? "on" : "off")" }

		case "memlimit":
			guard rest.count >= 2 else { return fail("usage: memlimit <app> <MB>|off [notify|freeze|quit|forcequit]") }
			if rest[1].lowercased() == "off" {
				return change(rest[0], ["memory_limit_mb": 0]) { "\($0.displayName): memory limit off" }
			}
			guard let mb = Double(rest[1]), mb.isFinite, AppRule.memoryLimitRange.contains(mb) else {
				return fail("memory limit must be a number of MB between 16 and 16777216")
			}
			let action = rest.count > 2 ? rest[2].lowercased() : "notify"
			guard ["notify", "freeze", "quit", "forcequit"].contains(action) else { return fail("action must be notify, freeze, quit or forcequit") }
			return change(rest[0], ["memory_limit_mb": mb, "memory_action": action]) {
				"\($0.displayName): memory limit \(Fmt.megabytes(mb)), then \(action)"
			}

		case "lowmem":
			guard rest.count >= 2, let action = PressureAction(rawValue: rest[1].lowercased()) else { return fail("usage: lowmem <app> none|freeze|quit") }
			return change(rest[0], ["low_memory_action": action.rawValue]) { "\($0.displayName): when the Mac is low on memory → \(action.rawValue)" }

		case "enable", "disable", "ignore":
			guard let target = rest.first else { return fail("usage: \(command) <app>") }
			return change(target, command == "ignore" ? ["ignored": true] : ["enabled": command == "enable"]) { "\($0.displayName): \(command)d" }

		case "unlimit":
			guard rest.count >= 1, let rule = ruleFor(rest[0], create: false) else { return fail("no rule for \(rest.first ?? "?")") }
			store.remove(id: rule.id)
			store.saveNow()
			ChangeJournal.record(before: rule, after: nil, source: source, store: store)
			print("\(rule.displayName): rule removed")
			return 0

		case "undo":
			switch ChangeJournal.undoLast(store: store, force: rest.contains("--force")) {
			case .nothing:
				print("Nothing to undo.")
				return 0
			case .conflict(_, let message):
				return fail(message)
			case .undone(_, let message):
				print(message + (AppState.read() == nil ? "  (AppWrangler isn't running — applies when it starts)" : ""))
				return 0
			}

		case "freeze", "unfreeze":
			guard rest.count >= 1 else { return fail("usage: \(command) <app>") }
			if command == "freeze", let problem = RuleTargets.check(rest[0]) { return fail(problem.description) }
			// Check the name here, so a typo fails instead of silently doing nothing in the app.
			let t = rest[0].lowercased()
			if !apps.contains(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t }) {
				let groups = Reports.sampleGroups(apps: apps, seconds: 0.2)
				if Reports.findGroup(rest[0], in: groups) == nil {
					return fail(Reports.notFound(rest[0], in: groups).replacingOccurrences(of: " and has no rule", with: ""))
				}
			}
			guard postToApp(command, rest[0]) else { return fail("AppWrangler isn't running") }
			print("\(command) \(rest[0]): sent")
			return 0

		case "prefs":
			if rest.isEmpty || rest == ["--json"] {
				let now = PreferenceSettings.current()
				if rest == ["--json"] { print(Reports.json(now)); return 0 }
				for spec in PreferenceSettings.specs {
					let v = now[spec.key].map { v -> String in
						if let b = v as? Bool { return b ? "on" : "off" }
						if let d = v as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
						return "\(v)"
					} ?? ""
					print(spec.key.padding(toLength: 24, withPad: " ", startingAt: 0) + v.padding(toLength: 10, withPad: " ", startingAt: 0) + spec.help)
				}
				return 0
			}
			var values: [String: Any] = [:]
			for arg in rest {
				let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
				guard parts.count == 2 else { return fail("expected key=value, got \"\(arg)\" (run `appwrangler prefs` to list them)") }
				values[parts[0].replacingOccurrences(of: "-", with: "_")] = parts[1]
			}
			do { _ = try PreferenceSettings.set(values) } catch { return fail("\(error)") }
			_ = postToApp("prefs", nil)
			print("Saved: " + values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " "))
			return 0

		case "free-memory":
			guard postToApp(command, nil) else { return fail("AppWrangler isn't running") }
			print("Asked AppWrangler to freeze apps you haven't used for a while; each resumes when you switch to it. See `appwrangler status`.")
			return 0

		case "pause", "resume":
			guard postToApp(command, nil) else { return fail("AppWrangler isn't running") }
			print(command == "pause" ? "Limits paused (frozen apps stay frozen)." : "Limits resumed.")
			return 0

		case "export":
			guard let data = try? store.exportData() else { return fail("couldn't encode rules") }
			if let path = rest.first {
				do { try data.write(to: URL(fileURLWithPath: path)) } catch { return fail(error.localizedDescription) }
				print("Exported \(store.rules.count) rules to \(path)")
			} else {
				print(String(decoding: data, as: UTF8.self))
			}
			return 0

		case "import":
			guard let path = rest.first else { return fail("usage: import <file.json>") }
			do {
				let before = store.rules
				let n = try store.importData(Data(contentsOf: URL(fileURLWithPath: path)))
				for rule in store.rules where !before.contains(rule) {
					ChangeJournal.record(before: before.first { $0.id == rule.id }, after: rule, source: source, store: store)
				}
				store.saveNow()
				print("Imported \(n) rules")
				return 0
			} catch {
				return fail("couldn't import: \(error.localizedDescription)")
			}

		default:
			print(usage)
			return 1
		}
	}

	/// Human-readable `show` output.
	static func showText(_ r: [String: Any]) -> String {
		var lines: [String] = []
		let name = r["app"] as? String ?? "?"
		if let u = r["usage"] as? [String: Any] {
			lines.append("\(name) — \(u["description"] as? String ?? "")")
			lines.append(String(format: "  Now: %.1f%% CPU, %@ memory, %d processes", u["cpuPercent"] as? Double ?? 0,
								Fmt.megabytes(u["memoryMB"] as? Double ?? 0), u["processes"] as? Int ?? 0))
			lines.append("  Safety: \(u["safety"] as? String ?? "")")
		} else {
			lines.append("\(name) — not running")
		}
		lines.append("  Managed by: \(r["managedBy"] as? String ?? "") — \(r["managedByMeaning"] as? String ?? "")")
		if let auto = r["autoState"] as? String { lines.append("  Auto mode: \(auto)") }
		lines.append("  Rule: \(r["rule"] as? String ?? "")" + ((r["matchedBy"] as? String).map { "   [\($0)]" } ?? ""))
		lines.append("")
		lines.append("  Settings (change with: appwrangler set \(Suggestions.quoted(name)) key=value …)")
		let settings = r["settings"] as? [String: Any] ?? [:]
		for (key, _) in RuleChanges.keys where settings[key] != nil || key == "use_auto" {
			guard key != "use_auto" else { continue }
			let value = settings[key].map { v -> String in
				if let a = v as? [Int] { return a.map(String.init).joined(separator: ",") }
				if let d = v as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
				return "\(v)"
			} ?? ""
			lines.append("    " + key.padding(toLength: 20, withPad: " ", startingAt: 0) + value)
		}
		if let suggestions = r["suggestions"] as? [[String: Any]], !suggestions.isEmpty {
			lines.append("")
			lines.append("  Suggestions:")
			for s in suggestions {
				lines.append("    • \(s["title"] as? String ?? "")")
				for a in s["actions"] as? [[String: Any]] ?? [] {
					lines.append("      → \(a["label"] as? String ?? ""):  \(a["cli"] as? String ?? "")")
				}
			}
		}
		return lines.joined(separator: "\n")
	}

	static let usage = """
	AppWrangler — per-app CPU, efficiency-core and memory limits

	usage: appwrangler <command> [arguments]

	  list [--all] [--json]          running apps with CPU, memory and what they are
	  rules                          show saved rules
	  suggest [app] [--json]         recommended settings for what's running, with ready commands
	  show <app> [--json]            what an app is, its usage, every setting, and suggestions
	  undo [--force]                 revert the last rule change (from here, a suggestion, an AI assistant
	                                 or a quick action); --force if it was edited since
	  set <app> key=value …          change any setting, e.g. set Slack efficiency_cores=on
	                                 background_only=true   (run `set` alone to list the keys)
	  status                         running? paused? what's frozen or hogging the CPU
	  stats [hour|today|week|month] [--json]  how much CPU/energy was saved, and what it cost
	  auto [on|off]                  Auto mode: full speed for the app you use, efficiency for the rest
	  auto freeze-idle on|off [min]  also freeze apps unused for [min] when memory runs low
	  limit <app> <percent>          cap CPU (100 = one core). New rules apply only while
	                                 the app isn't frontmost; --always to apply even then
	  ecores <app> on|off            run the app on efficiency cores only
	  memlimit <app> <MB>|off [notify|freeze|quit|forcequit]
	  lowmem <app> none|freeze|quit  what to do when the Mac runs low on memory
	  enable|disable <app>           turn a rule on or off
	  ignore <app>                   never suggest limits for this app
	  unlimit <app>                  delete the rule
	  freeze|unfreeze <app>          suspend / resume an app now (AppWrangler must be running)
	  pause|resume                   pause or resume all CPU limits
	  prefs [key=value …]            show or change app-wide settings (Auto, low memory, alerts…)
	  free-memory                    freeze apps unused for a while now (they resume when you switch to them)
	  export [file] / import <file>  share rules as JSON
	  mcp [--read-only]              run as an MCP server for Claude / OpenAI tools (docs/mcp.md)
	  mcp install|uninstall|status [--read-only] [claude-desktop|claude-code|codex]
	                                 add AppWrangler to your AI apps' MCP settings

	<app> is an app name ("Google Chrome"), bundle id (com.google.Chrome),
	process name (node), path (/usr/local/bin/x) or pattern ("*Helper*").
	Changes apply immediately to the running app — no restart needed.
	"""
}
