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
		/// Low priority work was paused while the Mac needs its resources.
		case shed
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

	mutating func remove(kind: PanelAction.Kind) { items.removeAll { $0.kind == kind } }

	mutating func prune(at now: Date) { items.removeAll { !$0.isVisible(at: now) } }

	func visible(at now: Date, limit: Int = 3) -> [PanelAction] {
		Array(items.filter { $0.isVisible(at: now) }.prefix(limit))
	}
}

/// How AppWrangler treats one app, as the main window offers it. Auto comes first:
/// a custom rule is for apps Auto mode can't handle well, or when you want something specific.
enum Handling: String, CaseIterable, Identifiable {
	case auto
	case custom
	case leaveAlone

	var id: String { rawValue }

	var title: String {
		switch self {
		case .auto: return L("Auto (recommended)")
		case .custom: return L("Custom rule")
		case .leaveAlone: return L("Leave alone")
		}
	}

	/// Memory-only rules don't count: Auto still looks after the app's CPU.
	static func of(_ rule: AppRule?) -> Handling {
		guard let rule else { return .auto }
		if rule.ignored { return .leaveAlone }
		if rule.enabled && (rule.cpuLimitEnabled || rule.backgroundMode) { return .custom }
		return .auto
	}

	/// Change `rule` so the app is handled this way. A rule left with nothing in it should be removed by the caller.
	func apply(to rule: inout AppRule) {
		switch self {
		case .auto:
			rule.cpuLimitEnabled = false
			rule.backgroundMode = false
			rule.ignored = false
		case .custom:
			rule.ignored = false
			rule.enabled = true
		case .leaveAlone:
			rule.ignored = true
			rule.enabled = true
		}
	}
}

/// Decides when the menu bar panel opens by itself because AppWrangler just did something.
struct PanelOpening {
	/// Cards already announced; each is announced once, even if the panel stayed closed.
	private(set) var announced: Set<UUID> = []
	private var lastOpened = Date.distantPast
	/// After opening, wait this long before opening again, so a busy spell doesn't keep popping up.
	static let minimumGap: TimeInterval = 120

	mutating func shouldOpen(cards: [PanelAction], now: Date, enabled: Bool, panelShown: Bool, windowInUse: Bool) -> Bool {
		let fresh = cards.filter { $0.shownAt == nil && !announced.contains($0.id) && $0.isVisible(at: now) }
		guard !fresh.isEmpty else { return false }
		announced.formUnion(fresh.map(\.id))
		if announced.count > 200 { announced = Set(fresh.map(\.id)) }
		guard enabled, !panelShown, !windowInUse, now.timeIntervalSince(lastOpened) >= Self.minimumGap else { return false }
		lastOpened = now
		return true
	}
}
