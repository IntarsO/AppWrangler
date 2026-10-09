//
//  AppSettings.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  One vocabulary for every per-app setting, shared by the MCP tools
//  (`get_app_settings`, `configure_app`) and the CLI (`show`, `set`):
//
//      appwrangler set Slack background_only=true efficiency_cores=on
//      configure_app {"app": "Slack", "background_only": true, "efficiency_cores": true}
//

import Foundation

/// A partial update to an app's rule. Only the fields that are set change.
struct RuleChanges {
	var cpuLimit: Double?			// percent of one core; 0 = no CPU limit
	var efficiencyCores: Bool?
	var backgroundOnly: Bool?
	var memoryLimitMB: Double?		// 0 = no memory limit
	var memoryAction: MemoryAction?
	var lowMemoryAction: PressureAction?
	var includeHelpers: Bool?
	var enabled: Bool?
	var ignored: Bool?
	var useAuto: Bool?
	var priority: AppPriority?
	var power: PowerCondition?
	var lowPowerModeOnly: Bool?
	var hotOnly: Bool?
	var schedule: Schedule?

	/// Every key, with a one-line explanation (shown by `show`, `get_app_settings` and the docs).
	static let keys: [(key: String, help: String)] = [
		("cpu_limit", "CPU cap in % of one core (100 = one full core, 0 = no cap). Covers the app's helpers too."),
		("efficiency_cores", "true = run on the efficiency cores with low-priority disk/network I/O. Never pauses the app."),
		("background_only", "true = CPU cap and efficiency cores only apply while the app isn't frontmost (recommended)."),
		("memory_limit_mb", "Memory limit in MB (0 = none). When the app stays above it, memory_action happens."),
		("memory_action", "notify, freeze, quit or forcequit — what happens above memory_limit_mb."),
		("low_memory_action", "none, freeze or quit — what happens to this app (when it isn't in use) if the whole Mac runs low on memory."),
		("include_helpers", "true = limits cover the app's helper processes (browser tabs, renderers). Default true."),
		("enabled", "false = keep the rule but switch it off."),
		("ignored", "true = never suggest limits for this app and keep it out of Auto mode."),
		("use_auto", "true = drop this app's own CPU cap and efficiency-core setting so Auto mode manages it."),
		("priority", "high, normal or low — what matters when the Mac needs its resources. Low work (updaters, indexing) is slowed first and paused if the need lasts; high is never slowed or paused."),
		("power", "any, battery or charger — only apply the rule on that power source."),
		("low_power_mode_only", "true = only apply while Low Power Mode is on."),
		("hot_only", "true = only apply while the Mac is hot (thermal pressure)."),
		("schedule", "HH:MM-HH:MM (e.g. 09:00-18:00) or off — only apply during those hours. A window may cross midnight (22:00-06:00)."),
		("weekdays", "With schedule: days it applies, 1 = Sunday … 7 = Saturday, e.g. 2,3,4,5,6 for Mon–Fri."),
	]

	static var keyNames: Set<String> { Set(keys.map(\.key)) }

	var isEmpty: Bool {
		cpuLimit == nil && efficiencyCores == nil && backgroundOnly == nil && memoryLimitMB == nil && memoryAction == nil
			&& lowMemoryAction == nil && includeHelpers == nil && enabled == nil && ignored == nil && useAuto == nil
			&& priority == nil && power == nil && lowPowerModeOnly == nil && hotOnly == nil && schedule == nil
	}

	/// Does this change turn something on (so a missing rule should be created)?
	var addsSomething: Bool {
		(cpuLimit ?? 0) > 0 || efficiencyCores == true || (memoryLimitMB ?? 0) > 0
			|| (lowMemoryAction.map { $0 != .none } ?? false) || ignored == true || (priority.map { $0 != .normal } ?? false)
	}

	struct ParseError: Error, CustomStringConvertible { let description: String }

