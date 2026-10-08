//
//  Rules.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Per-app resource rules, persisted as JSON in the data directory. A rule
//  follows the app across relaunches (matched by bundle id, path, process name
//  or a name pattern) and covers the app's helper processes by default.
//  The file is watched: edits from the CLI or another instance apply at once.
//

import AppKit

enum MatchKind: String, Codable, CaseIterable, Identifiable {
	case bundleID, path, name, pattern
	var id: String { rawValue }
	var label: String {
		switch self {
		case .bundleID: return L("Bundle ID")
		case .path: return L("Path")
		case .name: return L("Process name")
		case .pattern: return L("Name pattern")
		}
	}

	/// Lower wins when several rules match one app.
	var precedence: Int {
		switch self {
		case .bundleID: return 0
		case .path: return 1
		case .name: return 2
		case .pattern: return 3
		}
	}
}

enum MemoryAction: String, Codable, CaseIterable, Identifiable {
	case notify, freeze, quit, forceQuit
	var id: String { rawValue }
	var label: String {
		switch self {
		case .notify: return L("Notify me")
		case .freeze: return L("Freeze (suspend)")
		case .quit: return L("Quit app")
		case .forceQuit: return L("Force quit")
		}
	}
}

enum PressureAction: String, Codable, CaseIterable, Identifiable {
	case none, freeze, quit
	var id: String { rawValue }
	var label: String {
		switch self {
		case .none: return L("Do nothing")
		case .freeze: return L("Freeze until memory frees up")
		case .quit: return L("Quit app")
		}
	}
}

enum PowerCondition: String, Codable, CaseIterable, Identifiable {
	case any, battery, charger
	var id: String { rawValue }
	var label: String {
		switch self {
		case .any: return L("Always")
		case .battery: return L("Only on battery")
		case .charger: return L("Only when plugged in")
		}
	}
}

struct Schedule: Codable, Equatable {
	var enabled = false
	/// Minutes after midnight. If end < start the window crosses midnight.
	var start = 9 * 60
	var end = 18 * 60
	/// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty = every day.
	var weekdays: Set<Int> = []

	func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
		guard enabled else { return true }
		let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
		let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
		var weekday = c.weekday ?? 1
		let inWindow: Bool
		if start == end {
			inWindow = true
		} else if start < end {
			inWindow = minute >= start && minute < end
		} else {
			// Overnight window: the early-morning part belongs to the previous day's schedule.
			inWindow = minute >= start || minute < end
			if minute < end { weekday = weekday == 1 ? 7 : weekday - 1 }
		}
		return inWindow && (weekdays.isEmpty || weekdays.contains(weekday))
	}
}

struct RuleConditions: Codable, Equatable {
	var power: PowerCondition = .any
	var lowPowerModeOnly = false
	var hotOnly = false
	var schedule = Schedule()

	var isConditional: Bool { power != .any || lowPowerModeOnly || hotOnly || schedule.enabled }

	func applies(_ state: SystemState) -> Bool {
		switch power {
		case .any: break
		case .battery: if !state.onBattery { return false }
		case .charger: if state.onBattery { return false }
		}
		if lowPowerModeOnly && !state.lowPowerMode { return false }
		if hotOnly && !state.isHot { return false }
		return schedule.contains(state.now)
	}

	var summary: String {
		var parts: [String] = []
		switch power {
		case .any: break
		case .battery: parts.append(L("on battery"))
		case .charger: parts.append(L("on charger"))
		}
		if lowPowerModeOnly { parts.append(L("Low Power Mode")) }
		if hotOnly { parts.append(L("when hot")) }
		if schedule.enabled {
			parts.append(String(format: "%02d:%02d–%02d:%02d", schedule.start / 60, schedule.start % 60, schedule.end / 60, schedule.end % 60))
		}
		return parts.joined(separator: ", ")
	}

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		power = try c.decodeIfPresent(PowerCondition.self, forKey: .power) ?? .any
		lowPowerModeOnly = try c.decodeIfPresent(Bool.self, forKey: .lowPowerModeOnly) ?? false
		hotOnly = try c.decodeIfPresent(Bool.self, forKey: .hotOnly) ?? false
		schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? Schedule()
	}
}

