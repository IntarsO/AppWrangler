//
//  Helpers.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import ProcKit
@testable import AppWranglerKit

/// Records everything the enforcer asks for instead of signalling processes.
final class FakeController: ProcessController {
	struct SetCall: Equatable {
		let gid: UInt32
		let pids: [pid_t]
		let limit: Double
		let frozen: Bool
	}

	var sets: [SetCall] = []
	var removed: [UInt32] = []
	var paused = false
	var background: [pid_t: Bool] = [:]
	var terminated: [pid_t] = []
	var children: [pid_t: [pid_t]] = [:]
	var killed: [pid_t] = []
	/// Current limiter table, as the real C limiter would hold it.
	var groups: [UInt32: SetCall] = [:]

	func setGroup(_ gid: UInt32, pids: [pid_t], limit: Double, frozen: Bool) {
		let call = SetCall(gid: gid, pids: pids, limit: limit, frozen: frozen)
		sets.append(call)
		groups[gid] = call
	}
	func removeGroup(_ gid: UInt32) { removed.append(gid); groups[gid] = nil }
	func removeAllGroups() { groups.removeAll() }
	func setPaused(_ paused: Bool) { self.paused = paused }
	func setBackground(_ pid: pid_t, on: Bool) -> Int32 { background[pid] = on; return 0 }
	func descendants(of pid: pid_t) -> [pid_t] {
		(children[pid] ?? []).flatMap { [$0] + descendants(of: $0) }
	}
	func terminate(_ group: AppGroup) { terminated.append(group.ownerPid) }
	func forceKill(_ pids: [pid_t]) { killed.append(contentsOf: pids) }
	func limiterStatus() -> [pk_lim_status] { [] }
	func releaseAll() {}

	var frozenGroups: [SetCall] { groups.values.filter(\.frozen) }
	var limitedGroups: [SetCall] { groups.values.filter { !$0.frozen } }
}

func makeGroup(name: String = "Test App", bundleID: String? = "com.example.test", pid: pid_t = 50_000,
			   helpers: [pid_t] = [], cpu: Double = 0.1, footprintMB: Double = 100,
			   helperFootprintMB: Double = 0, kind: AppKind = .app) -> AppGroup {
	var g = AppGroup(id: "app:" + (bundleID ?? name), ownerPid: pid, name: name, bundleID: bundleID,
					 path: "/Applications/\(name).app", kind: kind)
	g.processes = [ProcessStat(pid: pid, name: name, path: g.path, footprint: UInt64(footprintMB * 1_048_576), measured: true)]
	for h in helpers {
		g.processes.append(ProcessStat(pid: h, name: name + " Helper", path: g.path + "/Contents/Helper",
									   footprint: UInt64(helperFootprintMB * 1_048_576), measured: true))
	}
	g.cpu = cpu
	g.footprint = g.processes.reduce(0) { $0 + $1.footprint }
	g.measured = true
	return g
}

func makeSnapshot(_ groups: [AppGroup], seq: UInt64) -> Snapshot {
	var s = Snapshot()
	s.seq = seq
	s.full = true
	s.groups = groups
	return s
}

func tempStore() -> RuleStore {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerTests-\(UUID().uuidString)")
	return RuleStore(directory: dir, defaults: UserDefaults(suiteName: "AppWranglerTests-\(UUID().uuidString)")!)
}

/// Spawn `/usr/bin/yes > /dev/null` — a one-core CPU burner that needs no compiling.
func spawnBurner() -> pid_t {
	var pid: pid_t = 0
	var actions: posix_spawn_file_actions_t?
	posix_spawn_file_actions_init(&actions)
	posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
	let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/yes"), nil]
	posix_spawn(&pid, "/usr/bin/yes", &actions, nil, argv, environ)
	posix_spawn_file_actions_destroy(&actions)
	argv.forEach { free($0) }
	// Don't inherit an efficiency-cores policy from whatever launched the tests.
	_ = pk_set_background(pid, 0)
	return pid
}

func reap(_ pids: [pid_t]) {
	for pid in pids {
		kill(pid, SIGCONT)
		kill(pid, SIGKILL)
		var status: Int32 = 0
		waitpid(pid, &status, 0)
	}
}

/// Combined CPU usage of `pids` (in cores) over `seconds`.
func measureCPU(_ pids: [pid_t], seconds: Double) -> Double {
	func total() -> UInt64 {
		var sum: UInt64 = 0
		var u = pk_proc_usage()
		for pid in pids where pk_proc_usage_get(pid, 0, &u) == 0 { sum += u.cpu_ns }
		return sum
	}
	let a = total(), t = pk_now_ns()
	usleep(useconds_t(seconds * 1_000_000))
	return Double(total() - a) / Double(pk_now_ns() - t)
}
