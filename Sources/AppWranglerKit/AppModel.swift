//
//  AppModel.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Owns the sampling cadence. Monitoring is adaptive:
//    • UI open                → every process, every `APUIInterval` (1 s)
//    • UI closed, rules exist → only ruled/frozen apps, every `APEnforceInterval` (2 s)
//    • runaway detection on   → plus a full scan every ~5 s
//    • nothing to do          → no timer at all
//  Rule edits (UI, CLI, file), app launches, focus changes and power/thermal/
//  memory-pressure changes all trigger an immediate pass — no restart needed.
//

import AppKit
import Combine
import ProcKit

final class AppModel: ObservableObject {
	static let shared = AppModel()

	let rules: RuleStore
	let log = ActivityLog()
	let enforcer: Enforcer
	let history = HistoryStore()
	let runaway = RunawayDetector()
	let system = SystemStateMonitor()

	@Published private(set) var snapshot = Snapshot()
	@Published private(set) var limiterStatus: [String: pk_lim_status] = [:]
	@Published private(set) var suggestions: [RunawaySuggestion] = []
	@Published private(set) var systemState = SystemState()
	@Published var paused = false {
		didSet {
			guard paused != oldValue else { return }
			enforcer.setPaused(paused)
			log.add("AppWrangler", paused ? L("CPU limits paused (frozen apps stay frozen)") : L("Limits resumed"))
			writeState()
		}
	}

	/// Called with the latest system CPU load for the menu bar title.
	var onSystemCPU: ((Double) -> Void)?

	private let sampler = Sampler()
	private var timer: Timer?
	private var timerInterval: TimeInterval?
	private var visibleSurfaces = 0
	private var apps: [pid_t: RunningApp] = [:]
	private var appsDirty = true
	private var frontmostPid: pid_t = 0
	private var lastSnapshot = Snapshot()
	private var lastFullScan = Date.distantPast
	private var cancellables: Set<AnyCancellable> = []
	private var pendingTick: DispatchWorkItem?
	private var started = false
	private var runningAppsObservation: NSKeyValueObservation?

	init(rules: RuleStore = RuleStore(defaults: Migration.legacyDefaults), controller: ProcessController = LiveProcessController()) {
		self.rules = rules
		self.enforcer = Enforcer(controller: controller)
		enforcer.onEvent = { [weak self] app, message, notify in self?.log.add(app, message, notify: notify) }
		log.notifier = { title, body in Notifier.shared.post(title: title, body: body) }
	}

	var uiVisible: Bool { visibleSurfaces > 0 }

