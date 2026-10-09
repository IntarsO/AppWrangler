//
//  WidgetSnapshot.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  What the desktop widget shows. The app writes it (`widget.json` next to the
//  rules) about once a minute; the widget extension, which is sandboxed and
//  can't measure anything itself, only reads it. This file is compiled into
//  both, so it must only use Foundation.
//

import Foundation

struct WidgetSnapshot: Codable, Equatable {
	struct App: Codable, Equatable {
		var name: String
		var cpu: Double			// cores
		var memoryBytes: UInt64
		/// "auto-ecores", "auto-full", "rule", "frozen" or "".
		var state: String
	}

	var updated: Date
	var chip: String
	var cores: Int
	/// Whole-Mac CPU use, 0…1.
	var cpu: Double
	var memoryUsedBytes: UInt64
	var memoryTotalBytes: UInt64
	/// 1 normal, 2 warning, 4 critical.
	var memoryPressure: Int
	var swapUsedBytes: UInt64
	var paused: Bool
	var autoOn: Bool
	var autoManaged: Int
	var autoOnEfficiency: Int
	var autoCapped: Int
	var frozen: [String]
	var savedCPUSecondsToday: Double
	var savedEnergyWhToday: Double
	var topApps: [App]
	var suggestionCount: Int
	var topSuggestion: String?
	/// The first few suggestion titles (for the large widget). Optional so
	/// files written by 1.2.0 still decode.
	var suggestionTitles: [String]? = nil

	/// Older than this and the app has probably stopped.
	static let staleAfter: TimeInterval = 15 * 60

	static func url(_ directory: URL) -> URL { directory.appendingPathComponent("widget.json") }

	/// The real data folder, also from inside the sandboxed widget (whose
	/// home directory is its container).
	static var defaultDirectory: URL {
		let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
		return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AppWrangler")
	}

	static func read(directory: URL = defaultDirectory) -> WidgetSnapshot? {
		read(file: url(directory))
	}

	static func read(file: URL) -> WidgetSnapshot? {
		guard let data = try? Data(contentsOf: file) else { return nil }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try? decoder.decode(WidgetSnapshot.self, from: data)
	}

	func write(directory: URL) {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(self) { try? data.write(to: Self.url(directory), options: .atomic) }
	}

	func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updated) > Self.staleAfter }

	var memoryFraction: Double { memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : 0 }

	static let sample = WidgetSnapshot(
		updated: Date(), chip: "Apple M1", cores: 8, cpu: 0.24, memoryUsedBytes: 6_400_000_000, memoryTotalBytes: 8_589_934_592,
		memoryPressure: 2, swapUsedBytes: 3_000_000_000, paused: false, autoOn: true, autoManaged: 8, autoOnEfficiency: 6,
		autoCapped: 0, frozen: [], savedCPUSecondsToday: 660, savedEnergyWhToday: 1.2,
		topApps: [App(name: "Brave Browser", cpu: 0.32, memoryBytes: 5_000_000_000, state: "auto-full"),
				  App(name: "Claude", cpu: 0.2, memoryBytes: 2_200_000_000, state: "auto-ecores"),
				  App(name: "Slack", cpu: 0.03, memoryBytes: 690_000_000, state: "auto-ecores")],
		suggestionCount: 2, topSuggestion: "Brave Browser uses more than this Mac's RAM",
		suggestionTitles: ["Brave Browser uses more than this Mac's RAM", "Let Auto mode freeze apps you aren't using when memory runs out"])
}
