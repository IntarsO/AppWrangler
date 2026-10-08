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
	/// Measure everything running for `seconds` (rates need two samples).
	static func sampleGroups(apps: [RunningApp], seconds: Double = 1) -> [AppGroup] {
		let appMap = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
		let sampler = Sampler()
		let request = SampleRequest(apps: appMap, includeAll: true, includeOtherUsers: false, withThreads: true, matcher: GroupMatcher())
		_ = sampler.sampleNow(request)
		usleep(useconds_t(max(0.2, seconds) * 1_000_000))
		return sampler.sampleNow(request).groups
	}

	/// Measure running apps for `seconds` and describe each one.
	static func apps(store: RuleStore, apps: [RunningApp], includeProcesses: Bool, limit: Int? = nil,
					 seconds: Double = 1) -> [[String: Any]] {
		var groups = sampleGroups(apps: apps, seconds: seconds).filter { includeProcesses || $0.kind != .process }
		groups.sort { $0.cpu > $1.cpu }
		if let limit { groups = Array(groups.prefix(max(0, limit))) }
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

	/// `days` = 0 means the last hour.
	static func stats(directory: URL, days: Int) -> [String: Any] {
		let store = StatsStore(directory: directory)
		let s = days == 0 ? store.summary(hours: 1) : store.summary(days: days)
		let apps: [[String: Any]] = s.apps.map { row in
			["key": row.key, "name": row.impact.name, "savedCPUSeconds": row.impact.savedCPUSeconds,
			 "savedEnergyWh": row.impact.totalSavedEnergyJ / 3600, "efficiencySavedWh": row.impact.efficiencySavedJ / 3600,
			 "limitedSeconds": row.impact.limitedSeconds,
			 "heldBackSeconds": row.impact.heldBackSeconds, "frozenSeconds": row.impact.frozenSeconds,
			 "efficiencySeconds": row.impact.efficiencySeconds, "averageWantedCores": row.impact.averageWanted,
			 "averageAllowedCores": row.impact.averageAllowed, "memoryActions": row.impact.memoryActions,
			 "lowMemoryActions": row.impact.lowMemoryActions, "memoryFreedBytes": row.impact.memoryFreedBytes]
		}
		var out: [String: Any] = [
			"period": days == 0 ? "hour" : days == 1 ? "today" : "\(days) days",
			"days": days, "savedCPUSeconds": s.total.savedCPUSeconds, "savedEnergyWh": s.total.totalSavedEnergyJ / 3600,
			"efficiencySavedWh": s.total.efficiencySavedJ / 3600, "throttleSavedWh": s.total.savedEnergyJ / 3600,
			"heldBackSeconds": s.total.heldBackSeconds, "frozenSeconds": s.total.frozenSeconds,
			"efficiencySeconds": s.total.efficiencySeconds, "runawayAlerts": s.runawayAlerts,
			"memoryActions": s.total.memoryActions, "lowMemoryActions": s.total.lowMemoryActions,
			"self": ["cpuSeconds": s.selfCPUSeconds, "uptimeSeconds": s.uptimeSeconds, "averageCPUCores": s.averageSelfCPU,
					 "averageMemoryBytes": s.averageFootprint, "peakMemoryBytes": s.peakFootprint],
			"apps": apps,
			"daily": s.daily.map { ["day": $0.day, "savedCPUSeconds": $0.savedCPUSeconds] },
		]
		let m = s.memory
		var memory: [String: Any] = [
			"measuredSeconds": m.measuredSeconds, "shortOfMemorySeconds": m.shortSeconds, "criticalSeconds": m.criticalSeconds,
			"swapPeakBytes": m.swapPeakBytes, "swapReadBytes": m.swapInBytes, "swapReadBytesWhileShort": m.swapInBytesWhileShort,
			"appsFrozenForMemory": m.freezes, "memoryHeldByFrozenAppsBytes": m.frozenBytes, "frozenForMemoryAppSeconds": m.frozenAppSeconds,
		]
		if let perHour = m.swapInPerShortHour { memory["swapReadBytesPerShortHour"] = perHour }
		out["memory"] = memory
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
			out["autoApps"] = state.autoApps ?? [:]
		} else {
			out["running"] = false
			out["autoMode"] = UserDefaults.standard.bool(forKey: Prefs.autoEnabled) ? "on" : "off"
		}
		let d = UserDefaults.standard
		out["autoFreezeIdleApps"] = ["enabled": d.bool(forKey: Prefs.autoFreezeIdle), "idleMinutes": d.integer(forKey: Prefs.autoFreezeIdleMinutes),
									 "atMemoryPressure": d.integer(forKey: Prefs.pressureLevel) >= 4 ? "critical" : "warning"]
		if let last = ChangeJournal.entries(directory: store.fileURL.deletingLastPathComponent()).last {
			out["lastChange"] = ["app": last.app, "source": last.source, "date": ISO8601DateFormatter().string(from: last.date),
								 "now": last.after?.summary ?? "rule removed"]
		}
		return out
	}

	/// The running group a user-supplied name refers to: exact name or bundle id
	/// first, then a name containing it (apps before processes, biggest first).
	static func findGroup(_ target: String, in groups: [AppGroup]) -> AppGroup? {
		let t = target.trimmingCharacters(in: .whitespaces).lowercased()
		guard !t.isEmpty else { return nil }
		if let exact = groups.first(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t || $0.path.lowercased() == t }) {
			return exact
		}
		let partial = partialMatches(t, in: groups)
		return partial.count == 1 ? partial[0] : nil
	}

	/// Running apps (not plain processes, unless nothing else matches) whose name contains `t`.
	static func partialMatches(_ target: String, in groups: [AppGroup]) -> [AppGroup] {
		let t = target.trimmingCharacters(in: .whitespaces).lowercased()
		let all = groups.filter { $0.name.lowercased().contains(t) }
		let apps = all.filter { $0.kind != .process }
		return apps.isEmpty ? all : apps
	}

	/// "No such app", or the candidates when the name is ambiguous.
	static func notFound(_ target: String, in groups: [AppGroup]) -> String {
		let names = partialMatches(target, in: groups).map(\.name)
		return names.count > 1 ? "\"\(target)\" matches several: \(names.prefix(8).joined(separator: ", ")). Use the full name."
			: "\(target) isn't running and has no rule"
	}

	/// Everything about one app: what it is, live usage, every setting (with the
	/// keys `configure_app` / `appwrangler set` take), who manages it, and suggestions.
	static func appSettings(_ target: String, store: RuleStore, apps: [RunningApp], input: SuggestionInput) -> [String: Any]? {
		let group = findGroup(target, in: input.groups)
		let rule = group.flatMap { store.rule(for: $0) } ?? RuleTargets.resolve(target, store: store, apps: apps, create: false)
		guard group != nil || rule != nil else { return nil }
		let name = group?.name ?? rule?.displayName ?? target
		let managed = AppSettings.managedBy(group, rule: rule, autoEnabled: input.autoEnabled)
		var out: [String: Any] = [
			"app": name,
			"running": group != nil,
			"rule": rule?.summary ?? "no rule",
			"settings": AppSettings.settings(rule),
			"managedBy": managed,
			"managedByMeaning": AppSettings.managedByHelp[managed] ?? "",
			"suggestions": Suggestions.make(input, app: name).map(\.json),
			"settingKeys": Dictionary(uniqueKeysWithValues: RuleChanges.keys.map { ($0.key, $0.help) }),
		]
		if let rule { out["matchedBy"] = "\(rule.matchKind.rawValue): \(rule.matchValue)" }
		if let group { out["usage"] = Self.group(store: store, group) }
		if let auto = AppState.read()?.autoApps?[name] { out["autoState"] = auto }
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