	/// Parse MCP arguments (typed JSON) or CLI `key=value` pairs (strings). Unknown keys are errors.
	static func parse(_ values: [String: Any], current: Schedule = Schedule()) throws -> RuleChanges {
		var c = RuleChanges()
		func bool(_ key: String, _ v: Any) throws -> Bool {
			if let b = v as? Bool { return b }
			if let n = v as? NSNumber { return n.boolValue }
			switch (v as? String)?.lowercased() {
			case "true", "on", "yes", "1": return true
			case "false", "off", "no", "0": return false
			default: throw ParseError(description: "\(key) must be true or false")
			}
		}
		func number(_ key: String, _ v: Any, range: ClosedRange<Double>) throws -> Double {
			let d: Double?
			if let n = v as? NSNumber, !(v is Bool) { d = n.doubleValue } else if let s = v as? String {
				d = ["off", "none", "no", "false"].contains(s.lowercased()) ? 0 : Double(s.replacingOccurrences(of: "%", with: ""))
			} else { d = nil }
			guard let d, d.isFinite, d == 0 || range.contains(d) else {
				throw ParseError(description: "\(key) must be 0 (off) or a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
			}
			return d
		}
		func choice<T: RawRepresentable>(_ key: String, _ v: Any, _ make: (String) -> T?, _ allowed: String) throws -> T where T.RawValue == String {
			guard let s = v as? String, let t = make(s.lowercased()) else { throw ParseError(description: "\(key) must be one of: \(allowed)") }
			return t
		}
		func minutes(_ text: String) -> Int? {
			let parts = text.split(separator: ":").compactMap { Int($0) }
			guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
			return parts[0] * 60 + parts[1]
		}
		var schedule = current
		var scheduleTouched = false
		for (key, v) in values {
			switch key {
			case "app": continue
			case "cpu_limit": c.cpuLimit = try number(key, v, range: AppRule.cpuLimitRange)
			case "efficiency_cores": c.efficiencyCores = try bool(key, v)
			case "background_only": c.backgroundOnly = try bool(key, v)
			case "memory_limit_mb": c.memoryLimitMB = try number(key, v, range: AppRule.memoryLimitRange)
			case "memory_action":
				c.memoryAction = try choice(key, v, { $0 == "forcequit" ? .forceQuit : MemoryAction(rawValue: $0) }, "notify, freeze, quit, forcequit")
			case "low_memory_action": c.lowMemoryAction = try choice(key, v, { PressureAction(rawValue: $0) }, "none, freeze, quit")
			case "include_helpers": c.includeHelpers = try bool(key, v)
			case "enabled": c.enabled = try bool(key, v)
			case "ignored": c.ignored = try bool(key, v)
			case "use_auto": c.useAuto = try bool(key, v)
			case "priority": c.priority = try choice(key, v, { AppPriority(rawValue: $0) }, "high, normal, low")
			case "power": c.power = try choice(key, v, { PowerCondition(rawValue: $0) }, "any, battery, charger")
			case "low_power_mode_only": c.lowPowerModeOnly = try bool(key, v)
			case "hot_only": c.hotOnly = try bool(key, v)
			case "schedule":
				scheduleTouched = true
				if let obj = v as? [String: Any] {
					schedule.enabled = try obj["enabled"].map { try bool("schedule.enabled", $0) } ?? true
					if let s = obj["start"] {
						guard let m = (s as? String).flatMap(minutes) else { throw ParseError(description: "schedule.start must be HH:MM") }
						schedule.start = m
					}
					if let e = obj["end"] {
						guard let m = (e as? String).flatMap(minutes) else { throw ParseError(description: "schedule.end must be HH:MM") }
						schedule.end = m
					}
					if let days = obj["weekdays"] as? [Any] {
						schedule.weekdays = Set(days.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }.filter { (1...7).contains($0) })
					}
				} else if let s = (v as? String)?.lowercased() {
					if ["off", "none", "false", "no"].contains(s) {
						schedule.enabled = false
					} else {
						let ends = s.split(separator: "-").map(String.init)
						guard ends.count == 2, let a = minutes(ends[0]), let b = minutes(ends[1]) else {
							throw ParseError(description: "schedule must look like 09:00-18:00, or off")
						}
						schedule.enabled = true
						schedule.start = a
						schedule.end = b
					}
				} else {
					throw ParseError(description: "schedule must be HH:MM-HH:MM, off, or an object")
				}
			case "weekdays":
				scheduleTouched = true
				let list: [Int]
				if let a = v as? [Any] { list = a.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") } }
				else { list = "\(v)".split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) } }
				guard list.allSatisfy({ (1...7).contains($0) }) else { throw ParseError(description: "weekdays are 1 (Sunday) … 7 (Saturday)") }
				schedule.weekdays = Set(list)
			default:
				throw ParseError(description: "unknown setting \"\(key)\" — valid: " + keys.map(\.key).joined(separator: ", "))
			}
		}
		if scheduleTouched { c.schedule = schedule }
		return c
	}

	/// Parse CLI arguments like `cpu_limit=50 efficiency_cores=on`.
	static func parse(cli args: [String], current: Schedule = Schedule()) throws -> RuleChanges {
		var values: [String: Any] = [:]
		for arg in args {
			let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
			guard parts.count == 2, !parts[0].isEmpty else { throw ParseError(description: "expected key=value, got \"\(arg)\"") }
			values[parts[0].replacingOccurrences(of: "-", with: "_")] = parts[1]
		}
		return try parse(values, current: current)
	}

	func apply(to rule: inout AppRule, maxCPU: Double = Double(max(SystemInfo.ncpu, 1) * 100)) {
		if let v = cpuLimit {
			rule.cpuLimitEnabled = v > 0
			if v > 0 { rule.cpuLimit = min(v, maxCPU) }
		}
		if let v = efficiencyCores { rule.backgroundMode = v }
		if let v = backgroundOnly { rule.onlyWhenInactive = v }
		if let v = memoryLimitMB {
			rule.memoryLimitEnabled = v > 0
			if v > 0 { rule.memoryLimitMB = v }
		}
		if let v = memoryAction { rule.memoryAction = v }
		if let v = lowMemoryAction { rule.pressureAction = v }
		if let v = includeHelpers { rule.includeHelpers = v }
		if let v = ignored { rule.ignored = v }
		if let v = priority { rule.priority = v }
		if useAuto == true {
			rule.cpuLimitEnabled = false
			rule.backgroundMode = false
			rule.ignored = false
		}
		if let v = power { rule.conditions.power = v }
		if let v = lowPowerModeOnly { rule.conditions.lowPowerModeOnly = v }
		if let v = hotOnly { rule.conditions.hotOnly = v }
		if let v = schedule { rule.conditions.schedule = v }
		if let v = enabled {
			rule.enabled = v
		} else if addsSomething {
			rule.enabled = true
		}
		rule = rule.sanitized()
	}
}

