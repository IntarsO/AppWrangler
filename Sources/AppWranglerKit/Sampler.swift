//
//  Sampler.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Collects per-process usage and folds helpers/XPC services into the app that
//  owns them. Runs on a background queue; process identity (path, parent,
//  responsible app) is cached per pid, so a steady-state tick costs one pid
//  listing plus one rusage call per *measured* process.
//

import Foundation
import ProcKit

struct ProcIdent {
	let ppid: pid_t
	let rpid: pid_t
	let uid: uid_t
	let name: String
	let path: String
}

enum Grouping {
	/// The app a process belongs to: itself, or a GUI app that is responsible for
	/// it (or is an ancestor) *and* ships it. A shell started from Terminal stays
	/// separate while Chrome renderers and Safari's WebContent fold in.
	static func owner(of pid: pid_t, ident: ProcIdent, apps: [pid_t: RunningApp], idents: [pid_t: ProcIdent]) -> pid_t? {
		if apps[pid] != nil { return pid }
		var candidate: pid_t?
		if ident.rpid != pid, apps[ident.rpid] != nil {
			candidate = ident.rpid
		} else {
			var p = ident.ppid
			for _ in 0..<12 where p > 1 {
				if apps[p] != nil { candidate = p; break }
				guard let parent = idents[p] else { break }
				p = parent.ppid
			}
		}
		guard let owner = candidate, let app = apps[owner] else { return nil }
		if let bundlePath = app.bundlePath, ident.path.hasPrefix(bundlePath + "/") { return owner }
		if ident.rpid == owner, ident.path.contains(".xpc/") { return owner }
		return nil
	}

	static func groupID(for app: RunningApp) -> String {
		"app:" + (app.bundleID ?? app.bundlePath ?? "\(app.pid)")
	}
}

final class Sampler {
	private struct Prev {
		var start: UInt64
		var cpu: UInt64
		var read: UInt64
		var write: UInt64
		var energy: UInt64
		var time: UInt64
	}

	private let queue = DispatchQueue(label: "AppWrangler.sampler", qos: .utility)
	private var idents: [pid_t: ProcIdent] = [:]
	private var prev: [pid_t: Prev] = [:]
	private var pidBuffer = [pid_t](repeating: 0, count: 16384)
	private var pathBuffer = [CChar](repeating: 0, count: Int(PK_PATH_MAX))
	private var lastCPUTicks: pk_cpu_ticks?
	private var busy = false
	private let busyLock = NSLock()
	private var seq: UInt64 = 0
	private let myPid = getpid()
	private let myUID = getuid()

	/// Returns false if a sample is already running (the request is dropped).
	@discardableResult
	func sample(_ request: SampleRequest, completion: @escaping (Snapshot) -> Void) -> Bool {
		busyLock.lock()
		defer { busyLock.unlock() }
		guard !busy else { return false }
		busy = true
		queue.async {
			let snapshot = self.run(request)
			self.busyLock.lock()
			self.busy = false
			self.busyLock.unlock()
			DispatchQueue.main.async { completion(snapshot) }
		}
		return true
	}

	/// Synchronous sample (CLI and tests).
	func sampleNow(_ request: SampleRequest) -> Snapshot {
		queue.sync { run(request) }
	}

	private func run(_ req: SampleRequest) -> Snapshot {
		seq += 1
		var snapshot = Snapshot(seq: seq, full: req.includeAll)
		var ticks = pk_cpu_ticks()
		if pk_cpu_ticks_get(&ticks) == 0 {
			if let last = lastCPUTicks, ticks.total > last.total {
				snapshot.systemCPU = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total)
			}
			lastCPUTicks = ticks
		}
		pk_memory_stats_get(&snapshot.memory)

