//
//  Suggestions.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Looks at what's running, the saved rules, memory/swap and the impact
//  statistics, and proposes concrete settings — each with the reason, the
//  expected benefit and ready-to-run actions (MCP tool + arguments, and the
//  equivalent CLI command). Used by `appwrangler suggest` and the MCP
//  `suggest_settings` / `get_app_settings` tools. Nothing here changes anything.
//

import Foundation
import ProcKit

struct Suggestion {
	enum Severity: String, Comparable {
		case high, medium, low, info
		private var order: Int { [.high: 0, .medium: 1, .low: 2, .info: 3][self] ?? 3 }
		static func < (a: Severity, b: Severity) -> Bool { a.order < b.order }
	}

	enum Category: String { case memory, cpu, battery, rules, auto }

	struct Action {
		/// Short label, e.g. "Warn at 6 GB".
		var label: String
		/// MCP tool to call and its arguments.
		var tool: String
		var arguments: [String: Any]
		/// The same change from the command line.
		var cli: String

		var json: [String: Any] { ["label": label, "tool": tool, "arguments": arguments, "cli": cli] }

		/// A `configure_app` call and its `appwrangler set` twin.
		static func configure(_ label: String, app: String, _ settings: [String: Any]) -> Action {
			let pairs = settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
			return Action(label: label, tool: "configure_app", arguments: settings.merging(["app": app]) { a, _ in a },
						  cli: (["appwrangler set", Suggestions.quoted(app)] + pairs).joined(separator: " "))
		}
	}

	/// Stable id, e.g. "memory-hog:com.brave.Browser" — the same problem keeps the same id.
	var id: String
	var severity: Severity
	var category: Category
	/// App the suggestion is about (nil for Mac-wide ones).
	var app: String?
	var title: String
	var reason: String
	var benefit: String
	/// Manual steps outside AppWrangler (e.g. a browser setting), if any.
	var tip: String?
	var actions: [Action] = []

	var json: [String: Any] {
		var out: [String: Any] = ["id": id, "severity": severity.rawValue, "category": category.rawValue, "title": title,
								  "reason": reason, "benefit": benefit, "actions": actions.map(\.json)]
		if let app { out["app"] = app }
		if let tip { out["tip"] = tip }
		return out
	}
}

/// Everything the engine looks at, gathered up front so it's testable.
struct SuggestionInput {
	var groups: [AppGroup]
	var rules: [AppRule]
	var autoEnabled: Bool
	var frontmostPid: pid_t = 0
	var memoryBytes: UInt64
	var memoryUsedBytes: UInt64 = 0
	/// 1 normal, 2 warning, 4 critical.
	var memoryPressure = 1
	var swapUsedBytes: UInt64 = 0
	var onBattery = false
	var ncpu = 8
	/// Impact over the last week, if any has been recorded.
	var week: ImpactSummary?
	var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

	/// Read the live state of this Mac.
	static func current(groups: [AppGroup], store: RuleStore, frontmostPid: pid_t) -> SuggestionInput {
		var mem = pk_memory_stats()
		pk_memory_stats_get(&mem)
		let system = SystemState.read()
		let stats = StatsStore(directory: store.fileURL.deletingLastPathComponent())
		let week = stats.summary(days: 7)
		return SuggestionInput(groups: groups, rules: store.rules,
							   autoEnabled: UserDefaults.standard.bool(forKey: Prefs.autoEnabled),
							   frontmostPid: frontmostPid, memoryBytes: SystemInfo.info.memsize, memoryUsedBytes: mem.used,
							   memoryPressure: system.memoryPressure, swapUsedBytes: Swap.usedBytes,
							   onBattery: system.onBattery, ncpu: SystemInfo.ncpu,
							   week: week.uptimeSeconds > 0 ? week : nil)
	}
}

enum Swap {
	static var usedBytes: UInt64 {
		var usage = xsw_usage()
		var size = MemoryLayout<xsw_usage>.size
		return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
	}
}

enum Suggestions {
	/// Browsers with a built-in "sleep inactive tabs" feature, and where to find it.
	static let browserMemorySettings: [String: String] = [
		"com.google.Chrome": "chrome://settings/performance → Memory Saver",
		"com.brave.Browser": "brave://settings/system → Memory Saver",
		"com.microsoft.edgemac": "edge://settings/system → Efficiency mode / Sleeping tabs",
		"com.vivaldi.Vivaldi": "Settings → Tabs → Tab Hibernation",
		"com.operasoftware.Opera": "Settings → Battery saver / Tab snoozing",
		"company.thebrowser.Browser": "Arc → Settings → Archive tabs after…",
		"org.mozilla.firefox": "about:preferences → Performance (Firefox unloads tabs automatically when memory is low)",
		"com.apple.Safari": "Safari frees background tabs on its own; close tabs you don't need",
	]

