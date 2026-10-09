//
//  Routine.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Two things about you, both private to this Mac:
//
//    • Away: no keyboard or mouse input for a few minutes while you're plugged in.
//      Auto then holds nothing back, so background work finishes at full speed, and
//      restores everything the moment you're back.
//    • Routine: which app you have in front, by weekday and hour. Auto uses it to keep
//      apps you usually use around now at full speed and unfrozen, and to freeze the
//      ones you're unlikely to need soon. Only app identifiers and minutes per
//      weekday-hour are kept, in `patterns.json` next to your rules. Nothing leaves
//      the Mac, and it can be switched off and forgotten.
//

import CoreGraphics
import Foundation

enum AwayMode {
	/// Seconds since the last keyboard, mouse or trackpad event.
	static func idleSeconds() -> TimeInterval {
		CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
	}

	/// Away means idle for `after` seconds, on the charger, not in Low Power Mode and not hot.
	static func isAway(idle: TimeInterval, after: TimeInterval, enabled: Bool, onBattery: Bool, lowPower: Bool, hot: Bool) -> Bool {
		enabled && idle >= after && !onBattery && !lowPower && !hot
	}
}

final class UsagePatterns {
	static let slots = 7 * 24
	/// Minutes of use in one weekday-hour (after decay) that count as "you always use this then".
	static let regular = 45.0
	/// Every week what was learned counts a tenth less, so a routine that changes is followed.
	static let weeklyDecay = 0.9

	private struct File: Codable {
		var updated: Date
		var lastDecay: Date
		var minutes: [String: [Double]]
	}

	private(set) var minutes: [String: [Double]] = [:]
	private var lastDecay: Date
	private let url: URL?
	var calendar = Calendar.current

	/// - Parameter url: where to keep it; nil keeps it in memory only (tests).
	init(url: URL? = nil, now: Date = Date()) {
		self.url = url
		lastDecay = now
		if let url, let data = try? Data(contentsOf: url) {
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			if let file = try? decoder.decode(File.self, from: data) {
				minutes = file.minutes.filter { $0.value.count == Self.slots }
				lastDecay = file.lastDecay
			}
		}
	}

	var isEmpty: Bool { minutes.isEmpty }

	func slot(_ date: Date) -> Int {
		let c = calendar.dateComponents([.weekday, .hour], from: date)
		return ((c.weekday ?? 1) - 1) * 24 + (c.hour ?? 0)
	}

	/// `m` minutes of `key` being the app in front, at `date`.
	func record(_ key: String, minutes m: Double, at date: Date) {
		guard m > 0, m.isFinite else { return }
		var slots = minutes[key] ?? Array(repeating: 0, count: Self.slots)
		slots[slot(date)] += m
		minutes[key] = slots
	}

	/// 0…1: how regularly you use the app in this weekday-hour.
	func expected(_ key: String, at date: Date) -> Double {
		min(1, (minutes[key]?[slot(date)] ?? 0) / Self.regular)
	}

	/// 0…1: how likely you are to use the app now or within `horizon` seconds.
	func likelySoon(_ key: String, at date: Date, horizon: TimeInterval = 3600) -> Double {
		max(expected(key, at: date), expected(key, at: date.addingTimeInterval(horizon)))
	}

	/// Apps you usually use around now.
	func likely(at date: Date, threshold: Double = 0.6) -> Set<String> {
		Set(minutes.keys.filter { expected($0, at: date) >= threshold })
	}

	/// Each week, what was learned counts less; apps that are no longer used drop out.
	func decayIfDue(now: Date) {
		var weeks = 0
		while now.timeIntervalSince(lastDecay) >= 7 * 86_400 && weeks < 52 {
			lastDecay = lastDecay.addingTimeInterval(7 * 86_400)
			weeks += 1
		}
		guard weeks > 0 else { return }
		let factor = pow(Self.weeklyDecay, Double(weeks))
		for (key, slots) in minutes {
			let decayed = slots.map { $0 * factor }
			minutes[key] = decayed.reduce(0, +) < 1 ? nil : decayed
		}
	}

	func reset() {
		minutes = [:]
		if let url { try? FileManager.default.removeItem(at: url) }
	}

	func save(now: Date = Date(), maxApps: Int = 300) {
		guard let url, !minutes.isEmpty else { return }
		var kept = minutes
		if kept.count > maxApps {
			let top = kept.sorted { $0.value.reduce(0, +) > $1.value.reduce(0, +) }.prefix(maxApps)
			kept = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
		}
		let rounded = kept.mapValues { $0.map { ($0 * 10).rounded() / 10 } }
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(File(updated: now, lastDecay: lastDecay, minutes: rounded)) {
			try? data.write(to: url, options: .atomic)
		}
	}
}
