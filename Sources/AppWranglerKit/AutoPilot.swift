//
//  AutoPilot.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Auto mode: keep every app usable when you're using it, and efficient when
//  you're not — without per-app rules.
//
//    • The focused app (and one you left a moment ago) runs at full speed.
//    • Apps playing or recording audio count as in use (music, calls, dictation).
//    • Other apps move to the efficiency cores after a grace period, and come
//      straight back to full speed when you switch to them.
//    • Only when the Mac is actually busy are background apps capped: the CPU
//      the foreground isn't using is shared fairly between them (max-min
//      fairness), with a floor so none of them starves. When the Mac isn't
//      busy, nothing is capped at all.
//    • Command-line processes that run hot are moved to the efficiency cores too, but
//      only while the Mac needs its resources (busy, on battery, hot): never capped or
//      frozen, never build tools, system processes or what a terminal is waiting for.
//    • You're away (no input for a few minutes, plugged in): nothing is held back, so
//      background work finishes at full speed. It's all restored the moment you're back.
//    • Learned routine: apps you usually use around now stay at full speed longer.
//    • Adaptive (on by default): Auto follows what the Mac needs right now. When
//      you're plugged in, the Mac is calm and cool, a background app that is
//      doing real work runs free instead of being held on the efficiency cores,
//      so it finishes sooner; it goes back when the Mac gets busy or the app
//      goes quiet. On battery, in Low Power Mode or when hot, apps move to the
//      efficiency cores sooner.
//
//  Apps with their own rule, ignored apps, plain processes and macOS services
//  are left to the user's rules.
//

import Foundation

enum AppTraits {
	/// Apps where freezing means missed messages or calls.
	static let messagingHints = ["slack", "whatsapp", "teams", "zoom", "discord", "telegram", "signal", "messages", "mail",
								 "outlook", "skype", "facetime", "webex", "mattermost", "element", "wechat", "viber"]

	/// Apps that do work for you while you're elsewhere: freezing them would stop
	/// builds, dev servers, terminals' jobs or virtual machines.
	static let keepRunningHints = ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper",
								   "xcode", "vscode", "visual studio code", "cursor", "zed", "jetbrains", "intellij", "pycharm",
								   "webstorm", "goland", "android studio", "docker", "orbstack", "utm", "parallels", "vmware",
								   "virtualbox", "multipass", "podman", "rancher"]

	/// Compilers and build tools: busy because you're waiting for them, so
	/// slowing them down (efficiency cores, a CPU cap) only makes you wait longer.
	static let buildTools: Set<String> = ["swift-frontend", "swiftc", "swift-build", "swift-driver", "clang", "clang++", "cc1", "cc1plus",
										  "ld", "ld64", "lld", "rustc", "cargo", "go", "javac", "kotlinc", "gradle", "java", "make",
										  "ninja", "cmake", "xcodebuild", "ibtool", "actool", "node-gyp", "esbuild", "tsc", "webpack"]

	static func isBuildTool(_ name: String) -> Bool { buildTools.contains(name.lowercased()) }

	/// Never frozen just for being idle.
	static func neverIdleFreeze(name: String, bundleID: String?) -> Bool {
		if isMessaging(name: name, bundleID: bundleID) { return true }
		let n = (name + " " + (bundleID ?? "")).lowercased()
		return keepRunningHints.contains { n.range(of: "\\b" + $0, options: .regularExpression) != nil }
	}

	static func isMessaging(name: String, bundleID: String?) -> Bool {
		let n = (name + " " + (bundleID ?? "")).lowercased()
		return messagingHints.contains { hint in
			n.range(of: "\\b" + hint, options: .regularExpression) != nil
		}
	}
}

struct AutoSettings: Equatable {
	var enabled = true
	/// Seconds in the background before an app moves to the efficiency cores.
	var efficiencyAfter: TimeInterval = 30
	var useEfficiencyCores = true
	var shareCPU = true
	/// Whole-Mac CPU use (0…1) above which background apps get capped.
	var busyThreshold = 0.75
	/// Lower threshold on battery so apps can't drain it while the Mac is busy.
	var busyThresholdOnBattery = 0.5
	/// Seconds after you switch away during which an app still counts as in use.
	var focusGrace: TimeInterval = 15
	/// Cores always kept free for the foreground.
	var headroomCores = 1.0
	/// No background app is capped below this many cores.
	var floorCores = 0.15
	/// Opt-in: when the Mac is low on memory, freeze regular apps you haven't
	/// used for `freezeIdleAfter` seconds. They resume when you switch to them.
	var freezeIdleWhenLowMemory = false
	var freezeIdleAfter: TimeInterval = 600