struct AppRule: Codable, Identifiable, Equatable {
	var id = UUID()
	var matchKind: MatchKind
	var matchValue: String
	var displayName: String
	var enabled = true

	/// Apply to helper / XPC processes as well as the main process.
	var includeHelpers = true

	var cpuLimitEnabled = false
	/// Percent of one core; may exceed 100 on multi-core machines.
	var cpuLimit: Double = 50
	/// Apply the CPU limit and efficiency cores only while the app isn't
	/// frontmost, so it's at full speed while you use it. On for new rules.
	var onlyWhenInactive = true

	/// Darwin background policy: E-cores only + throttled disk/network I/O.
	var backgroundMode = false

	var memoryLimitEnabled = false
	var memoryLimitMB: Double = 2048
	var memoryAction: MemoryAction = .notify

	/// What to do with this app when the whole Mac runs short of memory.
	var pressureAction: PressureAction = .none

	/// When the limits above are in force.
	var conditions = RuleConditions()

	/// Never suggest limits for this app and leave it out of automatic actions.
	var ignored = false

	var hasLimits: Bool { cpuLimitEnabled || backgroundMode || memoryLimitEnabled || pressureAction != .none }
	var isActive: Bool { enabled && !ignored && hasLimits }

	func isInEffect(_ state: SystemState) -> Bool { isActive && conditions.applies(state) }

	func matches(_ group: AppGroup) -> Bool {
		matches(bundleID: group.bundleID, path: group.path, name: group.name)
	}

	func matches(bundleID: String?, path: String, name: String) -> Bool {
		switch matchKind {
		case .bundleID: return bundleID == matchValue
		case .path: return path == matchValue
		case .name: return name.caseInsensitiveCompare(matchValue) == .orderedSame
		case .pattern: return Glob.matches(matchValue, name) || (bundleID.map { Glob.matches(matchValue, $0) } ?? false)
		}
	}

	var summary: String {
		guard enabled else { return L("Disabled") }
		if ignored { return L("Ignored") }
		var parts: [String] = []
		if cpuLimitEnabled { parts.append(L("CPU %d%%", Int(cpuLimit))) }
		if backgroundMode { parts.append(L("E-cores")) }
		if onlyWhenInactive && (cpuLimitEnabled || backgroundMode) { parts.append(L("background only")) }
		if memoryLimitEnabled { parts.append(L("RAM %@", Fmt.megabytes(memoryLimitMB))) }
		if pressureAction != .none { parts.append(L("low-memory: %@", pressureAction == .freeze ? L("freeze") : L("quit"))) }
		if parts.isEmpty { return L("No limits") }
		let conditions = conditions.summary
		return parts.joined(separator: " · ") + (conditions.isEmpty ? "" : " — " + conditions)
	}

	static func forGroup(_ group: AppGroup) -> AppRule {
		if let bundleID = group.bundleID {
			return AppRule(matchKind: .bundleID, matchValue: bundleID, displayName: group.name)
		}
		if !group.path.isEmpty {
			return AppRule(matchKind: .path, matchValue: group.path, displayName: group.name)
		}
		return AppRule(matchKind: .name, matchValue: group.name, displayName: group.name)
	}

	init(matchKind: MatchKind, matchValue: String, displayName: String) {
		self.matchKind = matchKind
		self.matchValue = matchValue
		self.displayName = displayName
	}

	static let cpuLimitRange: ClosedRange<Double> = 1...10_000			// up to 100 cores
	static let memoryLimitRange: ClosedRange<Double> = 16...16_777_216	// 16 MB … 16 TB

