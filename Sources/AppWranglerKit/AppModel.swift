//
//  AppModel.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Owns the sampling cadence. Monitoring is adaptive:
//    • UI open                → every process, every `AWUIInterval` (1 s)
//    • UI closed, rules exist → only ruled/frozen apps, every `AWEnforceInterval` (2 s)
//    • runaway detection on   → plus a full scan every ~5 s
//    • nothing to do          → no timer at all
//  Rule edits (UI, CLI, file), app launches, focus changes and power/thermal/
//  memory-pressure changes all trigger an immediate pass — no restart needed.
//

import AppKit
import Combine
import ProcKit
import WidgetKit

final class AppModel: ObservableObject {
	static let shared = AppModel()

	let rules: RuleStore
	let log = ActivityLog()
	let enforcer: Enforcer
	let history = HistoryStore()
	let runaway = RunawayDetector()
	let system = SystemStateMonitor()
	let stats = StatsStore()
	let autoPilot = AutoPilot()
	@Published private(set) var autoSummary = AutoSummary()
	/// When each app pid was last frontmost (Auto's grace period).
	private var lastActive: [pid_t: Date] = [:]

	@Published private(set) var snapshot = Snapshot()
	@Published private(set) var limiterStatus: [String: pk_lim_status] = [:]
	@Published private(set) var suggestions: [RunawaySuggestion] = []
	/// Recommended settings shown in the panel (same engine as `appwrangler suggest`).
	@Published private(set) var advice: [Suggestion] = []
	private var lastAdvice = Date.distantPast
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
	/// Apps not used since AppWrangler started count as idle since then.
	private let launchedAt = Date()
	private var lastUsageWrite = Date.distantPast
	private var lastWidgetWrite = Date.distantPast
	private var lastWidgetReload = Date.distantPast
	private var lastWidgetKey = ""
	private var lastWidgetPressure = ""
	private var runningAppsObservation: NSKeyValueObservation?

	init(rules: RuleStore = RuleStore(defaults: Migration.legacyDefaults), controller: ProcessController = LiveProcessController()) {
		self.rules = rules
		self.enforcer = Enforcer(controller: controller)
		enforcer.onEvent = { [weak self] app, message, notify in self?.log.add(app, message, notify: notify) }
		enforcer.onImpact = { [weak self] group, event in
			self?.stats.record(event, key: ImpactKey.of(group), name: group.name)
		}
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
			if self.frontmostPid > 0 { self.lastActive[self.frontmostPid] = Date() }
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
			let info = note.userInfo as? [String: String] ?? [:]
			guard IPC.isForThisInstance(info) else { return }
			self?.handleCommand(info)
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
		scheduleStatsFlush()
		tick()
	}

	// MARK: Impact statistics

	private var lastStatsTime: Date?
	private var lastSelfCPU: (ns: UInt64, at: UInt64)?

	/// Credit this interval's savings: throttled, frozen and E-core apps, plus our own cost.
	private func recordImpact(_ snapshot: Snapshot, status: [String: pk_lim_status], state: SystemState) {
		let now = Date()
		defer { lastStatsTime = now }
		// Our own CPU since the last call (always advance the baseline, even
		// across a gap, so the next interval isn't averaged over the gap).
		var usage = pk_proc_usage()
		var selfCPU = 0.0
		var footprint: UInt64 = 0
		if pk_proc_usage_get(getpid(), 0, &usage) == 0 {
			footprint = usage.footprint
			let t = pk_now_ns()
			if let prev = lastSelfCPU, t > prev.at {
				selfCPU = Double(usage.cpu_ns &- prev.ns) / Double(t - prev.at)
			}
			lastSelfCPU = (usage.cpu_ns, t)
		}
		guard let last = lastStatsTime else { return }
		let dt = now.timeIntervalSince(last)
		// A long gap means the Mac slept or we stalled: don't credit it.
		guard dt > 0, dt <= max(10, (timerInterval ?? 2) * 3) else { return }

		var ticks: [ImpactTick] = []
		for group in snapshot.groups {
			let frozen = enforcer.isFrozen(group.id)
			let efficiency = enforcer.isInBackgroundMode(group)
			var throttle: (Double, Double, Double)?
			if !frozen, !paused, let st = status[group.id], let limit = enforcer.effectiveLimit[group.id] {
				throttle = (st.usage_cores, st.demand_cores, limit)
			}
			guard throttle != nil || frozen || efficiency else { continue }
			var tick = ImpactTick(key: ImpactKey.of(group), name: group.name)
			tick.throttle = throttle
			// Credit a freeze with the app's earlier usage only for its first hour —
			// beyond that we can't assume it would still have been busy.
			if frozen {
				let age = enforcer.frozenSince[group.id].map { now.timeIntervalSince($0) } ?? 0
				tick.frozenDemand = age < 3600 ? (enforcer.frozenDemand[group.id] ?? 0) : 0
			}
			tick.efficiency = efficiency
			tick.cpu = group.cpu
			tick.power = group.power
			ticks.append(tick)
		}

		stats.record(ticks, selfCPU: selfCPU, selfFootprint: footprint, dt: dt, at: now)
	}