	/// Also manage command-line processes (hot ones, and only while the Mac needs its resources).
	var processes = true
	/// A process counts as hot above this many cores…
	var processCPU = 0.15
	/// …for this long before it's moved to the efficiency cores.
	var processHotFor: TimeInterval = 20
	/// When you're away (no input for `awayAfter`, plugged in, cool), nothing is held back.
	var away = true
	var awayAfter: TimeInterval = 300
	/// Learn which apps you use when, and keep the ones you usually use now at full speed longer.
	var learn = true
	/// An app you usually use around now stays at full speed this long after you leave it.
	var likelyGrace: TimeInterval = 300
	/// Pause low priority work (updaters, indexing, anything you marked Low) while the Mac needs
	/// its resources for what you're doing; see Priority.swift.
	var shed = true
	/// Follow what the Mac needs right now instead of fixed timings: run working
	/// background apps free when there's room, tighten when strained, and act on
	/// memory early and gently.
	var adaptive = true
	/// A background app using at least this many cores for `liftAfter` seconds…
	var liftCPU = 0.3
	var liftAfter: TimeInterval = 10
	/// …runs free, and goes back to the efficiency cores after `liftQuietFor`
	/// seconds below `liftQuietCPU` cores.
	var liftQuietCPU = 0.1
	var liftQuietFor: TimeInterval = 30
	/// Nothing runs free for this long after the Mac was busy.
	var liftCooldown: TimeInterval = 120
	/// On battery, in Low Power Mode or when hot, apps move to the efficiency cores after this.
	var strainedEfficiencyAfter: TimeInterval = 10
}

struct AutoDecision: Equatable {
	enum Reason: String { case foreground, audio, recent, background, priority, room }

	/// Plain-language state, for status output.
	var label: String {
		switch reason {
		case .foreground: return "in use — full speed"
		case .audio: return "playing or recording audio — full speed"
		case .priority:
			if let cap { return String(format: "prioritized — sharing %.0f%% while the Mac is saturated", cap * 100) }
			return "prioritized — full speed"
		case .room: return "making room for it — full speed, everything else steps back"
		case .recent: return "just used — full speed for a few seconds"
		case .background:
			if away { return "background — running free while you're away" }
			if lifted { return "background — running free: it's working and the Mac has room" }
			if let cap { return String(format: "background — efficiency cores, shared CPU %.0f%% (Mac busy)", cap * 100) }
			return efficiency ? "background — efficiency cores" : "background — moves to efficiency cores shortly"
		}
	}
	var reason: Reason
	var efficiency = false
	/// CPU cap in cores, when the Mac is busy.
	var cap: Double?
	/// A background app doing real work while the Mac has room: not held on the efficiency cores.
	var lifted = false
	/// Running free because you're away.
	var away = false
}

struct AutoSummary: Equatable {
	var managed = 0
	var inUse = 0
	var onEfficiency = 0
	var capped = 0
	/// Background apps running free because they're working and the Mac has room.
	var runningFree = 0
	/// Command-line processes held on the efficiency cores because the Mac needs its resources.
	var processes = 0
	/// You're away: nothing is held back.
	var away = false
	var busy = false
}

final class AutoPilot {
	var settings = AutoSettings()
	private(set) var busy = false
	private var busyStreak = 0
	private var calmStreak = 0
	private var lastLoadSample: Date?
	/// The last time the Mac was busy (nothing runs free for a while afterwards).
	private var lastBusy: Date?
	private var backgroundSince: [String: Date] = [:]
	private var workingSince: [String: Date] = [:]
	private var quietSince: [String: Date] = [:]
	private var runningFree: Set<String> = []
	/// Processes that have been hot (since when), and those currently held.
	private var hotSince: [String: Date] = [:]
	private var heldProcesses: Set<String> = []
	/// Hot processes Auto is following, so the app keeps measuring them between full scans.
	var watchedProcessIDs: Set<String> { Set(hotSince.keys) }
	private(set) var decisions: [String: AutoDecision] = [:]
	private var owners: [String: pid_t] = [:]
	/// Every pid of each managed app, so switching to any of its windows counts.
	private var groupPids: [String: Set<pid_t>] = [:]
	private(set) var summary = AutoSummary()