	/// Clamp numbers from any source (UI, CLI, MCP, imported or hand-edited
	/// files) so a typo like 1e19 can't crash later conversions.
	func sanitized() -> AppRule {
		var r = self
		r.cpuLimit = cpuLimit.isFinite ? min(max(cpuLimit, Self.cpuLimitRange.lowerBound), Self.cpuLimitRange.upperBound) : 50
		r.memoryLimitMB = memoryLimitMB.isFinite ? min(max(memoryLimitMB, Self.memoryLimitRange.lowerBound), Self.memoryLimitRange.upperBound) : 2048
		r.conditions.schedule.start = min(max(conditions.schedule.start, 0), 24 * 60 - 1)
		r.conditions.schedule.end = min(max(conditions.schedule.end, 0), 24 * 60 - 1)
		r.conditions.schedule.weekdays = conditions.schedule.weekdays.filter { (1...7).contains($0) }
		return r
	}

	// Decode leniently so older/newer rule files still load.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		matchKind = try c.decode(MatchKind.self, forKey: .matchKind)
		matchValue = try c.decode(String.self, forKey: .matchValue)
		displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? matchValue
		enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		includeHelpers = try c.decodeIfPresent(Bool.self, forKey: .includeHelpers) ?? true
		cpuLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .cpuLimitEnabled) ?? false
		cpuLimit = try c.decodeIfPresent(Double.self, forKey: .cpuLimit) ?? 50
		onlyWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .onlyWhenInactive) ?? false
		backgroundMode = try c.decodeIfPresent(Bool.self, forKey: .backgroundMode) ?? false
		memoryLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryLimitEnabled) ?? false
		memoryLimitMB = try c.decodeIfPresent(Double.self, forKey: .memoryLimitMB) ?? 2048
		memoryAction = try c.decodeIfPresent(MemoryAction.self, forKey: .memoryAction) ?? .notify
		pressureAction = try c.decodeIfPresent(PressureAction.self, forKey: .pressureAction) ?? .none
		conditions = try c.decodeIfPresent(RuleConditions.self, forKey: .conditions) ?? RuleConditions()
		ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
		self = sanitized()
	}
}

/// Turns a user-supplied name ("Google Chrome", com.google.Chrome, node,
/// /path, "*Helper*") into the matching rule, or a new one. Shared by the CLI,
/// the MCP server and suggestions so they all resolve names the same way.
enum RuleTargets {
	enum Problem: Error, CustomStringConvertible {
		case protected(String)
		case tooBroad(String)
		case ambiguous(String, [String])

		var description: String {
			switch self {
			case .protected(let t): return "\(t) is critical to macOS; AppWrangler won't limit it"
			case .tooBroad(let t): return "the pattern \"\(t)\" would match almost everything; use a more specific one (e.g. \"*Helper*\")"
			case .ambiguous(let t, let names): return "\"\(t)\" matches several apps: \(names.joined(separator: ", ")). Use the full name."
			}
		}
	}

