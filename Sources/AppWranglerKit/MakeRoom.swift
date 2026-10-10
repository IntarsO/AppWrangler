//
//  MakeRoom.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  "Make room for Zoom": for a while, one app gets everything it needs. It runs at
//  full speed and is never capped, held or frozen (its own CPU rule is set aside;
//  memory limits still apply). Everything else is tamed hard: efficiency cores
//  at once, a tighter share of the CPU, low priority work paused, and idle apps
//  frozen if memory gets short. Away mode is suspended (in a meeting you may not
//  touch the keyboard). It ends by itself when the time is up.
//

import Foundation

struct RoomFor: Codable, Equatable {
	var name: String
	var bundleID: String?
	/// nil: until you stop it.
	var until: Date?

	func isActive(at now: Date = Date()) -> Bool { until.map { now < $0 } ?? true }

	func matches(_ g: AppGroup) -> Bool {
		if let bundleID { return g.bundleID == bundleID }
		return g.name.caseInsensitiveCompare(name) == .orderedSame
	}

	/// "47 min left", "2 h 5 min left", "until you stop it".
	func remainingText(at now: Date = Date()) -> String {
		guard let until else { return L("until you stop it") }
		let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
		return minutes >= 60 ? L("%d h %d min left", minutes / 60, minutes % 60) : L("%d min left", minutes)
	}

	/// Choices offered in menus (minutes; 0 = until you stop it).
	static let durations: [(minutes: Double, title: String)] = [
		(30, L("30 minutes")), (60, L("1 hour")), (180, L("3 hours")), (0, L("Until I stop it")),
	]

	/// "30m", "90", "1h", "1.5h", "2h30m", "until-stop" / "on" → minutes (0 = until stopped).
	static func parseDuration(_ text: String) -> Double? {
		let t = text.lowercased().trimmingCharacters(in: .whitespaces)
		if ["on", "until-stop", "untilstop", "forever", "0"].contains(t) { return 0 }
		if let n = Double(t), n > 0, n <= 24 * 60 { return n }
		guard let regex = try? NSRegularExpression(pattern: #"^(?:(\d+(?:\.\d+)?)h)?(?:(\d+)m(?:in)?)?$"#),
			  let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
		func group(_ i: Int) -> Double? { Range(m.range(at: i), in: t).flatMap { Double(t[$0]) } }
		let total = (group(1) ?? 0) * 60 + (group(2) ?? 0)
		return total > 0 && total <= 24 * 60 ? total : nil
	}

	static func load(_ d: UserDefaults = .standard, now: Date = Date()) -> RoomFor? {
		guard let data = d.data(forKey: Prefs.roomFor), let room = try? JSONDecoder().decode(RoomFor.self, from: data),
			  room.isActive(at: now) else { return nil }
		return room
	}

	static func save(_ room: RoomFor?, _ d: UserDefaults = .standard) {
		if let room, let data = try? JSONEncoder().encode(room) { d.set(data, forKey: Prefs.roomFor) } else { d.removeObject(forKey: Prefs.roomFor) }
	}
}
