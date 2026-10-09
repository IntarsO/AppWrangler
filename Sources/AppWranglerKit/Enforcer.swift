//
//  Enforcer.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Turns rules + the latest snapshot into actions: CPU duty-cycling (via the C
//  limiter), E-core/background policy, freezing, memory-limit and
//  memory-pressure responses. Main thread only.
//

import AppKit
import ProcKit

/// Everything the enforcer does to other processes, so tests can substitute a fake.
protocol ProcessController: AnyObject {
	func setGroup(_ gid: UInt32, pids: [pid_t], limit: Double, frozen: Bool)
	func removeGroup(_ gid: UInt32)
	func removeAllGroups()
	func setPaused(_ paused: Bool)
	/// Returns 0 or an errno.
	func setBackground(_ pid: pid_t, on: Bool) -> Int32
	/// All descendants (children, grandchildren…) of a process.
	func descendants(of pid: pid_t) -> [pid_t]
	func isAlive(_ pid: pid_t) -> Bool
	/// A shell's foreground job: SIGSTOP would make the shell suspend it.
	func isTerminalForeground(_ pid: pid_t) -> Bool
	func terminate(_ group: AppGroup)
	func forceKill(_ pids: [pid_t])
	func limiterStatus() -> [pk_lim_status]
	func releaseAll()
}

final class LiveProcessController: ProcessController {
	func setGroup(_ gid: UInt32, pids: [pid_t], limit: Double, frozen: Bool) {
		pids.withUnsafeBufferPointer {
			pk_lim_set_group(gid, $0.baseAddress, Int32(pids.count), limit, frozen ? 1 : 0)
		}
	}
	func removeGroup(_ gid: UInt32) { pk_lim_remove_group(gid) }
	func removeAllGroups() { pk_lim_remove_all() }
	func setPaused(_ paused: Bool) { pk_lim_set_paused(paused ? 1 : 0) }
	func setBackground(_ pid: pid_t, on: Bool) -> Int32 { pk_set_background(pid, on ? 1 : 0) }

	func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
	func isTerminalForeground(_ pid: pid_t) -> Bool { pk_is_terminal_foreground(pid) != 0 }

	func descendants(of pid: pid_t) -> [pid_t] {
		var result: [pid_t] = []
		var queue = [pid]
		var buffer = [pid_t](repeating: 0, count: 1024)
		while let p = queue.popLast(), result.count < 4096 {
			let n = Int(pk_list_children(p, &buffer, Int32(buffer.count)))
			for i in 0..<n where buffer[i] > 1 && buffer[i] != p {
				result.append(buffer[i])
				queue.append(buffer[i])
			}
		}
		return result
	}

	func terminate(_ group: AppGroup) {
		if group.isApp, let app = NSRunningApplication(processIdentifier: group.ownerPid) {
			app.terminate()
		} else {
			kill(group.ownerPid, SIGTERM)
		}
	}

	func forceKill(_ pids: [pid_t]) {
		for pid in pids { kill(pid, SIGKILL) }
	}

	func limiterStatus() -> [pk_lim_status] {
		var buffer = [pk_lim_status](repeating: pk_lim_status(), count: Int(PK_MAX_GROUPS))
		let n = Int(pk_lim_status_get(&buffer, Int32(buffer.count)))
		return Array(buffer.prefix(n))
	}

	func releaseAll() { pk_release_all() }
}

enum FreezeReason: String {
	case manual, memoryLimit, memoryPressure
	/// "Free memory now": idle apps frozen on request; they resume when you switch to them.
	case idle

	/// Freezes that end by themselves as soon as you switch to the app (or it plays audio).
	var resumesOnFocus: Bool { self == .memoryPressure || self == .idle }
}

final class Enforcer {
	private struct Applied: Equatable {
		var pids: [pid_t]
		var limit: Double
		var frozen: Bool
	}