	/// - Parameters:
	///   - groups: apps eligible for Auto (caller excludes rules, ignored, protected, processes).
	///   - foregroundPids: the frontmost app's pid.
	///   - lastActive: when each app pid was last frontmost (for the grace period).
	///   - audioPids: processes playing or recording audio.
	///   - systemCPU: whole-Mac CPU use, 0…1.
	///   - demand: estimated demand per group id while capped (otherwise measured usage is used).
	@discardableResult
	func decide(groups: [AppGroup], frontmostPid: pid_t, lastActive: [pid_t: Date], audioPids: Set<pid_t>,
				systemCPU: Double, onBattery: Bool, ncpu: Int, lowPower: Bool = false, hot: Bool = false,
				demand: [String: Double] = [:], priorities: [String: AppPriority] = [:], away: Bool = false,
				likely: Set<String> = [], roomFor: String? = nil, now: Date = Date()) -> [String: AutoDecision] {
		guard settings.enabled else {
			reset()
			return [:]
		}

		// Busy with hysteresis: two samples over the threshold to start, two
		// clearly under it (threshold − 15 points) to stop.
		// Only samples at least ~1 s apart count, so extra quick samples (after a
		// launch or a setting change) can't flip the state on a tiny window.
		// Making room for an app: the Mac counts as busy sooner, so the rest steps back sooner.
		let making = roomFor.map { id in groups.contains { $0.id == id } } ?? false
		let threshold = (onBattery ? settings.busyThresholdOnBattery : settings.busyThreshold) - (making ? 0.15 : 0)
		if lastLoadSample.map({ now.timeIntervalSince($0) >= 0.9 }) ?? true {
			lastLoadSample = now
			busyStreak = systemCPU >= threshold ? busyStreak + 1 : 0
			calmStreak = systemCPU < threshold - 0.15 ? calmStreak + 1 : 0
			if !busy && busyStreak >= 2 { busy = true }
			if busy && calmStreak >= 2 { busy = false }
		}
		if busy { lastBusy = now }

		// What the Mac needs right now. Strained (battery, Low Power Mode, hot): hold background
		// apps sooner. Room to spare (plugged in, calm, cool, not just busy): let working apps run free.
		let strained = settings.adaptive && (onBattery || lowPower || hot)
		// Making room: everything else goes to the efficiency cores at once and never runs free.
		let grace = making ? 0 : strained ? min(settings.efficiencyAfter, settings.strainedEfficiencyAfter) : settings.efficiencyAfter
		let roomToRunFree = !making && settings.adaptive && !strained && !busy && systemCPU < threshold - 0.15
			&& lastBusy.map { now.timeIntervalSince($0) >= settings.liftCooldown } ?? true

		var result: [String: AutoDecision] = [:]
		var background: [AppGroup] = []
		var processIDs = Set<String>()
		var present = Set<String>()
		owners = [:]
		groupPids = [:]
		for g in groups {
			present.insert(g.id)
			owners[g.id] = g.ownerPid
			groupPids[g.id] = Set(g.pids)
			if g.kind == .process {
				// Only while the Mac needs its resources, and never anything but the efficiency cores.
				if let d = processDecision(g, needsResources: making || (!away && (busy || strained)), now: now) {
					result[g.id] = d
					processIDs.insert(g.id)
				}
				continue
			}
			let reason: AutoDecision.Reason
			if g.pids.contains(frontmostPid) {
				reason = .foreground
			} else if g.id == roomFor {
				reason = .room
			} else if priorities[g.id] == .high {
				reason = .priority
			} else if g.pids.contains(where: audioPids.contains) {
				reason = .audio
			} else if let t = g.pids.compactMap({ lastActive[$0] }).max(), now.timeIntervalSince(t) < settings.focusGrace {
				reason = .recent
			} else {
				reason = .background
			}
			if reason != .background {
				backgroundSince[g.id] = nil
				forgetFree(g.id)
				result[g.id] = AutoDecision(reason: reason)
				continue
			}
			// The background clock starts when you left the app (not when the grace
			// period ended), so E-cores kick in `efficiencyAfter` after leaving it.
			let since = backgroundSince[g.id] ?? g.pids.compactMap({ lastActive[$0] }).max() ?? now
			backgroundSince[g.id] = since
			var d = AutoDecision(reason: .background)
			if away && !making {
				// You're not here: nothing is held back, so background work finishes at full speed.
				d.lifted = true
				d.away = true
				result[g.id] = d
				forgetFree(g.id)
				continue
			}
			let low = priorities[g.id] == .low
			// An app you usually use around now stays at full speed a while longer (unless the Mac is strained).
			let appGrace = !strained && !making && likely.contains(g.id) ? max(grace, settings.likelyGrace) : grace
			// Low priority work goes to the efficiency cores at once; it never runs free.
			d.efficiency = settings.useEfficiencyCores && (low || now.timeIntervalSince(since) >= appGrace)
			if d.efficiency && !low && shouldRunFree(g, roomToRunFree: roomToRunFree, now: now) {
				d.efficiency = false
				d.lifted = true
			}
			result[g.id] = d
			background.append(g)
		}
		for id in backgroundSince.keys where !present.contains(id) { backgroundSince[id] = nil }
		for id in Set(workingSince.keys).union(quietSince.keys).union(runningFree) where !present.contains(id) { forgetFree(id) }
		for id in Set(hotSince.keys).union(heldProcesses) where !present.contains(id) {
			hotSince[id] = nil
			heldProcesses.remove(id)
		}

		// Fair share of what the foreground and everything else leave free.
		if busy && (!away || making) && settings.shareCPU && !background.isEmpty {
			let backgroundUsage = background.reduce(0) { $0 + $1.cpu }
			let othersUsage = max(0, systemCPU * Double(ncpu) - backgroundUsage)
			let minimumBudget = max(Double(ncpu) * (making ? 0.15 : 0.25), settings.floorCores * Double(background.count))
			// Making room: one more core is kept free for the app you're making room for.
			let budget = max(minimumBudget, Double(ncpu) - othersUsage - settings.headroomCores - (making ? 1 : 0))
			let wants = background.map { (id: $0.id, want: max(demand[$0.id] ?? $0.cpu, $0.cpu)) }
			for (id, cap) in Self.fairShare(wants, budget: budget, floor: settings.floorCores) {
				result[id]?.cap = cap
			}
		}

		// Prioritized apps run free, but not past the point where the Mac stalls: if the Mac is busy and
		// together they'd take more than all but one core, they share what's left of it.
		if busy {
			let prioritized = groups.filter { result[$0.id]?.reason == .priority }
			let room = Double(ncpu) - settings.headroomCores
			if prioritized.reduce(0, { $0 + $1.cpu }) > room {
				let wants = prioritized.map { (id: $0.id, want: max(demand[$0.id] ?? $0.cpu, $0.cpu)) }
				for (id, cap) in Self.fairShare(wants, budget: room, floor: 0.5) { result[id]?.cap = cap }
			}
		}

		decisions = result
		summary = AutoSummary(managed: result.count - processIDs.count,
							  inUse: result.values.filter { $0.reason != .background }.count,
							  onEfficiency: result.values.filter(\.efficiency).count,
							  capped: result.values.filter { $0.cap != nil }.count,
							  runningFree: result.values.filter(\.lifted).count,
							  processes: result.filter { processIDs.contains($0.key) && $0.value.efficiency }.count,
							  away: away && !groups.isEmpty,
							  busy: busy)
		return result
	}

