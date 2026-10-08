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

/// Recent per-app averages that the running app shares (as `usage.json` next
/// to the rules) with the CLI and MCP server, so their suggestions are based
/// on minutes of history rather than a one-second sample.
struct UsageAverages: Codable {
	struct App: Codable, Equatable {
		var name: String
		var cpu: Double			// cores, averaged
		var memoryMB: Double
		var minutes: Double		// how much history the average covers
	}

	var updated: Date
	var apps: [String: App]		// keyed by ImpactKey

	static func url(_ directory: URL) -> URL { directory.appendingPathComponent("usage.json") }

	/// Averages written within `maxAge` seconds, or nil (AppWrangler not running).
	static func read(directory: URL, maxAge: TimeInterval = 300, now: Date = Date()) -> UsageAverages? {
		guard let data = try? Data(contentsOf: url(directory)),
			  let usage = try? JSONDecoder().decode(UsageAverages.self, from: data),
			  now.timeIntervalSince(usage.updated) <= maxAge else { return nil }
		return usage
	}

	func write(directory: URL) {
		if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url(directory), options: .atomic) }
	}

	/// Averages for groups with at least `minimumMinutes` of history that use
	/// some CPU or memory (the rest aren't worth a suggestion).
	static func compute(groups: [AppGroup], history: HistoryStore, minimumMinutes: Double = 2, limit: Int = 200) -> [String: App] {
		var out: [(String, App)] = []
		for g in groups {
			let points = history.points(for: g.id)
			guard let first = points.first, let last = points.last else { continue }
			let minutes = last.time.timeIntervalSince(first.time) / 60
			guard minutes >= minimumMinutes else { continue }
			let cpu = points.map(\.cpu).reduce(0, +) / Double(points.count)
			let memory = points.map(\.memory).reduce(0, +) / Double(points.count) / 1_048_576
			guard cpu >= 0.02 || memory >= 100 else { continue }
			out.append((ImpactKey.of(g), App(name: g.name, cpu: cpu, memoryMB: memory.rounded(), minutes: (minutes * 10).rounded() / 10)))
		}
		return Dictionary(out.sorted { $0.1.cpu > $1.1.cpu }.prefix(limit).map { $0 }, uniquingKeysWith: { a, _ in a })
	}
}