	let controller: ProcessController
	/// (app name, message, post a notification?)
	var onEvent: ((String, String, Bool) -> Void)?
	/// Something the menu bar panel shows as a card, with a way to set the app up by hand.
	var onAction: ((AppGroup, PanelAction.Kind, String) -> Void)?
	/// Actions for the impact statistics: (group, event).
	var onImpact: ((AppGroup, StatsStore.Event) -> Void)?
	/// Which pressure level counts as "low memory": 2 = warning, 4 = critical.
	var pressureThreshold = 4
	/// Memory must stay fine this long before low-memory freezes are lifted,
	/// so pressure hovering at the threshold doesn't freeze and thaw repeatedly.
	var pressureThawDelay: TimeInterval = 60
	private var memoryFineSince: Date?
	/// Resume memory-frozen apps one at a time (oldest first) instead of all at once, so they
	/// don't all wake together and squeeze memory again.
	var gradualThaw = false
	var thawGap: TimeInterval = 10
	private var lastThaw: Date?

	private var gids: [String: UInt32] = [:]
	private var nextGid: UInt32 = 1
	private var applied: [UInt32: Applied] = [:]
	private var backgroundPids: [pid_t: String] = [:]
	/// Pids of in-use apps we've already made sure are at full speed.
	private var ensuredFullSpeed: Set<pid_t> = []
	private var backgroundFailed: Set<String> = []
	private var memoryStrikes: [String: Int] = [:]
	private var memoryTriggered: Set<String> = []
	private var pressureActed: Set<String> = []
	private var deniedLogged: Set<String> = []
	private var lastEvaluatedSeq: UInt64 = 0
	private(set) var frozen: [String: FreezeReason] = [:]
	/// CPU (cores) each frozen group was using when it was frozen — what freezing saves.
	private(set) var frozenDemand: [String: Double] = [:]
	/// When each group was frozen, and its main process (a relaunch is a new process).
	private(set) var frozenSince: [String: Date] = [:]
	private var frozenOwner: [String: pid_t] = [:]
	private var terminalJobsLogged: Set<String> = []
	private var groupNames: [String: String] = [:]
	private var lastGroups: [String: AppGroup] = [:]

	private(set) var paused = false

	init(controller: ProcessController = LiveProcessController()) {
		self.controller = controller
	}

	func setPaused(_ paused: Bool) {
		self.paused = paused
		controller.setPaused(paused)
	}

	private func gid(for groupID: String) -> UInt32 {
		if let g = gids[groupID] { return g }
		let g = nextGid
		nextGid &+= 1
		gids[groupID] = g
		return g
	}

	/// Groups that must be measured even when the UI is hidden.
	var trackedGroupIDs: Set<String> { Set(frozen.keys) }

	func isFrozen(_ groupID: String) -> Bool { frozen[groupID] != nil }

	// MARK: Apply

	/// Apply rules. Safe to call repeatedly with the same snapshot (e.g. on a
	/// focus change): memory checks only count *new* samples.
	/// What Auto mode last decided for each group it manages.
	private(set) var autoDecisions: [String: AutoDecision] = [:]
	/// The CPU limit actually in force per group (manual or Auto), in cores.
	private(set) var effectiveLimit: [String: Double] = [:]

