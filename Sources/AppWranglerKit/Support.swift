//
//  Support.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//

import AppKit
import ProcKit

// MARK: - Localization

/// Localized string. Keys are the English text; translations live in
/// Resources/<lang>.lproj/Localizable.strings (checked by LocalizationTests).
func L(_ key: String) -> String {
	NSLocalizedString(key, bundle: .main, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
	String(format: NSLocalizedString(key, bundle: .main, comment: ""), locale: .current, arguments: args)
}

enum Fmt {
	static func percent(_ cores: Double) -> String {
		let v = cores * 100
		return v < 10 ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v)
	}

	static func bytes(_ b: UInt64) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
	}

	static func megabytes(_ mb: Double) -> String {
		mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
	}

	static func rate(_ bytesPerSecond: Double) -> String {
		bytesPerSecond < 1024 ? L("0 KB/s") : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + L("/s")
	}

	static func watts(_ w: Double) -> String {
		w < 0.1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.1f W", w)
	}
}

enum SystemInfo {
	static let info: pk_system_info = {
		var i = pk_system_info()
		pk_system_info_get(&i)
		return i
	}()

	static var chip: String { withUnsafeBytes(of: info.chip) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
	static var ncpu: Int { Int(info.ncpu) }
	static var memsize: UInt64 { info.memsize }

	static var summary: String {
		var s = chip
		if info.pcores > 0 && info.ecores > 0 { s += " · \(info.pcores)P + \(info.ecores)E" } else { s += " · " + L("%d cores", ncpu) }
		return s + " · " + Fmt.bytes(memsize)
	}
}

struct ActivityEvent: Identifiable {
	let id = UUID()
	let date = Date()
	let app: String
	let message: String
}

final class ActivityLog: ObservableObject {
	@Published private(set) var events: [ActivityEvent] = []

	/// Set by the app to deliver notifications.
	var notifier: ((String, String) -> Void)?

	func add(_ app: String, _ message: String, notify: Bool = false) {
		events.insert(ActivityEvent(app: app, message: message), at: 0)
		if events.count > 300 { events.removeLast(events.count - 300) }
		if notify { notifier?(app, message) }
	}

	func clear() { events.removeAll() }
}

enum Prefs {
	static let uiInterval = "AWUIInterval"
	static let enforceInterval = "AWEnforceInterval"
	static let limiterPeriodMs = "AWLimiterPeriodMs"
	static let showOtherUsers = "AWShowOtherUsers"
	static let notifications = "AWNotifications"
	static let menuBarCPU = "AWMenuBarCPU"
	static let sortBy = "AWSortKey"
	static let collapsedSections = "AWCollapsedSections"
	static let runawayEnabled = "AWRunawayEnabled"
	static let runawayPercent = "AWRunawayPercent"
	static let runawayMinutes = "AWRunawayMinutes"
	static let pressureLevel = "AWPressureLevel"
	static let hotKeyEnabled = "AWHotKeyEnabled"

	static func register() {
		UserDefaults.standard.register(defaults: [
			uiInterval: 1.0,
			enforceInterval: 2.0,
			limiterPeriodMs: 50,
			showOtherUsers: false,
			notifications: true,
			menuBarCPU: false,
			sortBy: SortKey.cpu.rawValue,
			collapsedSections: "\(AppKind.system.rawValue),\(AppKind.process.rawValue)",
			runawayEnabled: true,
			runawayPercent: 80,
			runawayMinutes: 3,
			pressureLevel: 4,
			hotKeyEnabled: true,
		])
	}
}

// MARK: - Links

enum Links {
	static let repository = URL(string: "https://github.com/IntarsO/AppWrangler")!
	static let documentation = URL(string: "https://github.com/IntarsO/AppWrangler/blob/main/docs/getting-started.md")!
	static let issues = URL(string: "https://github.com/IntarsO/AppWrangler/issues")!
	static let upstream = URL(string: "https://github.com/fuyu/AppPolice")!
}

// MARK: - Inter-process (CLI ⇄ app)

enum IPC {
	/// Posted by the CLI; userInfo: ["command": String, "target": String?].
	static let command = Notification.Name("io.github.intarso.AppWrangler.command")
}

/// Small JSON file the running app keeps up to date so the CLI can report status.
struct AppState: Codable {
	var pid: Int32
	var paused: Bool
	var frozen: [String]
	/// Apps currently flagged as using lots of CPU in the background.
	var runaway: [String]? = nil
	var updated: Date

	static var url: URL { DataDirectory.url.appendingPathComponent("state.json") }

	static func read() -> AppState? {
		guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(AppState.self, from: data) else { return nil }
		// Stale file from a crashed instance?
		return kill(state.pid, 0) == 0 ? state : nil
	}

	func write() {
		if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
	}

	static func remove() { try? FileManager.default.removeItem(at: url) }
}

/// One enforcing instance per data directory: two would fight over SIGSTOP/SIGCONT.
enum InstanceLock {
	private static var fd: Int32 = -1

	static func acquire() -> Bool {
		try? FileManager.default.createDirectory(at: DataDirectory.url, withIntermediateDirectories: true)
		let path = DataDirectory.url.appendingPathComponent(".lock").path
		fd = open(path, O_CREAT | O_RDWR, 0o644)
		guard fd >= 0 else { return true }
		return flock(fd, LOCK_EX | LOCK_NB) == 0
	}
}

enum SortKey: String, CaseIterable, Identifiable {
	case cpu, memory, power, name
	var id: String { rawValue }
	var label: String {
		switch self {
		case .cpu: return L("CPU")
		case .memory: return L("Memory")
		case .power: return L("Energy")
		case .name: return L("Name")
		}
	}
}
