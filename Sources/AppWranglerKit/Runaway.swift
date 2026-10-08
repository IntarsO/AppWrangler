//
//  Runaway.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Spots apps that burn CPU in the background for minutes on end and suggests
//  a limit, e.g. "Chrome Helper has used 150% CPU for 5 minutes".
//

import Foundation

struct RunawaySuggestion: Identifiable, Equatable {
	var id: String { groupID }
	let groupID: String
	let name: String
	let bundleID: String?
	let path: String
	let kind: AppKind
	let averageCPU: Double		// cores
	let minutes: Int
}

final class RunawayDetector {
	/// Average usage (in cores) that counts as runaway.
	var threshold: Double = 0.8
	/// How long it must be sustained.
	var duration: TimeInterval = 180
	/// Don't nag about the same app more often than this.
	var cooldown: TimeInterval = 3600

	private var windows: [String: [(time: Date, cpu: Double)]] = [:]
	private var lastSuggested: [String: Date] = [:]

	/// Feed a *full* snapshot; returns newly raised suggestions.
	func observe(_ snapshot: Snapshot, frontmostPid: pid_t, now: Date = Date(),
				 isExempt: (AppGroup) -> Bool) -> [RunawaySuggestion] {
		var seen = Set<String>()
		var raised: [RunawaySuggestion] = []
		for group in snapshot.groups where group.measured {
			seen.insert(group.id)
			// Busy while you're using it is expected; only background burn counts.
			if group.ownerPid == frontmostPid || isExempt(group) || Protected.contains(group) {
				windows[group.id] = nil
				continue
			}
			var window = windows[group.id] ?? []
			window.append((now, group.cpu))
			window.removeAll { now.timeIntervalSince($0.time) > duration }
			windows[group.id] = window

			guard let first = window.first, now.timeIntervalSince(first.time) >= duration * 0.9 else { continue }
			let average = window.map(\.cpu).reduce(0, +) / Double(window.count)
			guard average >= threshold else { continue }
			if let last = lastSuggested[group.id], now.timeIntervalSince(last) < cooldown { continue }
			lastSuggested[group.id] = now
			raised.append(RunawaySuggestion(groupID: group.id, name: group.name, bundleID: group.bundleID, path: group.path,
											kind: group.kind, averageCPU: average, minutes: max(1, Int((duration / 60).rounded()))))
		}
		for id in windows.keys where !seen.contains(id) { windows[id] = nil }
		return raised
	}

	func snooze(_ groupID: String, now: Date = Date()) {
		lastSuggested[groupID] = now
		windows[groupID] = nil
	}
}