	/// - Parameters:
	///   - autoFreeze: apps Auto mode may freeze while the Mac is low on memory.
	///   - autoFreezeActive: Auto's idle-app freezing is switched on (else its freezes are lifted).
	///   - autoLowMemory: whether memory is short by Auto's own (earlier) measure; nil means the same as
	///     `pressureThreshold`. Freezes are held, and not thawed, while either measure says it's short.
	func apply(_ snapshot: Snapshot, rules: RuleStore, state: SystemState, frontmostPid: pid_t,
			   auto: [String: AutoDecision] = [:], audioPids: Set<pid_t> = [], autoFreeze: Set<String> = [],
			   autoFreezeActive: Bool = false, autoLowMemory: Bool? = nil, now: Date = Date()) {
		autoDecisions = auto
		var limits: [String: Double] = [:]
		defer { effectiveLimit = limits }
		let freshSample = snapshot.seq != 0 && snapshot.seq != lastEvaluatedSeq
		if freshSample { lastEvaluatedSeq = snapshot.seq }
		let lowMemory = state.memoryPressure >= pressureThreshold
		let holdFreezes = lowMemory || (autoLowMemory ?? false)
		if holdFreezes { memoryFineSince = nil } else if memoryFineSince == nil { memoryFineSince = now }

		var desired: [UInt32: Applied] = [:]
		var wantBackground: [pid_t: String] = [:]
		var inUsePids: Set<pid_t> = []
		let selfPid = getpid()

		for group in snapshot.groups where group.ownerPid != selfPid && !Protected.contains(group) {
			groupNames[group.id] = group.name
			lastGroups[group.id] = group
			let rule = rules.rule(for: group).flatMap { $0.isInEffect(state) ? $0 : nil }
			// Never SIGSTOP a shell's foreground job — the shell would treat it as
			// suspended and detach it. Efficiency cores still apply to it.
			let allPids = (rule?.includeHelpers ?? true) ? group.pids.sorted() : [group.ownerPid]
			let pids = allPids.filter { !controller.isTerminalForeground($0) }
			if pids.count < allPids.count, (rule?.cpuLimitEnabled == true || frozen[group.id] != nil),
			   terminalJobsLogged.insert(group.id).inserted {
				onEvent?(group.name, L("Running in a terminal's foreground — CPU limit and freeze skipped (they would suspend the job). Efficiency cores still apply."), false)
			}
			let gid = gid(for: group.id)

			// A frozen app that quit and was relaunched (new main process) starts unfrozen.
			if let owner = frozenOwner[group.id], owner != group.ownerPid, !controller.isAlive(owner) {
				clearFrozen(group.id)
			}

			// Frozen because memory ran short, and now you've switched to it (or it
			// plays audio): resume it right away rather than waiting for memory.
			if frozen[group.id]?.resumesOnFocus == true,
			   group.pids.contains(frontmostPid) || group.pids.contains(where: audioPids.contains) {
				clearFrozen(group.id)
				onEvent?(group.name, L("Resumed — you switched to it"), false)
			}

			// A freeze ends when its reason goes away: the memory-limit rule was removed,
			// disabled or no longer freezes; low-memory freezing was switched off.
			if let reason = frozen[group.id] {
				let stillWanted: Bool
				switch reason {
				case .manual, .idle: stillWanted = true
				case .memoryLimit: stillWanted = rule.map { $0.memoryLimitEnabled && $0.memoryAction == .freeze } ?? false
				case .memoryPressure: stillWanted = rule?.pressureAction == .freeze || autoFreezeActive
				}
				if !stillWanted {
					clearFrozen(group.id)
					onEvent?(group.name, L("Resumed — the setting that froze it was turned off"), false)
				}
			}

			// Auto mode: freeze an app you haven't used for a while when memory runs short.
			if freshSample, !paused, autoLowMemory ?? lowMemory, autoFreeze.contains(group.id), frozen[group.id] == nil, !pressureActed.contains(group.id),
			   !group.pids.contains(frontmostPid), !group.pids.contains(where: audioPids.contains),
			   (auto[group.id].map { $0.reason == .background } ?? true) {
				pressureActed.insert(group.id)
				onImpact?(group, .lowMemoryAction)
				onEvent?(group.name, L("Mac is low on memory — frozen by Auto mode until you switch to it"), true)
				onAction?(group, .autoFreeze, L("Mac is low on memory. It resumes when you switch to it."))
				freeze(group, reason: .memoryPressure)
			}

			if let rule, freshSample, !paused {
				// Never freeze/quit the app you're using (or one playing/recording audio)
				// just because the Mac is short of memory; pick a background app instead.
				let inUse = group.pids.contains(frontmostPid) || group.pids.contains(where: audioPids.contains)
					|| (auto[group.id].map { $0.reason != .background } ?? false)
				if rule.pressureAction != .none && lowMemory && !inUse && !pressureActed.contains(group.id) {
					pressureActed.insert(group.id)
					handlePressure(group, rule: rule)
				}
				if rule.memoryLimitEnabled && group.measured {
					checkMemory(group, rule: rule)
				} else {
					memoryStrikes[group.id] = nil
					memoryTriggered.remove(group.id)
				}
			}

			if frozen[group.id] != nil {
				let fp = frozenPids(group, rule: rule).filter { !controller.isTerminalForeground($0) }
				if !fp.isEmpty { desired[gid] = Applied(pids: fp, limit: 0, frozen: true) }
				continue
			}

			// Auto mode manages apps whose rule doesn't set CPU / E-cores itself.
			if let d = auto[group.id], !(rule?.cpuLimitEnabled ?? false), !(rule?.backgroundMode ?? false) {
				if d.reason != .background { inUsePids.formUnion(group.pids) }
				// Auto treats the app as a whole: a rule's "include helpers" only
				// scopes that rule's own limits (e.g. a memory limit).
				let appPids = group.pids.sorted()
				let stoppable = appPids.filter { !controller.isTerminalForeground($0) }
				if let cap = d.cap, !stoppable.isEmpty {
					desired[gid] = Applied(pids: stoppable, limit: cap, frozen: false)
					limits[group.id] = cap
				}
				if d.efficiency {
					for pid in appPids { wantBackground[pid] = group.id }
				}
			}
			guard let rule else { continue }

			// "Only while in the background" keeps the app at full speed while you use it.
			let inUse = rule.onlyWhenInactive && group.pids.contains(frontmostPid)
			if rule.cpuLimitEnabled && !inUse && !pids.isEmpty {
				let limit = max(rule.cpuLimit, 1) / 100
				desired[gid] = Applied(pids: pids, limit: limit, frozen: false)
				limits[group.id] = limit
			}
			if rule.backgroundMode && !inUse {
				for pid in allPids { wantBackground[pid] = group.id }
			}
		}

		// A frozen app or process that has gone away is no longer frozen —
		// otherwise a relaunched app would come back frozen.
		if freshSample {
			let present = Set(snapshot.groups.map(\.id))
			// Absent from this sample isn't enough (it may have been taken before
			// the freeze): its processes must actually have exited.
			for id in frozen.keys where !present.contains(id)
				&& !(gids[id].flatMap { applied[$0]?.pids } ?? []).contains(where: { controller.isAlive($0) }) {
				clearFrozen(id)
				if let gid = gids[id] { desired[gid] = nil }
				onEvent?(groupNames[id] ?? id, L("Quit while frozen — no longer frozen"), false)
			}
		}

		// A frozen app missing from this (partial) sample stays frozen.
		let present = Set(snapshot.groups.map(\.id))
		for id in frozen.keys where !present.contains(id) {
			if let gid = gids[id], let a = applied[gid], desired[gid] == nil { desired[gid] = a }
		}

		// Memory came back (and stayed back for a while): thaw what we froze because of it.
		if !holdFreezes && freshSample, let since = memoryFineSince, now.timeIntervalSince(since) >= pressureThawDelay {
			pressureActed.removeAll()
			var due = frozen.filter { $0.value == .memoryPressure }.map(\.key)
			if gradualThaw {
				if let last = lastThaw, now.timeIntervalSince(last) < thawGap {
					due = []
				} else {
					due = Array(due.sorted { (frozenSince[$0] ?? .distantPast) < (frozenSince[$1] ?? .distantPast) }.prefix(1))
				}
			}
			for id in due {
				clearFrozen(id)
				if let gid = gids[id] { desired[gid] = nil }
				lastThaw = now
				onEvent?(groupNames[id] ?? id, L("Memory pressure eased — resumed"), false)
			}
		}

		// Only touch groups whose parameters changed, so steady state never
		// interrupts a duty cycle.
		for (gid, params) in desired where applied[gid] != params {
			controller.setGroup(gid, pids: params.pids, limit: params.limit, frozen: params.frozen)
		}
		for gid in applied.keys where desired[gid] == nil {
			controller.removeGroup(gid)
		}
		applied = desired

		// Forget groups that are gone, so bookkeeping doesn't grow with every
		// short-lived process (builds, scripts) seen by full scans.
		if freshSample {
			let keep = Set(snapshot.groups.map(\.id)).union(frozen.keys)
			let liveGids = Set(applied.keys)
			gids = gids.filter { keep.contains($0.key) || liveGids.contains($0.value) }
			lastGroups = lastGroups.filter { keep.contains($0.key) }
			groupNames = groupNames.filter { gids[$0.key] != nil || keep.contains($0.key) }
			memoryStrikes = memoryStrikes.filter { keep.contains($0.key) }
			memoryTriggered.formIntersection(keep)
			deniedLogged.formIntersection(keep)
			backgroundFailed.formIntersection(keep)
			terminalJobsLogged.formIntersection(keep)
		}

		applyBackground(wantBackground)

		// An app you're using must be at full speed even if something else (an
		// earlier AppWrangler, `taskpolicy`, inheritance) put it in the background.
		for pid in inUsePids where !ensuredFullSpeed.contains(pid) && wantBackground[pid] == nil {
			_ = controller.setBackground(pid, on: false)
		}
		ensuredFullSpeed = inUsePids
	}