	/// Looks up an existing rule (by display name or match value). Never creates one.
	static func resolve(_ target: String, store: RuleStore, apps: [RunningApp], groups: [AppGroup] = [], create: Bool) -> AppRule? {
		let t = target.trimmingCharacters(in: .whitespaces).lowercased()
		guard !t.isEmpty else { return nil }
		if let existing = store.rules.first(where: { $0.displayName.lowercased() == t || $0.matchValue.lowercased() == t }) {
			return existing
		}
		// A running app or process with that name gets a rule for exactly it.
		if let group = groups.first(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t }) {
			if let existing = store.rule(for: group) { return existing }
			return create ? AppRule.forGroup(group) : nil
		}
		guard create else { return nil }
		return try? resolveForWrite(target, store: store, apps: apps).get()
	}

	/// The rule to change for `target`, creating one if needed — or why not.
	static func resolveForWrite(_ target: String, store: RuleStore, apps: [RunningApp],
								installed: (String) -> (name: String, bundleID: String)? = installedApp(named:),
								installedByID: (String) -> String? = installedAppName(bundleID:)) -> Result<AppRule, Problem> {
		let trimmed = target.trimmingCharacters(in: .whitespaces)
		let t = trimmed.lowercased()
		if let problem = check(trimmed) { return .failure(problem) }
		if let existing = store.rules.first(where: { $0.displayName.lowercased() == t || $0.matchValue.lowercased() == t }) {
			return .success(existing)
		}
		if let app = apps.first(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t }) {
			return .success(rule(for: app))
		}
		if trimmed.contains("*") || trimmed.contains("?") {
			return .success(AppRule(matchKind: .pattern, matchValue: trimmed, displayName: trimmed))
		}
		if trimmed.hasPrefix("/") {
			return .success(AppRule(matchKind: .path, matchValue: trimmed, displayName: (trimmed as NSString).lastPathComponent))
		}
		if looksLikeBundleID(trimmed) {
			return .success(AppRule(matchKind: .bundleID, matchValue: trimmed, displayName: installedByID(trimmed) ?? trimmed))
		}
		if let app = installed(trimmed) {
			return .success(AppRule(matchKind: .bundleID, matchValue: app.bundleID, displayName: app.name))
		}
		// Part of a running app's name ("chrome" → Google Chrome), if it's unambiguous.
		var seen = Set<String>()
		let partial = apps.filter { $0.name.lowercased().contains(t) && seen.insert($0.bundleID ?? $0.name).inserted }
		if partial.count == 1 { return .success(rule(for: partial[0])) }
		if partial.count > 1 { return .failure(.ambiguous(trimmed, partial.map(\.name).sorted())) }
		// Otherwise a process name (node, python3, …), matched without regard to case.
		return .success(AppRule(matchKind: .name, matchValue: trimmed, displayName: trimmed))
	}

	private static func rule(for app: RunningApp) -> AppRule {
		if let bundleID = app.bundleID { return AppRule(matchKind: .bundleID, matchValue: bundleID, displayName: app.name) }
		if let path = app.bundlePath { return AppRule(matchKind: .path, matchValue: path, displayName: app.name) }
		return AppRule(matchKind: .name, matchValue: app.name, displayName: app.name)
	}

	/// Targets AppWrangler refuses outright.
	static func check(_ target: String) -> Problem? {
		if Protected.contains(name: target, bundleID: target, pid: 2) { return .protected(target) }
		if target.contains("*") || target.contains("?") {
			let literal = target.filter { !"*?[]".contains($0) }
			if literal.count < 3 { return .tooBroad(target) }
		}
		return nil
	}

	/// com.google.Chrome, org.mozilla.firefox — at least three dot-separated parts.
	static func looksLikeBundleID(_ s: String) -> Bool {
		s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
	}

	/// An installed (not necessarily running) app with this name, from the usual folders.
	static func installedApp(named name: String) -> (name: String, bundleID: String)? {
		let fm = FileManager.default
		let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
					fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
		let wanted = name.lowercased().hasSuffix(".app") ? name.lowercased() : name.lowercased() + ".app"
		for dir in dirs {
			guard let entry = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.lowercased() == wanted }),
				  let bundle = Bundle(path: dir + "/" + entry), let id = bundle.bundleIdentifier else { continue }
			return ((entry as NSString).deletingPathExtension, id)
		}
		return nil
	}

	static func installedAppName(bundleID: String) -> String? {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
		return url.deletingPathExtension().lastPathComponent
	}
}

/// Carries settings over from the AppPolice builds this project grew out of.
enum Migration {
	/// AppPolice 1.x kept per-app limits in its own defaults domain.
	static var legacyDefaults: UserDefaults {
		UserDefaults(suiteName: "com.definemac.AppPolice") ?? .standard
	}

	static var appPoliceDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AppPolice", isDirectory: true)
	}

	/// Copy rules.json from the AppPolice 2.x data folder on first launch.
	/// Returns true if rules were imported.
	@discardableResult
	static func importAppPoliceRules(from old: URL = appPoliceDirectory, into new: URL = DataDirectory.url) -> Bool {
		let fm = FileManager.default
		let source = old.appendingPathComponent("rules.json")
		let target = new.appendingPathComponent("rules.json")
		guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) else { return false }
		try? fm.createDirectory(at: new, withIntermediateDirectories: true)
		return (try? fm.copyItem(at: source, to: target)) != nil
	}
}

/// Where rules and state live. `APPWRANGLER_DATA_DIR` overrides it (tests, e2e).
enum DataDirectory {
	static var isOverridden: Bool {
		!(ProcessInfo.processInfo.environment["APPWRANGLER_DATA_DIR"] ?? "").isEmpty
	}

