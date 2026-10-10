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

	/// CPU time in core-seconds → "12 core-min" / "3.4 core-h".
	static func coreTime(_ coreSeconds: Double) -> String {
		if coreSeconds < 60 { return L("%d core-s", Int(coreSeconds.rounded())) }
		if coreSeconds < 3600 { return L("%d core-min", Int((coreSeconds / 60).rounded())) }
		return L("%@ core-h", String(format: "%.1f", coreSeconds / 3600))
	}

	static func duration(_ seconds: Double) -> String {
		let f = DateComponentsFormatter()
		f.unitsStyle = .abbreviated
		f.maximumUnitCount = 2
		f.allowedUnits = seconds >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
		return f.string(from: max(0, seconds)) ?? "0"
	}

	/// Joules → "120 mWh" / "3.2 Wh".
	static func energy(_ joules: Double) -> String {
		let wh = joules / 3600
		return wh < 1 ? String(format: "%.0f mWh", wh * 1000) : String(format: "%.1f Wh", wh)
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
	var date = Date()
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

	#if DEBUG
	func replace(with events: [ActivityEvent]) { self.events = events }
	#endif
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
	static let statsFlushSeconds = "AWStatsFlushSeconds"
	static let autoEnabled = "AWAutoEnabled"
	static let autoEfficiencyAfter = "AWAutoEfficiencyAfter"
	static let autoUseEfficiency = "AWAutoUseEfficiency"
	static let autoShareCPU = "AWAutoShareCPU"
	static let autoBusyPercent = "AWAutoBusyPercent"
	static let autoFreezeIdle = "AWAutoFreezeIdle"
	static let autoFreezeIdleMinutes = "AWAutoFreezeIdleMinutes"
	static let autoAdaptive = "AWAutoAdaptive"
	static let autoShed = "AWAutoShed"
	static let autoProcesses = "AWAutoProcesses"
	static let autoAway = "AWAutoAway"
	static let autoAwayMinutes = "AWAutoAwayMinutes"
	static let autoLearn = "AWAutoLearn"
	/// "Make room for" an app: JSON of RoomFor (MakeRoom.swift).
	static let roomFor = "AWRoomFor"
	static let dismissedAdvice = "AWDismissedAdvice"
	static let mainWindowOpen = "AWMainWindowOpen"
	static let showPanelOnAction = "AWShowPanelOnAction"

	static var autoSettings: AutoSettings {
		let d = UserDefaults.standard
		var s = AutoSettings()
		s.enabled = d.bool(forKey: autoEnabled)
		s.efficiencyAfter = max(0, d.double(forKey: autoEfficiencyAfter))
		s.useEfficiencyCores = d.bool(forKey: autoUseEfficiency)
		s.shareCPU = d.bool(forKey: autoShareCPU)
		s.busyThreshold = min(max(d.double(forKey: autoBusyPercent), 5), 100) / 100
		s.busyThresholdOnBattery = min(s.busyThreshold, 0.5)
		s.freezeIdleWhenLowMemory = d.bool(forKey: autoFreezeIdle)
		s.freezeIdleAfter = min(max(d.double(forKey: autoFreezeIdleMinutes), 1), 24 * 60) * 60
		s.adaptive = d.bool(forKey: autoAdaptive)
		s.shed = d.bool(forKey: autoShed)
		s.processes = d.bool(forKey: autoProcesses)
		s.away = d.bool(forKey: autoAway)
		s.awayAfter = min(max(d.double(forKey: autoAwayMinutes), 1), 120) * 60
		s.learn = d.bool(forKey: autoLearn)
		return s
	}

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
			statsFlushSeconds: 30,
			autoEnabled: true,
			autoEfficiencyAfter: 30,
			autoUseEfficiency: true,
			autoShareCPU: true,
			autoBusyPercent: 75,
			autoFreezeIdle: false,
			autoFreezeIdleMinutes: 10,
			autoAdaptive: true,
			autoShed: true,
			autoProcesses: true,
			autoAway: true,
			autoAwayMinutes: 5,
			autoLearn: true,
			showPanelOnAction: true,
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
	/// Posted by the CLI; userInfo: ["command": String, "target": String?, "dataDir": String].
	static let command = Notification.Name("io.github.intarso.AppWrangler.command")

	static var dataDirKey: String { DataDirectory.url.standardizedFileURL.path }

	/// Distributed notifications reach every running copy; only obey commands
	/// sent for our own data folder (e.g. a test copy's commands must not
	/// pause or freeze things in the user's real AppWrangler).
	static func isForThisInstance(_ info: [String: String], dataDir: String = dataDirKey) -> Bool {
		info["dataDir"] == dataDir
	}
}

/// Small JSON file the running app keeps up to date so the CLI can report status.
struct AppState: Codable {
	var pid: Int32
	var paused: Bool
	var frozen: [String]
	/// Apps currently flagged as using a lot of CPU in the background.
	var runaway: [String]? = nil
	/// Auto mode, e.g. "on — 9 apps: 2 in use, 6 on efficiency cores, 0 capped".
	var auto: String? = nil
	/// What Auto is doing to each app it manages (app name → state).
	var autoApps: [String: String]? = nil
	/// "Making room for Zoom (47 min left)".
	var roomFor: String? = nil
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