	private func frozenPids(_ group: AppGroup, rule: AppRule?) -> [pid_t] {
		(rule?.includeHelpers ?? true) ? group.pids.sorted() : [group.ownerPid]
	}

	private func applyBackground(_ want: [pid_t: String]) {
		var now: [pid_t: String] = [:]
		for (pid, groupID) in want {
			if backgroundPids[pid] != nil {
				now[pid] = groupID
				continue
			}
			let err = controller.setBackground(pid, on: true)
			if err == 0 {
				now[pid] = groupID
			} else if err != ESRCH, !backgroundFailed.contains(groupID) {
				backgroundFailed.insert(groupID)
				onEvent?(groupNames[groupID] ?? groupID, L("Couldn't enable efficiency mode: %@", String(cString: strerror(err))), false)
			}
		}
		for (pid, groupID) in backgroundPids where want[pid] == nil {
			_ = controller.setBackground(pid, on: false)
			// Processes it started while in efficiency mode inherited the policy
			// (e.g. shells and builds launched from a terminal app); restore them
			// too, unless their own rule wants efficiency cores. The app's own
			// helpers are skipped: we restored the ones we set, and apps like
			// Chromium deliberately background some helpers themselves.
			let own = Set(lastGroups[groupID]?.pids ?? [])
			for child in controller.descendants(of: pid) where want[child] == nil && !own.contains(child) {
				_ = controller.setBackground(child, on: false)
			}
		}
		backgroundPids = now
	}