	static var url: URL {
		if let custom = ProcessInfo.processInfo.environment["APPWRANGLER_DATA_DIR"], !custom.isEmpty {
			return URL(fileURLWithPath: custom, isDirectory: true)
		}
		return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AppWrangler", isDirectory: true)
	}
}

final class RuleStore: ObservableObject {
	@Published var rules: [AppRule] = [] {
		didSet { if rules != oldValue && !loading { scheduleSave() } }
	}

	/// Called on the main queue after the file changed on disk (CLI edits etc.).
	var onExternalChange: (() -> Void)?

	let fileURL: URL
	private let defaults: UserDefaults
	private var saveWork: DispatchWorkItem?
	private var loading = false
	private var lastWritten: Data?
	/// The rules as last read from or written to disk; a save applies only what
	/// changed since, on top of the file as it is then (another process may have
	/// written it meanwhile: the app, the CLI, an MCP server).
	private var baseline: [AppRule] = []
	private var lastSeenModification: Date?
	private var watcher: DispatchSourceFileSystemObject?
	private let ioQueue = DispatchQueue(label: "AppWrangler.rules.io", qos: .utility)

	init(directory: URL = DataDirectory.url, defaults: UserDefaults = .standard) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		fileURL = directory.appendingPathComponent("rules.json")
		self.defaults = defaults
		load()
	}

	func rule(for group: AppGroup) -> AppRule? {
		rule(bundleID: group.bundleID, path: group.path, name: group.name)
	}

	/// Most specific match wins: bundle id, path, name, then pattern.
	func rule(bundleID: String?, path: String, name: String) -> AppRule? {
		rules.filter { $0.matches(bundleID: bundleID, path: path, name: name) }
			.min { $0.matchKind.precedence < $1.matchKind.precedence }
	}

	func upsert(_ rule: AppRule) {
		let rule = rule.sanitized()
		if let i = rules.firstIndex(where: { $0.id == rule.id }) {
			rules[i] = rule
		} else {
			rules.append(rule)
		}
	}

	func remove(id: UUID) {
		rules.removeAll { $0.id == id }
	}

	/// Rules currently worth measuring for (conditions are checked by the enforcer).
	func matcher(for state: SystemState) -> GroupMatcher {
		var m = GroupMatcher()
		for rule in rules where rule.isInEffect(state) {
			switch rule.matchKind {
			case .bundleID: m.bundleIDs.insert(rule.matchValue)
			case .path: m.paths.insert(rule.matchValue)
			case .name: m.names.insert(rule.matchValue)
			case .pattern: m.patterns.append(rule.matchValue)
			}
		}
		return m
	}

	// MARK: Import / export

	func exportData() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try encoder.encode(rules)
	}

	/// Merge rules from JSON; a rule for the same app replaces the existing one.
	/// Returns the number of rules imported.
	@discardableResult
	func importData(_ data: Data) throws -> Int {
		let incoming = try JSONDecoder().decode([AppRule].self, from: data)
		var merged = rules
		for var rule in incoming {
			if let i = merged.firstIndex(where: { $0.matchKind == rule.matchKind && $0.matchValue == rule.matchValue }) {
				rule.id = merged[i].id
				merged[i] = rule
			} else {
				if merged.contains(where: { $0.id == rule.id }) { rule.id = UUID() }
				merged.append(rule)
			}
		}
		rules = merged
		return incoming.count
	}

	// MARK: Persistence

	private func load() {
		if let data = try? Data(contentsOf: fileURL),
		   let decoded = try? JSONDecoder().decode([AppRule].self, from: data) {
			loading = true
			rules = decoded
			baseline = decoded
			loading = false
			return
		}
		migrateLegacyLimits()
	}

	/// Re-read the file. Returns true if the rules changed.
	@discardableResult
	func reloadFromDisk() -> Bool {
		// A pending local edit wins; our own writes aren't external changes.
		guard saveWork == nil,
			  let data = try? Data(contentsOf: fileURL),
			  data != lastWritten,
			  let decoded = try? JSONDecoder().decode([AppRule].self, from: data),
			  decoded != rules
		else { return false }
		loading = true
		rules = decoded
		baseline = decoded
		loading = false
		return true
	}

	/// `disk` plus whatever `local` added, changed or removed relative to `base`.
	static func merge(local: [AppRule], base: [AppRule], disk: [AppRule]) -> [AppRule] {
		var result = disk
		let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
		for rule in local where baseByID[rule.id] != rule {
			if let i = result.firstIndex(where: { $0.id == rule.id }) { result[i] = rule } else { result.append(rule) }
		}
		let localIDs = Set(local.map(\.id))
		for rule in base where !localIDs.contains(rule.id) {
			result.removeAll { $0.id == rule.id }
		}
		return result
	}

	/// AppPolice 1.x stored `{ "App Name": fraction }` under APApplicationLimits.
	private func migrateLegacyLimits() {
		guard let legacy = defaults.dictionary(forKey: "APApplicationLimits") as? [String: NSNumber] else { return }
		rules = legacy.compactMap { name, value in
			let fraction = value.doubleValue
			guard fraction > 0 else { return nil }
			var rule = AppRule(matchKind: .name, matchValue: name, displayName: name)
			rule.cpuLimitEnabled = true
			rule.cpuLimit = (fraction * 100).rounded()
			return rule
		}.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
	}

	private static func encode(_ rules: [AppRule]) -> Data? {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try? encoder.encode(rules)
	}

	private func scheduleSave() {
		saveWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.write(sync: false) }
		saveWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
	}

	private func write(sync: Bool) {
		saveWork = nil
		let local = rules, base = baseline, url = fileURL
		let lockPath = fileURL.deletingLastPathComponent().appendingPathComponent(".rules.lock").path
		// Under a lock shared by every AppWrangler process: read what's on disk now,
		// apply our own changes to it, write.
		let merge: () -> ([AppRule], Data?) = {
			let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
			if fd >= 0 { flock(fd, LOCK_EX) }
			defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
			let disk = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? base
			let merged = Self.merge(local: local, base: base, disk: disk)
			guard let data = Self.encode(merged) else { return (merged, nil) }
			try? data.write(to: url, options: .atomic)
			return (merged, data)
		}
		// Back on the main queue: adopt others' changes, keeping edits made since.
		let adopt: ([AppRule], Data?) -> Void = { [weak self] merged, data in
			guard let self else { return }
			if let data { self.lastWritten = data }
			let current = Self.merge(local: self.rules, base: local, disk: merged)
			self.baseline = merged
			if current != self.rules {
				self.loading = true
				self.rules = current
				self.loading = false
				self.onExternalChange?()
			}
		}
		if sync {
			let (merged, data) = ioQueue.sync(execute: merge)
			adopt(merged, data)
		} else {
			ioQueue.async {
				let (merged, data) = merge()
				DispatchQueue.main.async { adopt(merged, data) }
			}
		}
	}

	/// Flush pending changes to disk now (quit, CLI, tests).
	func saveNow() {
		guard let work = saveWork else {
			ioQueue.sync {}		// wait for an in-flight async write
			return
		}
		work.cancel()
		write(sync: true)
	}

	/// Watch the data directory (atomic writes replace the file, so watching
	/// the file itself would lose track after the first edit).
	func startWatching() {
		let dir = fileURL.deletingLastPathComponent().path
		let fd = open(dir, O_EVTONLY)
		guard fd >= 0 else { return }
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
		source.setEventHandler { [weak self] in
			guard let self else { return }
			// Let the writer finish its rename before reading.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				// Other files in the folder (state, stats) change too; only re-read rules when they changed.
				let stamp = (try? FileManager.default.attributesOfItem(atPath: self.fileURL.path))?[.modificationDate] as? Date
				guard stamp != self.lastSeenModification else { return }
				self.lastSeenModification = stamp
				if self.reloadFromDisk() { self.onExternalChange?() }
			}
		}
		source.setCancelHandler { close(fd) }
		source.resume()
		watcher = source
	}
}