		let count = Int(pk_list_pids(&pidBuffer, Int32(pidBuffer.count)))
		var alive = Set<pid_t>(minimumCapacity: count)
		for i in 0..<count where pidBuffer[i] > 0 && pidBuffer[i] != myPid {
			alive.insert(pidBuffer[i])
		}
		if idents.keys.contains(where: { !alive.contains($0) }) {
			idents = idents.filter { alive.contains($0.key) }
			prev = prev.filter { alive.contains($0.key) }
		}
		for pid in alive where idents[pid] == nil {
			var info = pk_proc_ident()
			guard pk_proc_ident_get(pid, &info) == 0 else { continue }
			pk_proc_path(pid, &pathBuffer, UInt32(pathBuffer.count))
			let path = String(cString: pathBuffer)
			var name = withUnsafeBytes(of: info.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			if !path.isEmpty { name = (path as NSString).lastPathComponent }
			idents[pid] = ProcIdent(ppid: info.ppid, rpid: info.rpid, uid: info.uid, name: name, path: path)
		}

		// Assign every process to an app group or its own group.
		var appMembers: [String: [pid_t]] = [:]
		var appHeads: [String: RunningApp] = [:]
		var procGroups: [pid_t] = []
		for pid in alive {
			guard let ident = idents[pid] else { continue }
			if let owner = Grouping.owner(of: pid, ident: ident, apps: req.apps, idents: idents), let app = req.apps[owner] {
				let key = Grouping.groupID(for: app)
				appMembers[key, default: []].append(pid)
				if appHeads[key] == nil || owner == pid { appHeads[key] = app }
			} else if req.includeOtherUsers || ident.uid == myUID {
				procGroups.append(pid)
			}
		}

		let now = pk_now_ns()
		var groups: [AppGroup] = []
		groups.reserveCapacity(appMembers.count + procGroups.count)

		for (key, pids) in appMembers {
			guard let app = appHeads[key] else { continue }
			let path = app.bundlePath ?? idents[app.pid]?.path ?? ""
			let autoManaged = req.includeApps && (app.kind == .app || app.kind == .background)
			guard req.includeAll || autoManaged || req.matcher.matches(id: key, bundleID: app.bundleID, path: path, name: app.name) else { continue }
			var group = AppGroup(id: key, ownerPid: app.pid, name: app.name, bundleID: app.bundleID, path: path, kind: app.kind)
			measure(&group, pids: pids, now: now, withThreads: req.withThreads)
			groups.append(group)
		}

		for pid in procGroups {
			guard let ident = idents[pid] else { continue }
			let key = "proc:\(pid)"
			guard req.includeAll || req.matcher.matches(id: key, bundleID: nil, path: ident.path, name: ident.name) else { continue }
			var group = AppGroup(id: key, ownerPid: pid, name: ident.name, bundleID: nil, path: ident.path, kind: .process)
			measure(&group, pids: [pid], now: now, withThreads: req.withThreads)
			groups.append(group)
		}

		snapshot.groups = groups
		return snapshot
	}

	private func measure(_ group: inout AppGroup, pids: [pid_t], now: UInt64, withThreads: Bool) {
		var usage = pk_proc_usage()
		var anyMeasured = false
		for pid in pids {
			guard let ident = idents[pid] else { continue }
			var stat = ProcessStat(pid: pid, name: ident.name, path: ident.path)
			if pk_proc_usage_get(pid, withThreads ? 1 : 0, &usage) == 0 {
				stat.measured = true
				stat.footprint = usage.footprint
				stat.threads = Int(usage.threads)
				// A baseline older than 10 s (process wasn't watched) would average over too long a window.
				if let p = prev[pid], p.start == usage.start_abstime, now > p.time, now - p.time < 10_000_000_000 {
					let dt = Double(now - p.time)
					stat.cpu = Double(usage.cpu_ns &- p.cpu) / dt
					stat.diskRead = Double(usage.disk_read &- p.read) / dt * 1e9
					stat.diskWrite = Double(usage.disk_written &- p.write) / dt * 1e9
					stat.power = Double(usage.energy_nj &- p.energy) / dt		// nJ/ns == W
				}
				prev[pid] = Prev(start: usage.start_abstime, cpu: usage.cpu_ns, read: usage.disk_read,
								 write: usage.disk_written, energy: usage.energy_nj, time: now)
				anyMeasured = true
				group.cpu += stat.cpu
				group.footprint += stat.footprint
				group.diskRead += stat.diskRead
				group.diskWrite += stat.diskWrite
				group.power += stat.power
				group.threads += stat.threads
			}
			group.processes.append(stat)
		}
		group.measured = anyMeasured
		group.processes.sort { $0.cpu > $1.cpu }
	}
}
