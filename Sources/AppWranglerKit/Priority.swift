//
//  Priority.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Priorities: some work can wait. When the Mac needs its resources for what you're
//  doing (it's saturated while the app you're using works, or memory is short), low
//  priority work is slowed first and, if the need lasts, paused. It resumes as soon as
//  the Mac has room again, and is never paused for long, so updates still finish.
//
//    • High: never capped, never paused; runs at full speed even in the background.
//    • Normal: the default; handled by Auto as before.
//    • Low: maintenance that can wait. Built in, and deliberately short: updaters
//      and Spotlight / photo analysis helpers. You can set any app or process to Low or High.
//

import Foundation

enum AppPriority: String, Codable, CaseIterable, Identifiable {
	case high, normal, low

	var id: String { rawValue }

	var title: String {
		switch self {
		case .high: return L("High")
		case .normal: return L("Normal")
		case .low: return L("Low")
		}
	}
}

enum Priorities {
	/// Spotlight and photo/media analysis helpers that run as you.
	private static let maintenancePrefixes = ["mdworker", "photoanalysisd", "mediaanalysisd"]
	/// Words that mark an updater ("GoogleSoftwareUpdateAgent", "Microsoft AutoUpdate", "Sparkle Updater").
	private static let updaterWords: Set<String> = ["update", "updates", "updater", "autoupdate"]

	/// Split a name into lowercase words at spaces, punctuation and camelCase.
	static func words(_ name: String) -> [String] {
		let spaced = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
		return spaced.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
	}

	/// Maintenance work that can wait. Conservative on purpose: only processes and background apps
	/// (never an app you use), never Apple's own updaters, never command-line tools from Homebrew
	/// or your projects, and never anything on the protected list.
	static func isMaintenance(name: String, bundleID: String?, path: String, kind: AppKind) -> Bool {
		guard kind == .process || kind == .background else { return false }
		guard !Protected.contains(name: name, bundleID: bundleID, pid: 2), !AppTraits.isBuildTool(name) else { return false }
		let lower = name.lowercased()
		if maintenancePrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
		guard !(bundleID ?? "").lowercased().hasPrefix("com.apple.") else { return false }
		guard path.contains(".app/") || path.contains("/Library/") else { return false }
		return !updaterWords.isDisjoint(with: words(name))
	}

	static func isMaintenance(_ g: AppGroup) -> Bool {
		isMaintenance(name: g.name, bundleID: g.bundleID, path: g.path, kind: g.kind)
	}

	/// Your choice for the app wins; otherwise built-in maintenance is Low and everything else Normal.
	static func of(_ g: AppGroup, rule: AppRule?) -> AppPriority {
		if let rule, rule.ignored { return .normal }
		if let rule, rule.priority != .normal { return rule.priority }
		return isMaintenance(g) ? .low : .normal
	}

	/// Names to keep measuring even when nothing else needs it, so Auto can see this work.
	static let measuredNames = ["mdworker*", "photoanalysisd", "mediaanalysisd", "*updat*"]
}

/// Decides when low priority work is paused and when it resumes.
final class Shedder {
	enum Need: Equatable {
		case none
		/// The Mac is saturated while what you're using is working.
		case cpu
		/// Memory is short.
		case memory
	}

	struct Candidate: Equatable {
		var id: String
		var name: String
		var cpu: Double			// cores
		var footprint: UInt64
	}

	struct Plan: Equatable {
		var pause: [String] = []
		var resume: [String] = []
		var isEmpty: Bool { pause.isEmpty && resume.isEmpty }
	}

	/// The need must last this long before anything is paused.
	var needFor: TimeInterval = 15
	/// The Mac must have had room this long before paused work resumes.
	var calmFor: TimeInterval = 30
	/// Nothing is paused longer than this at a stretch, so updates still finish…
	var maxHold: TimeInterval = 600
	/// …and then it runs undisturbed for this long.
	var rest: TimeInterval = 300
	/// Work that's idle isn't worth pausing: needs at least this much CPU (cores)…
	var minimumCPU = 0.05
	/// …or, when memory is short, at least this much memory.
	var minimumBytes: UInt64 = 100 * 1_048_576

	private var needSince: Date?
	private var calmSince: Date?
	/// "Resume now": nothing is paused again before this.
	private var holdOffUntil: Date?
	/// What's paused, and since when.
	private(set) var paused: [String: Date] = [:]
	private var resting: [String: Date] = [:]

	/// Forget paused work that's no longer frozen (quit, or resumed by hand).
	func sync(stillPaused ids: Set<String>) {
		for id in paused.keys where !ids.contains(id) { paused[id] = nil }
	}

	func reset() {
		needSince = nil
		calmSince = nil
		holdOffUntil = nil
		paused = [:]
		resting = [:]
	}

	/// You asked for everything back: resume what's paused, and pause nothing for `holdOff` seconds.
	func resumeAll(holdOff: TimeInterval = 600, now: Date = Date()) -> [String] {
		let ids = Array(paused.keys)
		paused = [:]
		holdOffUntil = now.addingTimeInterval(holdOff)
		return ids
	}

	func update(_ candidates: [Candidate], need: Need, now: Date = Date()) -> Plan {
		var plan = Plan()
		if need == .none {
			needSince = nil
			calmSince = calmSince ?? now
		} else {
			calmSince = nil
			needSince = needSince ?? now
		}
		let present = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

		for (id, since) in paused {
			if present[id] == nil {
				paused[id] = nil		// it quit
			} else if now.timeIntervalSince(since) >= maxHold {
				plan.resume.append(id)
				paused[id] = nil
				resting[id] = now.addingTimeInterval(rest)
			} else if need == .none, let calm = calmSince, now.timeIntervalSince(calm) >= calmFor {
				plan.resume.append(id)
				paused[id] = nil
			}
		}
		resting = resting.filter { $0.value > now }

		guard need != .none, let start = needSince, now.timeIntervalSince(start) >= (need == .memory ? 5 : needFor),
			  holdOffUntil.map({ now >= $0 }) ?? true else { return plan }
		let worth = candidates.filter { c in
			paused[c.id] == nil && resting[c.id] == nil
				&& (need == .cpu ? c.cpu >= minimumCPU : c.footprint >= minimumBytes)
		}
		for c in worth.sorted(by: { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.footprint > $1.footprint }) {
			plan.pause.append(c.id)
			paused[c.id] = now
		}
		return plan
	}
}