	private func scheduleStatsFlush() {
		let seconds = max(1, UserDefaults.standard.double(forKey: Prefs.statsFlushSeconds))
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
			self?.stats.flush()
			self?.scheduleStatsFlush()
		}
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
		autoPilot.settings = Prefs.autoSettings
		reschedule()
	}

	private var runawayEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.runawayEnabled) }

	private var needsBackgroundSampling: Bool {
		rules.rules.contains { $0.isActive } || !enforcer.frozen.isEmpty || runawayEnabled || autoPilot.settings.enabled
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
		let auto = decideAuto(lastSnapshot, state: state, newSample: false)
		enforcer.apply(lastSnapshot, rules: rules, state: state, frontmostPid: frontmostPid, auto: auto, audioPids: audioPids,
					   autoFreeze: autoFreezeCandidates(lastSnapshot, state: state), autoFreezeActive: autoFreezeActive)
		writeState()
	}

	private var autoFreezeActive: Bool { autoPilot.settings.enabled && autoPilot.settings.freezeIdleWhenLowMemory }

	/// Opt-in Auto memory: while the Mac is low on memory, apps you haven't used
	/// for a while may be frozen (they resume when you switch to them).
	private func autoFreezeCandidates(_ snapshot: Snapshot, state: SystemState) -> Set<String> {
		let s = autoPilot.settings
		guard s.enabled, s.freezeIdleWhenLowMemory, state.memoryPressure >= enforcer.pressureThreshold else { return [] }
		let groups = autoEligible(snapshot).filter { g in
			(rules.rule(for: g)?.pressureAction ?? PressureAction.none) == PressureAction.none	// the app's own rule decides otherwise
		}
		return Set(AutoPilot.idleFreezeCandidates(groups, frontmostPid: frontmostPid, lastActive: lastActive,
												  audioPids: audioPids, idleAfter: s.freezeIdleAfter, since: launchedAt))
	}

	/// Processes playing or recording audio (macOS 14.2+). Only queried when
	/// something uses it: Auto mode or a low-memory rule.
	private var audioPids: Set<pid_t> = []

	private func refreshAudio() {
		let needed = autoPilot.settings.enabled || rules.rules.contains { $0.enabled && $0.pressureAction != .none }
		audioPids = needed ? AudioActivity.activePids() : []
	}

	/// Apps Auto may manage: real apps without their own CPU / E-core rule,
	/// not ignored, not protected, not frozen.
	private func autoEligible(_ snapshot: Snapshot) -> [AppGroup] {
		let me = getpid()
		// Test-only: `-AWAutoScope <bundle-id prefix>` keeps a test copy's Auto
		// mode away from the user's real apps.
		let scope = UserDefaults.standard.string(forKey: "AWAutoScope")
		return snapshot.groups.filter { g in
			guard g.kind == .app || g.kind == .background, g.ownerPid != me, !Protected.contains(g),
				  !enforcer.isFrozen(g.id) else { return false }
			if let scope, !(g.bundleID ?? "").hasPrefix(scope) { return false }
			guard let rule = rules.rule(for: g) else { return true }
			return !rule.ignored && !(rule.enabled && (rule.cpuLimitEnabled || rule.backgroundMode))
		}
	}

	private func decideAuto(_ snapshot: Snapshot, state: SystemState, newSample: Bool) -> [String: AutoDecision] {
		guard autoPilot.settings.enabled else {
			autoPilot.reset()
			if autoSummary != AutoSummary() { autoSummary = AutoSummary() }
			return [:]
		}
		guard newSample else {
			// Focus changed: recompute who's in use without counting a new load sample.
			return autoPilot.refocus(frontmostPid: frontmostPid, lastActive: lastActive)
		}
		let demand = enforcer.limiterStatus().mapValues(\.demand_cores)
		let decisions = autoPilot.decide(groups: autoEligible(snapshot), frontmostPid: frontmostPid, lastActive: lastActive,
										 audioPids: audioPids, systemCPU: snapshot.systemCPU,
										 onBattery: state.onBattery, ncpu: SystemInfo.ncpu, demand: demand)
		if autoPilot.summary != autoSummary { autoSummary = autoPilot.summary }
		// Forget focus times of apps that have quit.
		if lastActive.count > 200 { lastActive = lastActive.filter { kill($0.key, 0) == 0 } }
		return decisions
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
			includeApps: autoPilot.settings.enabled,
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
		refreshAudio()
		let auto = decideAuto(snapshot, state: state, newSample: true)
		enforcer.apply(snapshot, rules: rules, state: state, frontmostPid: frontmostPid, auto: auto, audioPids: audioPids,
					   autoFreeze: autoFreezeCandidates(snapshot, state: state), autoFreezeActive: autoFreezeActive)
		onSystemCPU?(snapshot.systemCPU)
		history.record(snapshot)
		if Date().timeIntervalSince(lastWidgetWrite) >= 60 { updateWidget() }
		if Date().timeIntervalSince(lastUsageWrite) >= 60 {
			lastUsageWrite = Date()
			UsageAverages(updated: Date(), apps: UsageAverages.compute(groups: snapshot.groups, history: history))
				.write(directory: rules.fileURL.deletingLastPathComponent())
		}
		if snapshot.full && runawayEnabled { detectRunaways(snapshot) }
		let status = enforcer.limiterStatus()
		recordImpact(snapshot, status: status, state: state)
		// Only publish complete lists, and only while something is on screen.
		if snapshot.full && uiVisible {
			self.snapshot = snapshot
			limiterStatus = status
			if Date().timeIntervalSince(lastAdvice) >= 30 { refreshAdvice() }
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
			stats.record(.runawayAlert, key: "bundle:" + (s.bundleID ?? s.path), name: s.name)
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
		let before = rules.rules.first { $0.id == rule.id }
		rules.upsert(rule)
		ChangeJournal.record(before: before, after: rules.rules.first { $0.id == rule.id }, source: "alert", store: rules)
		runaway.snooze(groupID)
		suggestions.removeAll { $0.groupID == groupID }
		log.add(name, rule.summary)
		writeState()
	}

	// MARK: Suggestions (advice)

	func refreshAdvice() {
		lastAdvice = Date()
		guard lastSnapshot.full else { return }
		advice = computeAdvice()
	}

	private func computeAdvice() -> [Suggestion] {
		var mem = pk_memory_stats()
		pk_memory_stats_get(&mem)
		let week = stats.summary(days: 7)
		let d = UserDefaults.standard
		let input = SuggestionInput(
			groups: lastSnapshot.groups, rules: rules.rules, autoEnabled: autoPilot.settings.enabled,
			frontmostPid: frontmostPid, memoryBytes: SystemInfo.info.memsize, memoryUsedBytes: mem.used,
			memoryPressure: systemState.memoryPressure, swapUsedBytes: Swap.usedBytes, onBattery: systemState.onBattery,
			ncpu: SystemInfo.ncpu, week: week.uptimeSeconds > 0 ? week : nil,
			averages: UsageAverages.compute(groups: lastSnapshot.groups, history: history),
			autoFreezeIdle: d.bool(forKey: Prefs.autoFreezeIdle))
		let dismissed = d.dictionary(forKey: Prefs.dismissedAdvice) as? [String: Date] ?? [:]
		return Suggestions.make(input).filter { s in
			guard let when = dismissed[s.id] else { return true }
			return Date().timeIntervalSince(when) > 7 * 86_400
		}
	}

	// MARK: Widget

	/// Write what the desktop widget shows, and ask WidgetKit to refresh it —
	/// at once when something you'd notice changed (paused, frozen, Auto), and
	/// otherwise every few minutes, which keeps within WidgetKit's budget.
	func updateWidget() {
		lastWidgetWrite = Date()
		var mem = pk_memory_stats()
		pk_memory_stats_get(&mem)
		let today = stats.summary(days: 1)
		let s = autoSummary
		let suggestions = computeAdvice()
		let top = lastSnapshot.groups.filter { $0.kind == .app || $0.kind == .background }.sorted { $0.cpu > $1.cpu }.prefix(5)
		let snapshot = WidgetSnapshot(
			updated: Date(), chip: SystemInfo.chip, cores: SystemInfo.ncpu, cpu: lastSnapshot.systemCPU,
			memoryUsedBytes: mem.used, memoryTotalBytes: SystemInfo.info.memsize, memoryPressure: Int(mem.pressure_level),
			swapUsedBytes: Swap.usedBytes, paused: paused, autoOn: autoPilot.settings.enabled, autoManaged: s.managed,
			autoOnEfficiency: s.onEfficiency, autoCapped: s.capped, frozen: enforcer.frozen.keys.compactMap { id in
				lastSnapshot.groups.first { $0.id == id }?.name ?? enforcer.knownGroup(matching: id)?.name
			}.sorted(),
			savedCPUSecondsToday: today.total.savedCPUSeconds, savedEnergyWhToday: today.total.totalSavedEnergyJ / 3600,
			topApps: top.map { g in
				let state: String
				if enforcer.isFrozen(g.id) { state = "frozen" }
				else if let r = rules.rule(for: g), r.enabled, r.cpuLimitEnabled || r.backgroundMode { state = "rule" }
				else if let d = enforcer.autoDecisions[g.id] { state = d.efficiency ? "auto-ecores" : "auto-full" }
				else { state = "" }
				return WidgetSnapshot.App(name: g.name, cpu: g.cpu, memoryBytes: g.footprint, state: state)
			},
			suggestionCount: suggestions.count, topSuggestion: suggestions.first?.title,
			suggestionTitles: suggestions.prefix(3).map(\.title))
		snapshot.write(directory: rules.fileURL.deletingLastPathComponent())
		// The widget reads the real data folder; a copy on another folder (tests,
		// APPWRANGLER_DATA_DIR) must not make it redraw.
		guard !DataDirectory.isOverridden else { return }
		// Things you did (pause, freeze, Auto) show at once; memory pressure at most
		// once a minute; otherwise every 5 minutes — well within WidgetKit's budget.
		let userKey = "\(paused)|\(snapshot.frozen)|\(snapshot.autoOn)"
		let pressureKey = "\(snapshot.memoryPressure)"
		let since = Date().timeIntervalSince(lastWidgetReload)
		if userKey != lastWidgetKey || (pressureKey != lastWidgetPressure && since >= 60) || since >= 300 {
			lastWidgetKey = userKey
			lastWidgetPressure = pressureKey
			lastWidgetReload = Date()
			WidgetCenter.shared.reloadAllTimelines()
		}
	}

	/// Hide a suggestion for a week.
	func dismissAdvice(_ s: Suggestion) {
		var dismissed = UserDefaults.standard.dictionary(forKey: Prefs.dismissedAdvice) as? [String: Date] ?? [:]
		dismissed = dismissed.filter { Date().timeIntervalSince($0.value) < 7 * 86_400 }
		dismissed[s.id] = Date()
		UserDefaults.standard.set(dismissed, forKey: Prefs.dismissedAdvice)
		advice.removeAll { $0.id == s.id }
	}

	/// Apply one of a suggestion's actions, exactly as the CLI / MCP would.
	func applyAdvice(_ s: Suggestion, _ action: Suggestion.Action) {
		let d = UserDefaults.standard
		switch action.tool {
		case "configure_app":
			let target = action.arguments["app"] as? String ?? ""
			guard let changes = try? RuleChanges.parse(action.arguments) else { return }
			switch AppSettings.configure(target, changes: changes, store: rules, apps: Array(apps.values), source: "suggestion") {
			case .saved(let rule, _): log.add(rule.displayName, rule.summary)
			case .removed(let rule): log.add(rule.displayName, L("Rule removed"))
			case .failed(let message): log.add(target, message)
			}
		case "set_auto_mode":
			if let on = action.arguments["enabled"] as? Bool { d.set(on, forKey: Prefs.autoEnabled) }
			if let on = action.arguments["freeze_idle_apps"] as? Bool { d.set(on, forKey: Prefs.autoFreezeIdle) }
			preferencesChanged()
			reapply()
		case "remove_rule":
			let name = (action.arguments["app"] as? String ?? "").lowercased()
			// By what the rule matches (a stale path), never by display name: a live rule may share it.
			if let rule = rules.rules.first(where: { $0.matchValue.lowercased() == name })
				?? rules.rules.first(where: { $0.displayName.lowercased() == name }) {
				rules.remove(id: rule.id)
				rules.saveNow()
				ChangeJournal.record(before: rule, after: nil, source: "suggestion", store: rules)
				log.add(rule.displayName, L("Rule removed"))
			}
		default:
			return
		}
		advice.removeAll { $0.id == s.id }
		lastAdvice = .distantPast	// recompute on the next sample
		tickSoon(0.3)
	}

	func dismissSuggestion(_ s: RunawaySuggestion) {
		runaway.snooze(s.groupID)
		suggestions.removeAll { $0.groupID == s.groupID }
		writeState()
	}

	// MARK: CLI commands

	/// "Free memory now" (widget, CLI, MCP): freeze regular apps you haven't used
	/// for the idle time set for Auto mode (10 min by default), whatever the
	/// memory pressure. Same exclusions as Auto's idle freezing; each app
	/// resumes the moment you switch to it. Returns the apps frozen.
	@discardableResult
	func freeMemoryNow() -> [String] {
		// Measure apps now: with Auto off and the UI closed they may not be sampled.
		let snap = sampler.sampleNow(SampleRequest(apps: RunningApps.collect(), includeAll: false, includeApps: true,
												   includeOtherUsers: false, withThreads: false, matcher: GroupMatcher()))
		// A single fresh sample has no CPU rates; use what we measured recently.
		let groups = autoEligible(snap).filter { (rules.rule(for: $0)?.pressureAction ?? PressureAction.none) == PressureAction.none }
			.map { g -> AppGroup in
				var g = g
				let points = history.points(for: g.id).suffix(30)
				g.cpu = points.isEmpty ? (lastSnapshot.groups.first { $0.id == g.id }?.cpu ?? 0)
					: points.map(\.cpu).reduce(0, +) / Double(points.count)
				return g
			}
		// Check audio now: it's only tracked continuously while Auto mode is on.
		let audio = AudioActivity.activePids()
		let ids = Set(AutoPilot.idleFreezeCandidates(groups, frontmostPid: frontmostPid, lastActive: lastActive, audioPids: audio,
													 idleAfter: autoPilot.settings.freezeIdleAfter, since: launchedAt))
		let chosen = snap.groups.filter { ids.contains($0.id) }
		for g in chosen {
			enforcer.freeze(g, reason: .idle)
			stats.record(.lowMemoryAction, key: ImpactKey.of(g), name: g.name)
		}
		log.add("AppWrangler", chosen.isEmpty ? L("Free memory: no idle apps to freeze")
				: L("Free memory: froze %@ — each resumes when you switch to it", chosen.map(\.name).joined(separator: ", ")))
		writeState()
		reschedule()
		tickSoon(0.1)
		return chosen.map(\.name)
	}

	private func handleCommand(_ info: [String: String]) {
		let target = info["target"] ?? ""
		switch info["command"] {
		case "free-memory": freeMemoryNow()
		case "prefs":
			preferencesChanged()
			reapply()
			tickSoon(0.1)
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

	private var lastWrittenState: (Bool, [String], [String], String, [String: String])?

	/// App name → what Auto is doing to it.
	var autoAppStates: [String: String] {
		var out: [String: String] = [:]
		for g in lastSnapshot.groups {
			if let d = enforcer.autoDecisions[g.id] { out[g.name] = d.label }
		}
		return out
	}

	var autoDescription: String {
		guard autoPilot.settings.enabled else { return "off" }
		let s = autoSummary
		return "on — \(s.managed) apps: \(s.inUse) in use, \(s.onEfficiency) on efficiency cores, \(s.capped) capped" + (s.busy ? " (Mac busy)" : "")
	}

	/// Status for the CLI; only rewritten when it changes.
	private func writeState() {
		let frozen = enforcer.frozen.keys.sorted()
		let runaway = suggestions.map(\.name)
		let auto = autoDescription
		let apps = autoAppStates
		if let last = lastWrittenState, last.0 == paused, last.1 == frozen, last.2 == runaway, last.3 == auto, last.4 == apps { return }
		let pausedOrFrozenChanged = lastWrittenState.map { $0.0 != paused || $0.1 != frozen } ?? false
		lastWrittenState = (paused, frozen, runaway, auto, apps)
		AppState(pid: getpid(), paused: paused, frozen: frozen, runaway: runaway, auto: auto, autoApps: apps, updated: Date()).write()
		if pausedOrFrozenChanged { updateWidget() }
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
		let before = rules.rule(for: group)
		defer { ChangeJournal.record(before: before, after: rules.rule(for: group), source: "panel", store: rules) }
		var rule = before ?? AppRule.forGroup(group)
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
		let before = rules.rule(for: group)
		defer { ChangeJournal.record(before: before, after: rules.rule(for: group), source: "panel", store: rules) }
		var rule = before ?? AppRule.forGroup(group)
		rule.enabled = true
		rule.backgroundMode.toggle()
		rules.upsert(rule)
	}

	func isFrozen(_ group: AppGroup) -> Bool { enforcer.isFrozen(group.id) }

	func shutdown() {
		stats.flush()
		enforcer.releaseAll()
		rules.saveNow()
		AppState.remove()
	}
}
