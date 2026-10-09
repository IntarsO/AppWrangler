//
//  Preferences.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  The app-wide settings from Settings → General, for the CLI
//  (`appwrangler prefs key=value …`) and the MCP server (get/set_preferences).
//  An allowlist: only these keys, with these ranges, can be changed.
//

import Foundation

enum PreferenceSettings {
	enum Kind {
		case bool
		case number(ClosedRange<Double>)
		case choice([String: Int])	// shown name → stored value
	}

	struct Spec {
		let key: String
		let defaultsKey: String
		let kind: Kind
		let help: String
	}

	static let specs: [Spec] = [
		Spec(key: "auto", defaultsKey: Prefs.autoEnabled, kind: .bool, help: "Auto mode on or off."),
		Spec(key: "auto_efficiency_cores", defaultsKey: Prefs.autoUseEfficiency, kind: .bool, help: "Auto moves background apps to the efficiency cores."),
		Spec(key: "auto_efficiency_after", defaultsKey: Prefs.autoEfficiencyAfter, kind: .number(0...3600), help: "Seconds in the background before that (default 30)."),
		Spec(key: "auto_share_cpu", defaultsKey: Prefs.autoShareCPU, kind: .bool, help: "Auto shares the CPU fairly between background apps when the Mac is busy."),
		Spec(key: "auto_busy_percent", defaultsKey: Prefs.autoBusyPercent, kind: .number(30...95), help: "Whole-Mac CPU % above which the Mac counts as busy (default 75; at most 50 on battery)."),
		Spec(key: "auto_adaptive", defaultsKey: Prefs.autoAdaptive, kind: .bool, help: "Auto follows what the Mac needs: working background apps run free when it has room, apps are held sooner on battery or when hot, and memory is relieved early, one app at a time."),
		Spec(key: "auto_shed", defaultsKey: Prefs.autoShed, kind: .bool, help: "Pause low-priority work (updaters, Spotlight and photo analysis, apps you marked Low) while the Mac needs its resources for what you're doing; it resumes when there's room again."),
		Spec(key: "auto_processes", defaultsKey: Prefs.autoProcesses, kind: .bool, help: "Auto also moves command-line processes that run hot to the efficiency cores, only while the Mac needs its resources. Never capped or frozen; never build tools or system software."),
		Spec(key: "auto_away", defaultsKey: Prefs.autoAway, kind: .bool, help: "When you're away (no input, plugged in), nothing is held back so background work finishes at full speed; restored the moment you're back."),
		Spec(key: "auto_away_minutes", defaultsKey: Prefs.autoAwayMinutes, kind: .number(1...120), help: "Minutes without input before you count as away (default 5)."),
		Spec(key: "auto_learn", defaultsKey: Prefs.autoLearn, kind: .bool, help: "Learn which apps you use when (kept on this Mac), to keep the ones you usually use around now at full speed and unfrozen."),
		Spec(key: "freeze_idle", defaultsKey: Prefs.autoFreezeIdle, kind: .bool, help: "Auto freezes apps you haven't used for a while when the Mac is low on memory."),
		Spec(key: "freeze_idle_minutes", defaultsKey: Prefs.autoFreezeIdleMinutes, kind: .number(1...1440), help: "How long an app must be unused first (default 10)."),
		Spec(key: "low_memory_level", defaultsKey: Prefs.pressureLevel, kind: .choice(["warning": 2, "critical": 4]), help: "Memory pressure at which low-memory actions happen: warning or critical (default)."),
		Spec(key: "runaway_alerts", defaultsKey: Prefs.runawayEnabled, kind: .bool, help: "Tell me when an app keeps using a lot of CPU in the background."),
		Spec(key: "runaway_percent", defaultsKey: Prefs.runawayPercent, kind: .number(20...800), help: "CPU % that counts as a lot (default 80)."),
		Spec(key: "runaway_minutes", defaultsKey: Prefs.runawayMinutes, kind: .number(1...30), help: "For how many minutes (default 3)."),
		Spec(key: "notifications", defaultsKey: Prefs.notifications, kind: .bool, help: "Notifications for memory limits, low memory and runaway apps."),
		Spec(key: "show_panel_on_action", defaultsKey: Prefs.showPanelOnAction, kind: .bool, help: "Open the menu bar panel by itself, without taking focus, when AppWrangler freezes or flags an app."),
		Spec(key: "menu_bar_cpu", defaultsKey: Prefs.menuBarCPU, kind: .bool, help: "Show the total CPU % next to the menu bar icon."),
		Spec(key: "pause_shortcut", defaultsKey: Prefs.hotKeyEnabled, kind: .bool, help: "⌃⌥⌘P pauses and resumes all limits."),
	]

	static func current(_ d: UserDefaults = .standard) -> [String: Any] {
		var out: [String: Any] = [:]
		for spec in specs {
			switch spec.kind {
			case .bool: out[spec.key] = d.bool(forKey: spec.defaultsKey)
			case .number: out[spec.key] = d.double(forKey: spec.defaultsKey)
			case .choice(let names):
				let v = d.integer(forKey: spec.defaultsKey)
				out[spec.key] = names.first { $0.value == v }?.key ?? "\(v)"
			}
		}
		return out
	}

	/// Validate everything first, then write; nothing changes if any value is bad.
	static func set(_ values: [String: Any], _ d: UserDefaults = .standard) throws -> [String: Any] {
		var writes: [(String, Any)] = []
		for (key, value) in values {
			guard let spec = specs.first(where: { $0.key == key }) else {
				throw RuleChanges.ParseError(description: "unknown preference \"\(key)\" — valid: " + specs.map(\.key).joined(separator: ", "))
			}
			switch spec.kind {
			case .bool:
				let s = "\(value)".lowercased()
				if let b = value as? Bool { writes.append((spec.defaultsKey, b)) }
				else if ["true", "on", "yes", "1"].contains(s) { writes.append((spec.defaultsKey, true)) }
				else if ["false", "off", "no", "0"].contains(s) { writes.append((spec.defaultsKey, false)) }
				else { throw RuleChanges.ParseError(description: "\(key) must be on or off") }
			case .number(let range):
				let n = (value as? NSNumber).flatMap { $0 is Bool ? nil : $0.doubleValue } ?? Double("\(value)")
				guard let n, n.isFinite, range.contains(n) else {
					throw RuleChanges.ParseError(description: "\(key) must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
				}
				writes.append((spec.defaultsKey, n))
			case .choice(let names):
				guard let v = names["\(value)".lowercased()] else {
					throw RuleChanges.ParseError(description: "\(key) must be one of: " + names.keys.sorted().joined(separator: ", "))
				}
				writes.append((spec.defaultsKey, v))
			}
		}
		for (k, v) in writes { d.set(v, forKey: k) }
		d.synchronize()
		return current(d)
	}
}
