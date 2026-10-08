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
	/// Which pressure level counts as "low memory": 2 = warning, 4 = critical.
	var pressureThreshold = 4

	private var gids: [String: UInt32] = [:]
	private var nextGid: UInt32 = 1
	private var applied: [UInt32: Applied] = [:]
	private var backgroundPids: [pid_t: String] = [:]
	private var backgroundFailed: Set<String> = []
	private var memoryStrikes: [String: Int] = [:]
	private var memoryTriggered: Set<String> = []
	private var pressureActed: Set<String> = []
	private var deniedLogged: Set<String> = []
	private var lastEvaluatedSeq: UInt64 = 0
	private(set) var frozen: [String: FreezeReason] = [:]
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
	func apply(_ snapshot: Snapshot, rules: RuleStore, state: SystemState, frontmostPid: pid_t) {
		let freshSample = snapshot.seq != 0 && snapshot.seq != lastEvaluatedSeq
		if freshSample { lastEvaluatedSeq = snapshot.seq }
		let lowMemory = state.memoryPressure >= pressureThreshold

		var desired: [UInt32: Applied] = [:]
		var wantBackground: [pid_t: String] = [:]
		let selfPid = getpid()

		for group in snapshot.groups where group.ownerPid != selfPid && !Protected.contains(group) {
			groupNames[group.id] = group.name
			lastGroups[group.id] = group
			let rule = rules.rule(for: group).flatMap { $0.isInEffect(state) ? $0 : nil }
			let pids = (rule?.includeHelpers ?? true) ? group.pids.sorted() : [group.ownerPid]
			let gid = gid(for: group.id)

			if let rule, freshSample {
				if rule.pressureAction != .none && lowMemory && !pressureActed.contains(group.id) {
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
				desired[gid] = Applied(pids: frozenPids(group, rule: rule), limit: 0, frozen: true)
				continue
			}
			guard let rule else { continue }

			if rule.cpuLimitEnabled && !(rule.onlyWhenInactive && group.ownerPid == frontmostPid) {
				desired[gid] = Applied(pids: pids, limit: max(rule.cpuLimit, 1) / 100, frozen: false)
			}
			if rule.backgroundMode {
				for pid in pids { wantBackground[pid] = group.id }
			}
		}

		// Memory came back: thaw what we froze because of it.
		if !lowMemory && freshSample {
			pressureActed.removeAll()
			for (id, reason) in frozen where reason == .memoryPressure {
				frozen[id] = nil
				if let gid = gids[id] { desired[gid] = nil }
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

		applyBackground(wantBackground)
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
		for pid in backgroundPids.keys where want[pid] == nil {
			_ = controller.setBackground(pid, on: false)
		}
		backgroundPids = now
	}

	private func checkMemory(_ group: AppGroup, rule: AppRule) {
		let limit = UInt64(rule.memoryLimitMB * 1_048_576)
		let footprint = rule.includeHelpers ? group.footprint : group.ownerFootprint
		if footprint > limit {
			let strikes = (memoryStrikes[group.id] ?? 0) + 1
			memoryStrikes[group.id] = strikes
			// Two consecutive samples over the limit, so a brief spike doesn't trigger.
			guard strikes >= 2, !memoryTriggered.contains(group.id) else { return }
			memoryTriggered.insert(group.id)
			let detail = L("Memory %@ exceeded limit %@", Fmt.bytes(footprint), Fmt.megabytes(rule.memoryLimitMB))
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
		switch rule.pressureAction {
		case .none:
			break
		case .freeze:
			guard frozen[group.id] == nil else { return }
			onEvent?(group.name, L("Mac is low on memory — frozen"), true)
			freeze(group, reason: .memoryPressure)
		case .quit:
			onEvent?(group.name, L("Mac is low on memory — quitting"), true)
			quit(group)
		}
	}

	// MARK: Manual actions

	func freeze(_ group: AppGroup, reason: FreezeReason = .manual) {
		guard !Protected.contains(group), group.ownerPid != getpid() else { return }
		frozen[group.id] = reason
		groupNames[group.id] = group.name
		let gid = gid(for: group.id)
		let pids = group.pids.sorted()
		controller.setGroup(gid, pids: pids, limit: 0, frozen: true)
		applied[gid] = Applied(pids: pids, limit: 0, frozen: true)
	}

	func unfreeze(_ groupID: String) {
		frozen[groupID] = nil
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
		frozen[groupID] = nil
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
		frozen.removeAll()
		for pid in backgroundPids.keys { _ = controller.setBackground(pid, on: false) }
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
		if let b = bundleID, bundleIDs.contains(b) { return true }
		if let b = bundleID, b == Bundle.main.bundleIdentifier { return true }
		return names.contains(name) || pid <= 1
	}
}