	private func checkMemory(_ group: AppGroup, rule: AppRule) {
		let limit = UInt64(min(max(rule.memoryLimitMB, 0), AppRule.memoryLimitRange.upperBound) * 1_048_576)
		let footprint = rule.includeHelpers ? group.footprint : group.ownerFootprint
		if footprint > limit {
			let strikes = (memoryStrikes[group.id] ?? 0) + 1
			memoryStrikes[group.id] = strikes
			// Two consecutive samples over the limit, so a brief spike doesn't trigger.
			guard strikes >= 2, !memoryTriggered.contains(group.id) else { return }
			memoryTriggered.insert(group.id)
			let detail = L("Memory %@ exceeded limit %@", Fmt.bytes(footprint), Fmt.megabytes(rule.memoryLimitMB))
			let quits = rule.memoryAction == .quit || rule.memoryAction == .forceQuit
			onAction?(group, .memoryRule, detail)
			onImpact?(group, .memoryAction(freedBytes: quits ? Double(group.footprint) : 0))
			switch rule.memoryAction {
			case .notify:
				onEvent?(group.name, detail, true)
			case .freeze:
				onEvent?(group.name, detail + " — " + L("frozen"), true)
				freeze(group, reason: .memoryLimit)
			case .quit:
				onEvent?(group.name, detail + " — " + L("quitting"), true)
				quit(group)
			case .forceQuit:
				onEvent?(group.name, detail + " — " + L("force quit"), true)
				forceQuit(group)
			}
		} else if Double(footprint) < Double(limit) * 0.9 {
			memoryStrikes[group.id] = nil
			memoryTriggered.remove(group.id)
		}
	}

	private func handlePressure(_ group: AppGroup, rule: AppRule) {
		if rule.pressureAction != .none { onImpact?(group, .lowMemoryAction) }
		switch rule.pressureAction {
		case .none:
			break
		case .freeze:
			guard frozen[group.id] == nil else { return }
			onEvent?(group.name, L("Mac is low on memory — frozen"), true)
			onAction?(group, .lowMemoryRule, L("Mac is low on memory — frozen"))
			freeze(group, reason: .memoryPressure)
		case .quit:
			onEvent?(group.name, L("Mac is low on memory — quitting"), true)
			onAction?(group, .lowMemoryRule, L("Mac is low on memory — quitting"))
			quit(group)
		}
	}

	// MARK: Manual actions

	/// Called whenever an app is frozen (for statistics).
	var onFreeze: ((AppGroup, FreezeReason) -> Void)?