enum AppSettings {
	enum Outcome {
		case saved(AppRule, before: String)
		case removed(AppRule)
		case failed(String)
	}

	/// Apply `changes` to the app's rule (creating one if something is turned on).
	/// A rule left with no limits that isn't ignored is removed, so Auto mode manages the app.
	static func configure(_ target: String, changes: RuleChanges, store: RuleStore, apps: [RunningApp], source: String = "cli") -> Outcome {
		guard !changes.isEmpty else { return .failed("nothing to change — give at least one setting: " + RuleChanges.keys.map(\.key).joined(separator: ", ")) }
		if let problem = RuleTargets.check(target.trimmingCharacters(in: .whitespaces)) { return .failed(problem.description) }
		let existing = RuleTargets.resolve(target, store: store, apps: apps, create: false)
		var created: AppRule?
		if existing == nil && changes.addsSomething {
			switch RuleTargets.resolveForWrite(target, store: store, apps: apps) {
			case .success(let r): created = r
			case .failure(let problem): return .failed(problem.description)
			}
		}
		guard var rule = existing ?? created else {
			return .failed("\(target) has no rule, so there's nothing to turn off" + (changes.useAuto == true ? " — Auto mode already manages it" : ""))
		}
		if Protected.contains(name: rule.displayName, bundleID: rule.matchKind == .bundleID ? rule.matchValue : nil, pid: 2) {
			return .failed("\(rule.displayName) is critical to macOS; AppWrangler won't limit it")
		}
		let before = existing?.summary ?? "no rule"
		changes.apply(to: &rule)
		if !rule.hasLimits && !rule.ignored {
			if existing != nil {
				store.remove(id: rule.id)
				ChangeJournal.record(before: existing, after: nil, source: source, store: store)
			}
			store.saveNow()
			return .removed(rule)
		}
		store.upsert(rule)
		store.saveNow()
		ChangeJournal.record(before: existing, after: rule, source: source, store: store)
		return .saved(rule, before: before)
	}

