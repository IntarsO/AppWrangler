//
//  Reports.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Machine-readable views of AppWrangler's state, shared by the CLI
//  (`--json`) and the MCP server so both always return the same data.
//

import AppKit
import ProcKit

enum Reports {
	/// Measure running apps for `seconds` and describe each one.
	static func apps(store: RuleStore, apps: [RunningApp], includeProcesses: Bool, limit: Int? = nil,
					 seconds: Double = 1) -> [[String: Any]] {
		let appMap = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
		let sampler = Sampler()
		let request = SampleRequest(apps: appMap, includeAll: true, includeOtherUsers: false, withThreads: true, matcher: GroupMatcher())
		_ = sampler.sampleNow(request)
		usleep(useconds_t(max(0.2, seconds) * 1_000_000))
		var groups = sampler.sampleNow(request).groups.filter { includeProcesses || $0.kind != .process }
		groups.sort { $0.cpu > $1.cpu }
		if let limit { groups = Array(groups.prefix(limit)) }
		return groups.map { group(store: store, $0) }
	}

	static func group(store: RuleStore, _ g: AppGroup) -> [String: Any] {
		let d = ProcessCatalog.describe(g)
		var row: [String: Any] = [
			"name": g.name,
			"kind": "\(g.kind)",
			"bundleID": g.bundleID ?? "",
			"path": g.path,
			"cpuPercent": (g.cpu * 1000).rounded() / 10,
			"memoryMB": (Double(g.footprint) / 1_048_576).rounded(),
			"energyWatts": (g.power * 100).rounded() / 100,
			"diskReadBytesPerSec": g.diskRead.rounded(),
			"diskWriteBytesPerSec": g.diskWrite.rounded(),
			"threads": g.threads,
			"processes": g.processes.count,
			"description": d.summary,
			"vendor": d.vendor ?? "",
			"safety": "\(d.safety)",
			"rule": store.rule(for: g)?.summary ?? "",
		]
		if let detail = d.detail { row["detail"] = detail }
		return row
	}

	static func stats(directory: URL, days: Int) -> [String: Any] {
		let s = StatsStore(directory: directory).summary(days: days)
		let apps: [[String: Any]] = s.apps.map { row in
			["key": row.key, "name": row.impact.name, "savedCPUSeconds": row.impact.savedCPUSeconds,
			 "savedEnergyWh": row.impact.savedEnergyJ / 3600, "limitedSeconds": row.impact.limitedSeconds,
			 "heldBackSeconds": row.impact.heldBackSeconds, "frozenSeconds": row.impact.frozenSeconds,
			 "efficiencySeconds": row.impact.efficiencySeconds, "averageWantedCores": row.impact.averageWanted,
			 "averageAllowedCores": row.impact.averageAllowed, "memoryActions": row.impact.memoryActions,
			 "lowMemoryActions": row.impact.lowMemoryActions, "memoryFreedBytes": row.impact.memoryFreedBytes]
		}
		var out: [String: Any] = [
			"days": days, "savedCPUSeconds": s.total.savedCPUSeconds, "savedEnergyWh": s.total.savedEnergyJ / 3600,
			"heldBackSeconds": s.total.heldBackSeconds, "frozenSeconds": s.total.frozenSeconds,
			"efficiencySeconds": s.total.efficiencySeconds, "runawayAlerts": s.runawayAlerts,
			"memoryActions": s.total.memoryActions, "lowMemoryActions": s.total.lowMemoryActions,
			"self": ["cpuSeconds": s.selfCPUSeconds, "uptimeSeconds": s.uptimeSeconds, "averageCPUCores": s.averageSelfCPU,
					 "averageMemoryBytes": s.averageFootprint, "peakMemoryBytes": s.peakFootprint],
			"apps": apps,
			"daily": s.daily.map { ["day": $0.day, "savedCPUSeconds": $0.savedCPUSeconds] },
		]
		if let acc = s.accuracyError { out["limitAccuracy"] = acc }
		if let ratio = s.efficiencyRatio { out["efficiencyRatio"] = ratio }
		if let wh = Battery.capacityWh { out["batteryCapacityWh"] = wh }
		return out
	}

	static func status(store: RuleStore) -> [String: Any] {
		let info = SystemInfo.info
		let sys = SystemState.read()
		var mem = pk_memory_stats()
		pk_memory_stats_get(&mem)
		var out: [String: Any] = [
			"mac": ["chip": SystemInfo.chip, "logicalCores": Int(info.ncpu), "performanceCores": Int(info.pcores),
					"efficiencyCores": Int(info.ecores), "memoryBytes": info.memsize],
			"system": ["onBattery": sys.onBattery, "lowPowerMode": sys.lowPowerMode, "thermalState": sys.thermal,
					   "memoryPressure": sys.memoryPressure == 4 ? "critical" : sys.memoryPressure == 2 ? "warning" : "normal",
					   "memoryUsedBytes": mem.used],
			"activeRules": store.rules.filter(\.isActive).count,
			"dataDirectory": store.fileURL.deletingLastPathComponent().path,
		]
		if let state = AppState.read() {
			out["running"] = true
			out["pid"] = Int(state.pid)
			out["paused"] = state.paused
			out["frozen"] = state.frozen
			out["runaway"] = state.runaway ?? []
			out["autoMode"] = state.auto ?? "off"
		} else {
			out["running"] = false
			out["autoMode"] = UserDefaults.standard.bool(forKey: Prefs.autoEnabled) ? "on" : "off"
		}
		return out
	}

	static func rules(store: RuleStore) -> Any {
		(try? JSONSerialization.jsonObject(with: store.exportData())) ?? []
	}

	static func json(_ object: Any) -> String {
		let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
		return String(decoding: data, as: UTF8.self)
	}
}