	/// A hot command-line process while the Mac needs its resources goes to the efficiency cores;
	/// otherwise it's left alone (and an idle one isn't listed at all).
	private func processDecision(_ g: AppGroup, needsResources: Bool, now: Date) -> AutoDecision? {
		let hot = g.cpu >= settings.processCPU
		if hot {
			hotSince[g.id] = hotSince[g.id] ?? now
		} else if !(heldProcesses.contains(g.id) && needsResources) {
			hotSince[g.id] = nil	// a quiet process, unless it's quiet because it's being held
		}
		guard let since = hotSince[g.id], settings.processes else {
			heldProcesses.remove(g.id)
			return nil
		}
		let engage = settings.useEfficiencyCores && needsResources && now.timeIntervalSince(since) >= settings.processHotFor
		if engage { heldProcesses.insert(g.id) } else { heldProcesses.remove(g.id) }
		var d = AutoDecision(reason: .background)
		d.efficiency = engage
		return d
	}

	/// Command-line processes Auto may manage: yours, not build tools, dev tools or system software.
	static func processEligible(_ g: AppGroup) -> Bool {
		guard g.kind == .process, !Protected.contains(g), !AppTraits.isBuildTool(g.name),
			  !AppTraits.neverIdleFreeze(name: g.name, bundleID: g.bundleID) else { return false }
		let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/"]
		if system.contains(where: { g.path.hasPrefix($0) }) { return false }
		return ProcessCatalog.describe(g).safety == .safe
	}