	/// Every setting of a rule, using the same keys `configure_app` / `set` take.
	static func settings(_ rule: AppRule?) -> [String: Any] {
		let r = rule ?? AppRule(matchKind: .name, matchValue: "", displayName: "")
		var s: [String: Any] = [
			"cpu_limit": r.cpuLimitEnabled ? r.cpuLimit : 0,
			"efficiency_cores": r.backgroundMode,
			"background_only": r.onlyWhenInactive,
			"memory_limit_mb": r.memoryLimitEnabled ? r.memoryLimitMB : 0,
			"memory_action": r.memoryAction == .forceQuit ? "forcequit" : r.memoryAction.rawValue,
			"low_memory_action": r.pressureAction.rawValue,
			"include_helpers": r.includeHelpers,
			"enabled": rule?.enabled ?? false,
			"ignored": r.ignored,
			"priority": r.priority.rawValue,
			"power": r.conditions.power.rawValue,
			"low_power_mode_only": r.conditions.lowPowerModeOnly,
			"hot_only": r.conditions.hotOnly,
			"schedule": r.conditions.schedule.enabled
				? String(format: "%02d:%02d-%02d:%02d", r.conditions.schedule.start / 60, r.conditions.schedule.start % 60,
						 r.conditions.schedule.end / 60, r.conditions.schedule.end % 60) : "off",
		]
		if r.conditions.schedule.enabled, !r.conditions.schedule.weekdays.isEmpty {
			s["weekdays"] = r.conditions.schedule.weekdays.sorted()
		}
		return s
	}

	/// Who decides how fast the app runs: its own rule, Auto mode, or nothing.
	static func managedBy(_ group: AppGroup?, rule: AppRule?, autoEnabled: Bool) -> String {
		if let group, Protected.contains(group) { return "protected" }
		if let rule, rule.ignored { return "ignored" }
		if let rule, rule.enabled, rule.cpuLimitEnabled || rule.backgroundMode { return "rule" }
		let kind = group?.kind ?? .app
		if autoEnabled && (kind == .app || kind == .background) { return "auto" }
		return rule?.isActive == true ? "rule (memory only)" : "nothing"
	}

	static let managedByHelp: [String: String] = [
		"protected": "Critical to macOS — never limited.",
		"ignored": "You told AppWrangler to leave it alone.",
		"rule": "Its own rule sets its CPU cap / efficiency cores; Auto mode leaves it alone.",
		"auto": "Auto mode: full speed while in use, efficiency cores after a short time in the background (30 s by default), fair CPU share when the Mac is busy.",
		"rule (memory only)": "Only memory settings apply; CPU is unmanaged (Auto mode is off or it's a plain process).",
		"nothing": "Runs unmanaged.",
	]
}