	func freeze(_ group: AppGroup, reason: FreezeReason = .manual) {
		guard !Protected.contains(group), group.ownerPid != getpid() else { return }
		// Never stop a shell's foreground job: the shell would treat it as suspended.
		let pids = group.pids.sorted().filter { !controller.isTerminalForeground($0) }
		guard !pids.isEmpty else {
			onEvent?(group.name, L("Running in a terminal's foreground — not frozen (it would suspend the job)."), false)
			return
		}
		frozen[group.id] = reason
		frozenSince[group.id] = Date()
		frozenOwner[group.id] = group.ownerPid
		// A group looked up for a CLI freeze has no rate yet; use the last measurement.
		frozenDemand[group.id] = max(group.cpu, lastGroups[group.id]?.cpu ?? 0)
		groupNames[group.id] = group.name
		let gid = gid(for: group.id)
		controller.setGroup(gid, pids: pids, limit: 0, frozen: true)
		applied[gid] = Applied(pids: pids, limit: 0, frozen: true)
		onFreeze?(group, reason)
	}

	private func clearFrozen(_ id: String) {
		frozen[id] = nil
		frozenDemand[id] = nil
		frozenSince[id] = nil
		frozenOwner[id] = nil
	}

	func unfreeze(_ groupID: String) {
		clearFrozen(groupID)
		guard let gid = gids[groupID] else { return }
		controller.removeGroup(gid)
		applied[gid] = nil
	}

	func quit(_ group: AppGroup) {
		release(group.id)
		controller.terminate(group)
	}

	func forceQuit(_ group: AppGroup) {
		release(group.id)
		controller.forceKill(group.pids)
	}

	/// Resume a group fully so it can handle a quit request.
	private func release(_ groupID: String) {
		clearFrozen(groupID)
		guard let gid = gids[groupID] else { return }
		controller.removeGroup(gid)
		applied[gid] = nil
	}

	/// Find a group seen recently by id or (case-insensitive) name.
	func knownGroup(matching target: String) -> AppGroup? {
		if let g = lastGroups[target] { return g }
		let t = target.lowercased()
		return lastGroups.values.first { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t }
	}

	/// Resume everything and drop all policies (used on quit).
	func releaseAll() {
		controller.removeAllGroups()
		applied.removeAll()
		for id in frozen.keys { clearFrozen(id) }
		for (pid, groupID) in backgroundPids {
			_ = controller.setBackground(pid, on: false)
			let own = Set(lastGroups[groupID]?.pids ?? [])
			for child in controller.descendants(of: pid) where !own.contains(child) {
				_ = controller.setBackground(child, on: false)
			}
		}
		backgroundPids.removeAll()
		controller.releaseAll()
	}

	// MARK: Status

	func limiterStatus() -> [String: pk_lim_status] {
		var byGid: [UInt32: pk_lim_status] = [:]
		for status in controller.limiterStatus() { byGid[status.gid] = status }
		var result: [String: pk_lim_status] = [:]
		for (groupID, gid) in gids {
			guard let status = byGid[gid] else { continue }
			result[groupID] = status
			if status.denied != 0, !deniedLogged.contains(groupID) {
				deniedLogged.insert(groupID)
				onEvent?(groupNames[groupID] ?? groupID, L("Permission denied — the process belongs to another user"), false)
			}
		}
		return result
	}

	func isInBackgroundMode(_ group: AppGroup) -> Bool {
		group.pids.contains { backgroundPids[$0] != nil }
	}

	#if DEBUG
	/// Screenshots: show a made-up state without touching any process.
	func setDemoState(decisions: [String: AutoDecision], frozen ids: [String], efficiency: [pid_t: String]) {
		autoDecisions = decisions
		for id in ids { frozen[id] = .idle; frozenSince[id] = Date() }
		backgroundPids = efficiency
	}
	#endif
}

/// Processes that must never be stopped: doing so would hang the session.
enum Protected {
	private static let names: Set<String> = [
		"kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "SystemUIServer",
		"ControlCenter", "coreaudiod", "hidd", "logd", "opendirectoryd", "securityd",
		"cfprefsd", "distnoted", "mds", "UserEventAgent", "NotificationCenter",
	]
	private static let bundleIDs: Set<String> = [
		"com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
		"com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
	]

	static func contains(_ group: AppGroup) -> Bool {
		contains(name: group.name, bundleID: group.bundleID, pid: group.ownerPid)
	}

	static func contains(name: String, bundleID: String?, pid: pid_t) -> Bool {
		if let b = bundleID?.lowercased(), bundleIDs.contains(where: { $0.lowercased() == b }) { return true }
		if let b = bundleID, b.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame { return true }
		return names.contains { $0.caseInsensitiveCompare(name) == .orderedSame } || pid <= 1
	}
}