	func start() {
		guard !started else { return }
		started = true
		// Watch the running-apps list itself: macOS posts no didLaunchApplication
		// notification for menu bar / background (LSUIElement) apps, so relying on
		// it left their bundle-ID rules unapplied until something else refreshed.
		runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
			DispatchQueue.main.async {
				self?.appsDirty = true
				self?.tickSoon(0.2)
			}
		}
		let ws = NSWorkspace.shared.notificationCenter
		ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
			guard let self else { return }
			let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
			self.frontmostPid = app?.processIdentifier ?? 0
			self.reapply()	// "only while in background" rules switch instantly
		}
		ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
			self?.tickSoon(1)
		}
		frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

		// Rule edits from the UI…
		rules.$rules
			.dropFirst()
			.debounce(for: .milliseconds(100), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.rulesChanged() }
			.store(in: &cancellables)
		// …and from the CLI / another editor.
		rules.onExternalChange = { [weak self] in
			self?.log.add("AppWrangler", L("Rules reloaded from disk"))
			self?.rulesChanged()
		}
		rules.startWatching()

		DistributedNotificationCenter.default().addObserver(forName: IPC.command, object: nil, queue: .main) { [weak self] note in
			self?.handleCommand(note.userInfo as? [String: String] ?? [:])
		}

		system.onChange = { [weak self] state in
			guard let self else { return }
			self.systemState = state
			self.reapply()
			self.tickSoon(0.05)
		}
		system.start()
		systemState = system.current

		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.debounce(for: .milliseconds(200), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.preferencesChanged() }
			.store(in: &cancellables)

		preferencesChanged()
		writeState()
		tick()
	}

	// MARK: Visibility

	func surfaceDidAppear() {
		visibleSurfaces += 1
		if visibleSurfaces == 1 {
			reschedule()
			tick()
			tickSoon(0.5)	// second sample quickly so rates are populated
		}
	}

	func surfaceDidDisappear() {
		visibleSurfaces = max(0, visibleSurfaces - 1)
		if visibleSurfaces == 0 { reschedule() }
	}

	// MARK: Scheduling

	private func preferencesChanged() {
		let d = UserDefaults.standard
		pk_lim_set_period_ms(UInt32(max(10, d.integer(forKey: Prefs.limiterPeriodMs))))
		enforcer.pressureThreshold = d.integer(forKey: Prefs.pressureLevel) >= 4 ? 4 : 2
		runaway.threshold = max(0.1, d.double(forKey: Prefs.runawayPercent) / 100)
		runaway.duration = max(60, d.double(forKey: Prefs.runawayMinutes) * 60)
		reschedule()
	}

	private var runawayEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.runawayEnabled) }

	private var needsBackgroundSampling: Bool {
		rules.rules.contains { $0.isActive } || !enforcer.frozen.isEmpty || runawayEnabled
			|| UserDefaults.standard.bool(forKey: Prefs.menuBarCPU)
	}

	func reschedule() {
		let d = UserDefaults.standard
		let interval: TimeInterval?
		if uiVisible {
			interval = max(0.5, d.double(forKey: Prefs.uiInterval))
		} else if needsBackgroundSampling {
			interval = max(1, d.double(forKey: Prefs.enforceInterval))
		} else {
			interval = nil
		}
		guard interval != timerInterval else { return }
		timer?.invalidate()
		timer = nil
		timerInterval = interval
		guard let interval else { return }
		let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
		t.tolerance = interval * 0.25	// let the system coalesce wakeups
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	private func tickSoon(_ delay: TimeInterval) {
		pendingTick?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.tick() }
		pendingTick = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func rulesChanged() {
		reapply()		// lift/adjust limits on already-measured apps right away
		reschedule()
		tickSoon(0)		// and measure newly ruled apps
	}

	/// Re-run the enforcer on the last sample (focus, condition or rule change).
	private func reapply() {
		var state = system.current
		state.now = Date()
		enforcer.apply(lastSnapshot, rules: rules, state: state, frontmostPid: frontmostPid)
		writeState()
	}

	func tick() {
		if appsDirty {
			appsDirty = false
			apps = RunningApps.collect()
		}
		let d = UserDefaults.standard
		var state = system.refresh()
		state.now = Date()
		// Full scans: UI open, or periodically for runaway detection.
		let full = uiVisible || (runawayEnabled && Date().timeIntervalSince(lastFullScan) >= 5)
		var matcher = rules.matcher(for: state)
		matcher.groupIDs.formUnion(enforcer.trackedGroupIDs)
		if !full && matcher.isEmpty && !needsBackgroundSampling {
			// Nothing to watch: just make sure limits from removed rules are lifted.
			lastSnapshot = Snapshot()
			enforcer.apply(lastSnapshot, rules: rules, state: state, frontmostPid: frontmostPid)
			return
		}
		let request = SampleRequest(
			apps: apps,
			includeAll: full,
			includeOtherUsers: d.bool(forKey: Prefs.showOtherUsers),
			withThreads: uiVisible,
			matcher: matcher)
		let accepted = sampler.sample(request) { [weak self] snapshot in
			self?.didSample(snapshot, state: state)
		}
		if accepted && full { lastFullScan = Date() }
		// A dropped request while the popover opened would leave a partial list; retry.
		if !accepted && uiVisible { tickSoon(0.2) }
	}

	private func didSample(_ snapshot: Snapshot, state: SystemState) {
		lastSnapshot = snapshot
		enforcer.apply(snapshot, rules: rules, state: state, frontmostPid: frontmostPid)
		onSystemCPU?(snapshot.systemCPU)
		history.record(snapshot)
		if snapshot.full && runawayEnabled { detectRunaways(snapshot) }
		let status = enforcer.limiterStatus()
		// Only publish complete lists, and only while something is on screen.
		if snapshot.full && uiVisible {
			self.snapshot = snapshot
			limiterStatus = status
		}
		writeState()
	}

	// MARK: Runaway apps

	private func detectRunaways(_ snapshot: Snapshot) {
		// Drop suggestions for apps that have quit (or now have a rule).
		let present = Set(snapshot.groups.filter { rules.rule(for: $0) == nil }.map(\.id))
		suggestions.removeAll { !present.contains($0.groupID) }
		let raised = runaway.observe(snapshot, frontmostPid: frontmostPid) { [rules] group in
			rules.rule(for: group) != nil
		}
		for s in raised {
			guard !suggestions.contains(s) else { continue }
			suggestions.removeAll { $0.groupID == s.groupID }
			suggestions.insert(s, at: 0)
			let body = L("Has used %@ CPU for %d minutes in the background.", Fmt.percent(s.averageCPU), s.minutes)
			log.add(s.name, body)
			Notifier.shared.post(title: L("%@ is using a lot of CPU", s.name), body: body, suggestion: [
				"groupID": s.groupID, "name": s.name, "bundleID": s.bundleID ?? "", "path": s.path,
			])
		}
		writeState()
	}

	func applySuggestion(_ action: Notifier.Action, info: [String: String]) {
		guard let groupID = info["groupID"], let name = info["name"] else { return }
		let bundleID = info["bundleID"].flatMap { $0.isEmpty ? nil : $0 }
		var rule = rules.rule(bundleID: bundleID, path: info["path"] ?? "", name: name)
			?? (bundleID.map { AppRule(matchKind: .bundleID, matchValue: $0, displayName: name) }
				?? AppRule(matchKind: .path, matchValue: info["path"] ?? name, displayName: name))
		switch action {
		case .limit50:
			rule.cpuLimitEnabled = true
			rule.cpuLimit = 50
			rule.enabled = true
		case .ecores:
			rule.backgroundMode = true
			rule.enabled = true
		case .ignore:
			rule.ignored = true
		}
		rules.upsert(rule)
		runaway.snooze(groupID)
		suggestions.removeAll { $0.groupID == groupID }
		log.add(name, rule.summary)
		writeState()
	}

	func dismissSuggestion(_ s: RunawaySuggestion) {
		runaway.snooze(s.groupID)
		suggestions.removeAll { $0.groupID == s.groupID }
		writeState()
	}

	// MARK: CLI commands

	private func handleCommand(_ info: [String: String]) {
		let target = info["target"] ?? ""
		switch info["command"] {
		case "pause": paused = true
		case "resume": paused = false
		case "freeze", "unfreeze":
			// Look the app up in a fresh sample so it works with the UI closed.
			let request = SampleRequest(apps: RunningApps.collect(), includeAll: true, includeOtherUsers: false, withThreads: false, matcher: GroupMatcher())
			let snap = sampler.sampleNow(request)
			let t = target.lowercased()
			guard let group = snap.groups.first(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t })
					?? enforcer.knownGroup(matching: target) else {
				log.add("AppWrangler", L("No running app named %@", target))
				return
			}
			info["command"] == "freeze" ? freeze(group) : unfreeze(group)
		default: break
		}
	}

	private var lastWrittenState: (Bool, [String], [String])?

	/// Status for the CLI; only rewritten when it changes.
	private func writeState() {
		let frozen = enforcer.frozen.keys.sorted()
		let runaway = suggestions.map(\.name)
		if let last = lastWrittenState, last.0 == paused, last.1 == frozen, last.2 == runaway { return }
		lastWrittenState = (paused, frozen, runaway)
		AppState(pid: getpid(), paused: paused, frozen: frozen, runaway: runaway, updated: Date()).write()
	}

	// MARK: Actions from UI

	func freeze(_ group: AppGroup) {
		enforcer.freeze(group)
		log.add(group.name, L("Frozen"))
		writeState()
		reschedule()
		tickSoon(0.1)
	}

	func unfreeze(_ group: AppGroup) {
		enforcer.unfreeze(group.id)
		log.add(group.name, L("Resumed"))
		writeState()
		reschedule()
		tickSoon(0.1)
	}

	func quit(_ group: AppGroup) {
		enforcer.quit(group)
		log.add(group.name, L("Quit requested"))
		tickSoon(0.5)
	}

	func forceQuit(_ group: AppGroup) {
		enforcer.forceQuit(group)
		log.add(group.name, L("Force quit"))
		tickSoon(0.3)
	}

	/// Quick limit from a context menu.
	func quickLimit(_ group: AppGroup, cpu: Double?) {
		var rule = rules.rule(for: group) ?? AppRule.forGroup(group)
		rule.enabled = true
		if let cpu {
			rule.cpuLimitEnabled = true
			rule.cpuLimit = cpu
		} else {
			rule.cpuLimitEnabled = false
		}
		rules.upsert(rule)
	}

	func toggleEfficiency(_ group: AppGroup) {
		var rule = rules.rule(for: group) ?? AppRule.forGroup(group)
		rule.enabled = true
		rule.backgroundMode.toggle()
		rules.upsert(rule)
	}

	func isFrozen(_ group: AppGroup) -> Bool { enforcer.isFrozen(group.id) }

	func shutdown() {
		enforcer.releaseAll()
		rules.saveNow()
		AppState.remove()
	}
}