/// The last rule changes made from the CLI, the MCP server or a suggestion
/// (`changes.json` next to the rules), so "undo that" works.
enum ChangeJournal {
	struct Entry: Codable {
		var date: Date
		var app: String
		var source: String
		/// The rule before the change (nil = there was none) and after (nil = removed).
		var before: AppRule?
		var after: AppRule?
	}

	static let capacity = 50

	static func url(_ directory: URL) -> URL { directory.appendingPathComponent("changes.json") }

	/// The app, CLI and MCP servers all write the journal; take turns.
	private static func locked<T>(_ directory: URL, _ body: () -> T) -> T {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fd = open(directory.appendingPathComponent(".changes.lock").path, O_CREAT | O_RDWR, 0o600)
		if fd >= 0 { flock(fd, LOCK_EX) }
		defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
		return body()
	}

	static func entries(directory: URL) -> [Entry] {
		guard let data = try? Data(contentsOf: url(directory)) else { return [] }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let entries = try? decoder.decode([Entry].self, from: data) { return entries }
		// Unreadable (hand-edited, or from a future version): keep it aside rather than overwrite it.
		let aside = directory.appendingPathComponent("changes.unreadable-\(Int(Date().timeIntervalSince1970)).json")
		try? FileManager.default.moveItem(at: url(directory), to: aside)
		return []
	}

	private static func save(_ entries: [Entry], directory: URL) {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		if let data = try? encoder.encode(Array(entries.suffix(capacity))) { try? data.write(to: url(directory), options: .atomic) }
	}

	static func record(before: AppRule?, after: AppRule?, source: String, store: RuleStore) {
		guard before != after, let app = (after ?? before)?.displayName else { return }
		let dir = store.fileURL.deletingLastPathComponent()
		locked(dir) {
			save(entries(directory: dir) + [Entry(date: Date(), app: app, source: source, before: before, after: after)], directory: dir)
		}
	}

	enum UndoResult {
		case undone(Entry, String)
		/// The rule was changed somewhere else since (e.g. in the panel); undoing would lose that.
		case conflict(Entry, String)
		case nothing
	}

	/// The rule the entry is about, as it is now: same id, or the same app if it was re-created.
	private static func current(_ entry: Entry, in store: RuleStore) -> AppRule? {
		guard let ref = entry.after ?? entry.before else { return nil }
		return store.rules.first { $0.id == ref.id }
			?? store.rules.first { $0.matchKind == ref.matchKind && $0.matchValue.caseInsensitiveCompare(ref.matchValue) == .orderedSame }
	}

	/// Reverts the most recent change, unless the rule has been changed elsewhere
	/// since (then nothing happens unless `force`).
	static func undoLast(store: RuleStore, force: Bool = false) -> UndoResult {
		let dir = store.fileURL.deletingLastPathComponent()
		return locked(dir) {
			var all = entries(directory: dir)
			guard let last = all.last else { return .nothing }
			let now = current(last, in: store)
			if !force && now != last.after {
				return .conflict(last, "\(last.app) was changed elsewhere since (e.g. in AppWrangler's window) — undoing would lose that. Run `appwrangler undo --force` to undo anyway.")
			}
			all.removeLast()
			save(all, directory: dir)
			let message: String
			if var before = last.before {
				// Replace whatever rule is there now for that app, so there's never a duplicate.
				if let now, now.id != before.id { store.remove(id: now.id) }
				before.id = now?.id ?? before.id
				store.upsert(before)
				message = "\(before.displayName): restored — \(before.summary)"
			} else if let now {
				store.remove(id: now.id)
				message = "\(now.displayName): rule removed (it didn't exist before)"
			} else {
				message = "\(last.app): already as it was"
			}
			store.saveNow()
			return .undone(last, message)
		}
	}

	/// Older call style used by tests: undo without forcing.
	@discardableResult
	static func undo(store: RuleStore) -> (entry: Entry, message: String)? {
		if case .undone(let e, let m) = undoLast(store: store) { return (e, m) }
		return nil
	}
}