	private func forgetFree(_ id: String) {
		workingSince[id] = nil
		quietSince[id] = nil
		runningFree.remove(id)
	}

	/// Whether a background app that would be held on the efficiency cores should run free instead:
	/// it has been doing real work for a few seconds and the Mac has room. It stays free until the
	/// Mac stops having room, or the app has been quiet for a while.
	private func shouldRunFree(_ g: AppGroup, roomToRunFree: Bool, now: Date) -> Bool {
		guard roomToRunFree else {
			forgetFree(g.id)
			return false
		}
		if runningFree.contains(g.id) {
			if g.cpu < settings.liftQuietCPU {
				let since = quietSince[g.id] ?? now
				quietSince[g.id] = since
				if now.timeIntervalSince(since) >= settings.liftQuietFor {
					forgetFree(g.id)
					return false
				}
			} else {
				quietSince[g.id] = nil
			}
			return true
		}
		guard g.cpu >= settings.liftCPU else {
			workingSince[g.id] = nil
			return false
		}
		let since = workingSince[g.id] ?? now
		workingSince[g.id] = since
		guard now.timeIntervalSince(since) >= settings.liftAfter else { return false }
		workingSince[g.id] = nil
		runningFree.insert(g.id)
		return true
	}

	/// Forget everything (Auto turned off), so re-enabling starts fresh.
	func reset() {
		decisions = [:]
		owners = [:]
		groupPids = [:]
		backgroundSince = [:]
		workingSince = [:]
		quietSince = [:]
		runningFree = []
		hotSince = [:]
		heldProcesses = []
		lastBusy = nil
		summary = AutoSummary()
		busy = false
		busyStreak = 0
		calmStreak = 0
		lastLoadSample = nil
	}

	/// Re-evaluate who's in use after a focus change, keeping the last load
	/// assessment and caps (no new measurement has been taken).
	func refocus(frontmostPid: pid_t, lastActive: [pid_t: Date], now: Date = Date()) -> [String: AutoDecision] {
		guard settings.enabled else { return [:] }
		for (id, var d) in decisions {
			guard let pid = owners[id] else { continue }
			if pid == frontmostPid || groupPids[id]?.contains(frontmostPid) == true {
				d = AutoDecision(reason: .foreground)
				backgroundSince[id] = nil
			} else if d.reason == .foreground {
				// Just left: in the grace period it stays at full speed.
				d = AutoDecision(reason: .recent)
			}
			decisions[id] = d
		}
		return decisions
	}

	/// Max-min fair allocation: apps wanting less than an equal share keep what
	/// they use; the rest split the remainder equally. Returns caps only for
	/// apps that want more than they're given.
	/// Apps Auto may freeze when the Mac is low on memory: regular apps (not
	/// menu bar apps) you haven't used for `idleAfter`, using at least
	/// `minimumBytes`, biggest first. Never the app in use, anything playing or
	/// recording audio, messaging and calls apps (you'd miss messages), apps
	/// still doing work (above `busyCPU`), terminals, IDEs or virtual machines.
	static func idleFreezeCandidates(_ groups: [AppGroup], frontmostPid: pid_t, lastActive: [pid_t: Date],
									 audioPids: Set<pid_t>, idleAfter: TimeInterval, since: Date, now: Date = Date(),
									 minimumBytes: UInt64 = 100 * 1_048_576, busyCPU: Double = 0.05) -> [String] {
		groups.filter { g in
			guard g.kind == .app, g.footprint >= minimumBytes, g.cpu < busyCPU, !g.pids.contains(frontmostPid),
				  !g.pids.contains(where: audioPids.contains), !AppTraits.neverIdleFreeze(name: g.name, bundleID: g.bundleID) else { return false }
			let lastUsed = g.pids.compactMap { lastActive[$0] }.max() ?? since
			return now.timeIntervalSince(lastUsed) >= idleAfter
		}
		.sorted { $0.footprint > $1.footprint }
		.map(\.id)
	}

	static func fairShare(_ wants: [(id: String, want: Double)], budget: Double, floor: Double) -> [String: Double] {
		var remaining = budget
		var pending = wants.sorted { $0.want < $1.want }
		var caps: [String: Double] = [:]
		while !pending.isEmpty {
			let share = remaining / Double(pending.count)
			let first = pending[0]
			if first.want <= share {
				remaining -= first.want
				pending.removeFirst()
			} else {
				for app in pending { caps[app.id] = max(floor, share) }
				break
			}
		}
		return caps
	}
}
