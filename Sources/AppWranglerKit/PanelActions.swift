//
//  PanelActions.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  What the menu bar panel shows: the last ~10 minutes of system CPU and
//  memory for its charts, and short-lived cards for things AppWrangler just
//  did ("Auto froze Photos") with a way to set the app up by hand.
//

import Foundation

struct SystemPoint: Equatable {
	let time: Date
	let cpu: Double			// 0...1 of the whole machine
	let efficiency: Double	// 0...1: the part used by apps on efficiency cores
	let memoryUsed: UInt64
	let pressure: Int		// 1 normal, 2 warning, 4 critical
}

final class SystemHistory {
	let window: TimeInterval
	private(set) var points: [SystemPoint] = []

	init(window: TimeInterval = 600) {
		self.window = window
	}

	func record(_ point: SystemPoint) {
		// Samples come every 1–2 s; keep at most one per second.
		if let last = points.last, point.time.timeIntervalSince(last.time) < 0.9 { points.removeLast() }
		points.append(point)
		if let first = points.first, point.time.timeIntervalSince(first.time) > window {
			points.removeAll { point.time.timeIntervalSince($0.time) > window }
		}
	}

	#if DEBUG
	func replace(with points: [SystemPoint]) { self.points = points }
	#endif
}

struct PanelAction: Identifiable, Equatable {
	enum Kind: Equatable {
		/// Auto mode froze an idle app because memory ran short.
		case autoFreeze
		/// An app's own memory rule acted (notify, freeze or quit).
		case memoryRule
		/// An app's low-memory setting froze or quit it.
		case lowMemoryRule
		/// A background app used a lot of CPU for a while.
		case runaway
	}

	let id = UUID()
	var date = Date()
	let kind: Kind
	let groupID: String
	let name: String
	let bundleID: String?
	let path: String
	let title: String
	let detail: String
	/// When the panel first showed it; the card hides `PanelAction.shownFor` later.
	var shownAt: Date?

	static let shownFor: TimeInterval = 30
	/// Cards nobody saw (panel closed) are dropped after this long.
	static let unseenFor: TimeInterval = 15 * 60

	var info: [String: String] {
		["groupID": groupID, "name": name, "bundleID": bundleID ?? "", "path": path]
	}

	func isVisible(at now: Date) -> Bool {
		if let shownAt { return now.timeIntervalSince(shownAt) < Self.shownFor }
		return now.timeIntervalSince(date) < Self.unseenFor
	}

	/// 1 when just shown, 0 when about to hide.
	func remaining(at now: Date) -> Double {
		guard let shownAt else { return 1 }
		return min(1, max(0, 1 - now.timeIntervalSince(shownAt) / Self.shownFor))
	}
}

struct PanelActions {
	private(set) var items: [PanelAction] = []

	/// Newest first; a newer card for the same app replaces the older one.
	mutating func add(_ action: PanelAction, shown: Bool) {
		var action = action
		if shown { action.shownAt = action.date }
		items.removeAll { $0.groupID == action.groupID }
		items.insert(action, at: 0)
		if items.count > 20 { items.removeLast(items.count - 20) }
	}

	/// The panel opened: start the countdown of every card it now shows.
	mutating func markShown(at now: Date) {
		for i in items.indices where items[i].shownAt == nil && items[i].isVisible(at: now) {
			items[i].shownAt = now
		}
	}

	mutating func dismiss(_ id: UUID) { items.removeAll { $0.id == id } }

	mutating func prune(at now: Date) { items.removeAll { !$0.isVisible(at: now) } }

	func visible(at now: Date, limit: Int = 3) -> [PanelAction] {
		Array(items.filter { $0.isVisible(at: now) }.prefix(limit))
	}
}
