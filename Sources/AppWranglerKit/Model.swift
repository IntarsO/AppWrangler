//
//  Model.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Value types shared by the sampler, enforcer, UI and CLI.
//

import Foundation
import ProcKit

/// What sort of thing a row in the list is.
enum AppKind: Int, Codable, CaseIterable, Identifiable {
	/// Regular app with a Dock icon.
	case app
	/// Menu bar extras and other UI-less apps you installed.
	case background
	/// macOS's own UI agents (Wi-Fi, Control Center, …).
	case system
	/// Command-line tools, daemons and anything without an app bundle.
	case process

	var id: Int { rawValue }

	var title: String {
		switch self {
		case .app: return L("Apps")
		case .background: return L("Menu bar & background apps")
		case .system: return L("macOS system services")
		case .process: return L("Processes")
		}
	}

	var shortTitle: String {
		switch self {
		case .app: return L("App")
		case .background: return L("Background app")
		case .system: return L("macOS service")
		case .process: return L("Process")
		}
	}
}

struct RunningApp {
	let pid: pid_t
	let bundleID: String?
	let name: String
	let bundlePath: String?
	let kind: AppKind
}

struct ProcessStat: Identifiable {
	var id: pid_t { pid }
	let pid: pid_t
	let name: String
	let path: String
	var cpu: Double = 0			// cores (1.0 == 100% of one core)
	var footprint: UInt64 = 0
	var diskRead: Double = 0	// bytes / s
	var diskWrite: Double = 0
	var power: Double = 0		// watts
	var threads: Int = 0
	var measured = false
}

struct AppGroup: Identifiable {
	let id: String
	let ownerPid: pid_t
	let name: String
	let bundleID: String?
	/// Bundle path for apps, executable path for plain processes.
	let path: String
	let kind: AppKind
	var processes: [ProcessStat] = []
	var cpu: Double = 0
	var footprint: UInt64 = 0
	var diskRead: Double = 0
	var diskWrite: Double = 0
	var power: Double = 0
	var threads: Int = 0
	var measured = false

	var isApp: Bool { kind != .process }
	var pids: [pid_t] { processes.map(\.pid) }

	/// Footprint of the main process only (for rules that exclude helpers).
	var ownerFootprint: UInt64 { processes.first { $0.pid == ownerPid }?.footprint ?? footprint }
}

/// Which groups need measuring when the UI is hidden.
struct GroupMatcher {
	var bundleIDs: Set<String> = []
	var paths: Set<String> = []
	var names: Set<String> = []
	var patterns: [String] = []
	var groupIDs: Set<String> = []

	var isEmpty: Bool {
		bundleIDs.isEmpty && paths.isEmpty && names.isEmpty && patterns.isEmpty && groupIDs.isEmpty
	}

	func matches(id: String, bundleID: String?, path: String, name: String) -> Bool {
		if groupIDs.contains(id) || paths.contains(path) || names.contains(name) { return true }
		if let bundleID, bundleIDs.contains(bundleID) { return true }
		return patterns.contains { pattern in Glob.matches(pattern, name) || (bundleID.map { Glob.matches(pattern, $0) } ?? false) }
	}
}

enum Glob {
	/// Case-insensitive shell-style match: `*Helper*`, `com.google.*`.
	static func matches(_ pattern: String, _ text: String) -> Bool {
		fnmatch(pattern.lowercased(), text.lowercased(), 0) == 0
	}
}

struct SampleRequest {
	var apps: [pid_t: RunningApp]
	/// Measure every group (UI visible / runaway scan) rather than only matched ones.
	var includeAll: Bool
	/// Also measure every app (not plain processes) — needed by Auto mode.
	var includeApps = false
	var includeOtherUsers: Bool
	var withThreads: Bool
	var matcher: GroupMatcher
}

struct Snapshot {
	/// Increases with every real sample; re-applying an old snapshot keeps its seq.
	var seq: UInt64 = 0
	var full = false
	var groups: [AppGroup] = []
	var date = Date()
	var systemCPU: Double = 0		// 0...1 of the whole machine
	var memory = pk_memory_stats()
}
