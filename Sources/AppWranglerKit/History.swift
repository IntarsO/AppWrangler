//
//  History.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Last ~10 minutes of CPU / memory / power per app for the detail charts.
//

import Foundation

struct HistoryPoint {
	let time: Date
	let cpu: Double		// cores
	let memory: Double	// bytes
	let power: Double	// watts
}

final class HistoryStore {
	let window: TimeInterval
	private var series: [String: [HistoryPoint]] = [:]
	private var lastSeen: [String: Date] = [:]

	init(window: TimeInterval = 600) {
		self.window = window
	}

	func record(_ snapshot: Snapshot) {
		let now = snapshot.date
		for group in snapshot.groups where group.measured {
			var points = series[group.id] ?? []
			points.append(HistoryPoint(time: now, cpu: group.cpu, memory: Double(group.footprint), power: group.power))
			if let first = points.first, now.timeIntervalSince(first.time) > window {
				points.removeAll { now.timeIntervalSince($0.time) > window }
			}
			series[group.id] = points
			lastSeen[group.id] = now
		}
		// Forget apps that have been gone for a whole window.
		for (id, seen) in lastSeen where now.timeIntervalSince(seen) > window {
			series[id] = nil
			lastSeen[id] = nil
		}
	}

	func points(for groupID: String) -> [HistoryPoint] { series[groupID] ?? [] }
}