	/// Apps where freezing means missed calls or messages.
	static let messagingHints = ["slack", "whatsapp", "teams", "zoom", "discord", "telegram", "signal", "messages", "mail", "outlook", "skype", "facetime"]

	static func make(_ input: SuggestionInput, app: String? = nil) -> [Suggestion] {
		var out: [Suggestion] = []
		let gb = 1_073_741_824.0
		let ram = Double(max(input.memoryBytes, 1))
		let used = Double(input.memoryUsedBytes)
		let swap = Double(input.swapUsedBytes)
		let shortOfMemory = input.memoryPressure >= 2 || swap > max(1 * gb, ram * 0.1) || used > ram * 0.9

		func rule(for g: AppGroup) -> AppRule? {
			input.rules.filter { $0.matches(g) }.min { $0.matchKind.precedence < $1.matchKind.precedence }
		}
		func autoManages(_ g: AppGroup) -> Bool {
			guard input.autoEnabled, g.kind == .app || g.kind == .background else { return false }
			guard let r = rule(for: g) else { return true }
			return !r.ignored && !(r.enabled && (r.cpuLimitEnabled || r.backgroundMode))
		}
		func limitable(_ g: AppGroup) -> Bool {
			if Protected.contains(g) { return false }
			if let r = rule(for: g), r.ignored { return false }
			return ProcessCatalog.describe(g).safety != .protected
		}
		func target(_ g: AppGroup) -> String { g.name }
		func mbRoundedUp(_ bytes: Double, step: Double = 512) -> Int {
			Int((bytes / 1_048_576 / step).rounded(.up) * step)
		}
		func isMessaging(_ g: AppGroup) -> Bool {
			let n = (g.name + " " + (g.bundleID ?? "")).lowercased()
			return messagingHints.contains { n.contains($0) }
		}

		// Auto mode off: the single biggest lever.
		if !input.autoEnabled {
			out.append(Suggestion(
				id: "auto-off", severity: .medium, category: .auto, app: nil,
				title: "Turn on Auto mode",
				reason: "Auto mode is off, so only your own rules apply and background apps run on the performance cores.",
				benefit: "The app you're using stays at full speed; background apps move to the efficiency cores (≈4–5× less energy for the same work) and share the CPU fairly when the Mac is busy.",
				actions: [.init(label: "Turn Auto on", tool: "set_auto_mode", arguments: ["enabled": true], cli: "appwrangler auto on")]))
		}

		// Memory: big users when the Mac is short of memory.
		let heavyThreshold = max(1.5 * gb, ram * 0.15)
		let heavy = input.groups
			.filter { ($0.kind == .app || $0.kind == .background) && Double($0.footprint) > heavyThreshold && limitable($0) }
			.sorted { $0.footprint > $1.footprint }
		if shortOfMemory, !heavy.isEmpty {
			let top = heavy.prefix(3).map { "\($0.name) \(Fmt.bytes($0.footprint))" }.joined(separator: ", ")
			out.append(Suggestion(
				id: "memory-short", severity: input.memoryPressure >= 4 ? .high : .medium, category: .memory, app: nil,
				title: "Your Mac is short of memory",
				reason: "\(Fmt.bytes(UInt64(used))) of \(Fmt.bytes(input.memoryBytes)) in use" + (swap > 0 ? ", \(Fmt.bytes(UInt64(swap))) swapped to disk" : "")
					+ ". Biggest: \(top).",
				benefit: "Swapping makes every app slower and wears the SSD; trimming the biggest users helps more than any CPU limit.",
				tip: "Quit apps you aren't using; CPU limits don't free memory."))
		}
		for g in heavy where shortOfMemory || Double(g.footprint) > ram * 0.4 {
			let existing = rule(for: g)
			let share = Double(g.footprint) / ram
			let tip = g.bundleID.flatMap { browserMemorySettings[$0] }.map { "Turn on the browser's tab sleeping: \($0)." }
			var actions: [Suggestion.Action] = []
			if existing?.memoryLimitEnabled != true {
				let mb = mbRoundedUp(Double(g.footprint) * 1.25)
				actions.append(.configure("Warn me above \(Fmt.megabytes(Double(mb)))", app: target(g), ["memory_limit_mb": mb, "memory_action": "notify"]))
			}
			if (existing?.pressureAction ?? PressureAction.none) == PressureAction.none, !isMessaging(g) {
				actions.append(.configure("Freeze it in the background when memory runs out", app: target(g), ["low_memory_action": "freeze"]))
			}
			guard !actions.isEmpty || tip != nil else { continue }
			out.append(Suggestion(
				id: "memory-hog:" + ImpactKey.of(g), severity: share > 0.5 || input.memoryPressure >= 4 ? .high : .medium,
				category: .memory, app: g.name,
				title: share >= 1 ? "\(g.name) uses \(Fmt.bytes(g.footprint)) — more than this Mac's \(Fmt.bytes(input.memoryBytes)) of RAM"
					: "\(g.name) uses \(Fmt.bytes(g.footprint)) (\(Int(share * 100))% of RAM)",
				reason: shortOfMemory ? "Your Mac is short of memory and \(g.name) is one of the biggest users." : "\(g.name) alone uses a large share of this Mac's memory.",
				benefit: "Less swapping, so the app you're using stays responsive.",
				tip: tip, actions: actions))
		}

		// CPU: busy things in the background that nothing manages.
		for g in input.groups where g.cpu >= 0.5 && !g.pids.contains(input.frontmostPid) && limitable(g) && !autoManages(g) {
			let existing = rule(for: g)
			if let r = existing, r.isActive, r.cpuLimitEnabled || r.backgroundMode { continue }
			let caution = ProcessCatalog.describe(g).safety == .caution
			let isApp = g.kind == .app || g.kind == .background
			var actions: [Suggestion.Action] = [
				.configure("Run it on the efficiency cores", app: target(g), ["efficiency_cores": true, "background_only": isApp]),
			]
			let cap = max(25, Int((g.cpu * 100 / 2 / 25).rounded(.down) * 25))
			actions.append(.configure("Cap it at \(cap)% CPU" + (isApp ? " while in the background" : ""), app: target(g), ["cpu_limit": cap, "background_only": isApp]))
			if isApp && !input.autoEnabled {
				actions.insert(.init(label: "Let Auto mode handle it", tool: "set_auto_mode", arguments: ["enabled": true],
									 cli: "appwrangler auto on"), at: 0)
			}
			out.append(Suggestion(
				id: "background-cpu:" + ImpactKey.of(g), severity: g.cpu >= 1.5 ? .high : caution ? .low : .medium,
				category: input.onBattery ? .battery : .cpu, app: g.name,
				title: "\(g.name) uses \(Fmt.percent(g.cpu)) CPU in the background",
				reason: "It isn't the app you're using and nothing limits it" + (caution ? ". Other apps may depend on it — limit gently." : ".")
					+ " (Measured over about a second; check again if it's a short spike.)",
				benefit: "Efficiency cores do the same work with ≈4–5× less energy and keep the performance cores free for you.",
				actions: actions))
		}

		// Rules: limits that also slow the app while you use it.
		for r in input.rules where r.isActive && (r.cpuLimitEnabled || r.backgroundMode) && !r.onlyWhenInactive {
			out.append(Suggestion(
				id: "applies-while-focused:" + r.id.uuidString, severity: .medium, category: .rules, app: r.displayName,
				title: "\(r.displayName) is limited even while you use it",
				reason: "Its rule (\(r.summary)) also applies when it's the frontmost app, which makes it feel slow and laggy.",
				benefit: "Full speed while you use it, still efficient in the background.",
				actions: [
					.configure("Only limit it in the background", app: r.displayName, ["background_only": true]),
				] + (input.autoEnabled ? [.configure("Hand it to Auto mode", app: r.displayName, ["use_auto": true])] : [])))
		}

		// Rules: CPU limits that hold an app back most of the time.
		if let week = input.week {
			for row in week.apps {
				let a = row.impact
				guard a.limitedSeconds >= 600, a.heldBackSeconds / a.limitedSeconds > 0.5,
					  a.averageWanted > 2 * max(a.averageAllowed, 0.01),
					  let r = input.rules.first(where: { $0.cpuLimitEnabled && $0.isActive && ruleMatches($0, key: row.key, name: a.name) })
				else { continue }
				let raised = min(Int((a.averageWanted * 100 * 0.75 / 25).rounded(.up) * 25), input.ncpu * 100)
				guard raised > Int(r.cpuLimit) else { continue }
				var actions: [Suggestion.Action] = [
					.configure("Raise the limit to \(raised)%", app: r.displayName, ["cpu_limit": raised]),
				]
				if input.autoEnabled {
					actions.append(.configure("Hand it to Auto mode", app: r.displayName, ["use_auto": true]))
				}
				out.append(Suggestion(
					id: "limit-too-strict:" + r.id.uuidString, severity: .medium, category: .rules, app: r.displayName,
					title: "\(r.displayName)'s CPU limit holds it back most of the time",
					reason: "Over the last week it wanted \(Fmt.percent(a.averageWanted)) on average but was allowed \(Fmt.percent(a.averageAllowed)), and was held back \(Int(a.heldBackSeconds / a.limitedSeconds * 100))% of the time it was limited.",
					benefit: "Fewer stalls and timeouts in that app; Auto mode would still keep it efficient in the background.",
					actions: actions))
			}
		}

		// Rules: memory limits the app is always over.
		for g in input.groups {
			guard let r = rule(for: g), r.isActive, r.memoryLimitEnabled else { continue }
			let footprint = Double(r.includeHelpers ? g.footprint : g.ownerFootprint)
			let limit = r.memoryLimitMB * 1_048_576
			guard footprint > limit * 1.1 else { continue }
			let raised = mbRoundedUp(footprint * 1.25)
			let browserTip = g.bundleID.flatMap { browserMemorySettings[$0] }
			// Raising a limit past most of the RAM would only hide the problem.
			guard Double(raised) * 1_048_576 <= ram * 0.6 else {
				out.append(Suggestion(
					id: "memory-limit-exceeded:" + r.id.uuidString, severity: .low, category: .memory, app: r.displayName,
					title: "\(r.displayName) is over its \(Fmt.megabytes(r.memoryLimitMB)) memory limit",
					reason: "It's using \(Fmt.bytes(UInt64(footprint))). Raising the limit further would leave too little memory for everything else on this \(Fmt.bytes(input.memoryBytes)) Mac.",
					benefit: "Getting the app itself to use less memory is what stops the swapping.",
					tip: browserTip.map { "Make the browser sleep inactive tabs: \($0)." } ?? "Close windows or documents you don't need in it, or restart it.",
					actions: r.pressureAction == .none && !isMessaging(g) && !out.contains(where: { $0.id == "memory-hog:" + ImpactKey.of(g) })
						? [.configure("Freeze it in the background when memory runs out", app: r.displayName, ["low_memory_action": "freeze"])] : []))
				continue
			}
			out.append(Suggestion(
				id: "memory-limit-exceeded:" + r.id.uuidString, severity: r.memoryAction == .notify ? .low : .medium,
				category: .memory, app: r.displayName,
				title: "\(r.displayName) is over its \(Fmt.megabytes(r.memoryLimitMB)) memory limit",
				reason: "It's using \(Fmt.bytes(UInt64(footprint))), so the limit's action (\(r.memoryAction.rawValue)) keeps triggering.",
				benefit: "A limit the app normally stays under only fires when something is really wrong.",
				tip: browserTip.map { "Or make the browser use less: \($0)." },
				actions: [.configure("Raise it to \(Fmt.megabytes(Double(raised)))", app: r.displayName, ["memory_limit_mb": raised])]))
		}

		// Rules for apps that no longer exist.
		for r in input.rules where r.matchKind == .path && r.matchValue.hasPrefix("/") && !input.fileExists(r.matchValue) {
			out.append(Suggestion(
				id: "stale-rule:" + r.id.uuidString, severity: .low, category: .rules, app: r.displayName,
				title: "Rule for \(r.displayName) points to an app that's gone",
				reason: "\(r.matchValue) doesn't exist any more.",
				benefit: "A tidier rule list.",
				actions: [.init(label: "Remove the rule", tool: "remove_rule", arguments: ["app": r.displayName],
								cli: "appwrangler unlimit \(Suggestions.quoted(r.displayName))")]))
		}

		if let app {
			let t = app.lowercased()
			out = out.filter { s in
				guard let a = s.app?.lowercased() else { return false }
				return a == t || a.contains(t) || s.id.lowercased().contains(t)
			}
		}
		return out.sorted { $0.severity < $1.severity }
	}

	static func quoted(_ s: String) -> String { s.contains(" ") || s.contains("'") ? "\"\(s)\"" : s }

	/// Whether a rule covers the app a stats row (`bundle:…`, `path:…`, `name:…`) is about.
	static func ruleMatches(_ r: AppRule, key: String, name: String) -> Bool {
		if key.hasPrefix("bundle:") { return r.matches(bundleID: String(key.dropFirst(7)), path: "", name: name) }
		if key.hasPrefix("path:") { return r.matches(bundleID: nil, path: String(key.dropFirst(5)), name: name) }
		return r.matches(bundleID: nil, path: "", name: name)
	}

	/// Plain-text rendering for the CLI.
	static func text(_ list: [Suggestion]) -> String {
		guard !list.isEmpty else { return "No suggestions — everything looks well tuned right now." }
		var lines: [String] = []
		for (i, s) in list.enumerated() {
			lines.append("\(i + 1). [\(s.severity.rawValue)] \(s.title)")
			lines.append("   Why: \(s.reason)")
			lines.append("   Benefit: \(s.benefit)")
			if let tip = s.tip { lines.append("   Tip: \(tip)") }
			for a in s.actions { lines.append("   → \(a.label):  \(a.cli)") }
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}
}
