//
//  Stats.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Impact & efficiency statistics: how much CPU (and estimated energy)
//  AppWrangler saved, how long apps were held back / frozen / on E-cores,
//  what actions it took, and what AppWrangler itself cost to run.
//  Kept per day (35 days) in stats.json next to rules.json.
//
//  "Saved" is an estimate: while an app is throttled the limiter measures how
//  much CPU it *would* use if allowed to run (its demand) and how much it
//  actually got; the difference is the saving. A frozen app is credited with
//  the CPU it was using when it was frozen. Energy uses the app's own measured
//  watts per core where available.
//

import Foundation
import IOKit

/// Per-app totals for one day.
struct AppImpact: Codable, Equatable {
	var name: String
	/// Estimated CPU time saved, in core-seconds.
	var savedCPUSeconds: Double = 0
	/// Estimated energy saved, in joules.
	var savedEnergyJ: Double = 0
	/// Time a CPU limit was in force for the app.
	var limitedSeconds: Double = 0
	/// Time the app actually wanted more than its limit (was held back).
	var heldBackSeconds: Double = 0
	/// Integrated demand / allowance while limited (core-seconds), for averages.
	var wantedCoreSeconds: Double = 0
	var allowedCoreSeconds: Double = 0
	var frozenSeconds: Double = 0
	var efficiencySeconds: Double = 0
	/// Energy measured while on efficiency cores, and the estimated energy that
	/// the same work would have cost more on performance cores.
	var efficiencyEnergyJ: Double = 0
	var efficiencySavedJ: Double = 0
	var memoryActions: Int = 0
	var memoryFreedBytes: Double = 0
	var lowMemoryActions: Int = 0

	init(name: String) { self.name = name }

	// Tolerate files written by older versions (missing fields default to 0).
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		func d(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
		savedCPUSeconds = try d(.savedCPUSeconds)
		savedEnergyJ = try d(.savedEnergyJ)
		limitedSeconds = try d(.limitedSeconds)
		heldBackSeconds = try d(.heldBackSeconds)
		wantedCoreSeconds = try d(.wantedCoreSeconds)
		allowedCoreSeconds = try d(.allowedCoreSeconds)
		frozenSeconds = try d(.frozenSeconds)
		efficiencySeconds = try d(.efficiencySeconds)
		efficiencyEnergyJ = try d(.efficiencyEnergyJ)
		efficiencySavedJ = try d(.efficiencySavedJ)
		memoryActions = try c.decodeIfPresent(Int.self, forKey: .memoryActions) ?? 0
		memoryFreedBytes = try d(.memoryFreedBytes)
		lowMemoryActions = try c.decodeIfPresent(Int.self, forKey: .lowMemoryActions) ?? 0
	}

	mutating func add(_ o: AppImpact) {
		savedCPUSeconds += o.savedCPUSeconds
		savedEnergyJ += o.savedEnergyJ
		limitedSeconds += o.limitedSeconds
		heldBackSeconds += o.heldBackSeconds
		wantedCoreSeconds += o.wantedCoreSeconds
		allowedCoreSeconds += o.allowedCoreSeconds
		frozenSeconds += o.frozenSeconds
		efficiencySeconds += o.efficiencySeconds
		efficiencyEnergyJ += o.efficiencyEnergyJ
		efficiencySavedJ += o.efficiencySavedJ
		memoryActions += o.memoryActions
		memoryFreedBytes += o.memoryFreedBytes
		lowMemoryActions += o.lowMemoryActions
	}

	var averageWanted: Double { limitedSeconds > 0 ? wantedCoreSeconds / limitedSeconds : 0 }
	/// Energy saved by limits/freezes plus by efficiency cores (estimates).
	var totalSavedEnergyJ: Double { savedEnergyJ + efficiencySavedJ }
	var averageAllowed: Double { limitedSeconds > 0 ? allowedCoreSeconds / limitedSeconds : 0 }
}

/// How the Mac's memory fared, and what AppWrangler froze because of it.
/// Optional in each bucket, so stats written by older versions still load.
struct MemoryStats: Codable, Equatable {
	/// Time memory pressure was at warning or worse, and at critical.
	var shortSeconds: Double = 0
	var criticalSeconds: Double = 0
	/// Time measured (to put the above in proportion).
	var measuredSeconds: Double = 0
	var swapPeakBytes: Double = 0
	/// Data read back from swap — what memory pressure actually costs you.
	var swapInBytes: Double = 0
	var swapInBytesWhileShort: Double = 0
	/// Apps frozen because of memory (low memory, idle freezing, Free memory now),
	/// how much memory they held then, and how long they stayed frozen (summed).
	var freezes: Int = 0
	var frozenBytes: Double = 0
	var frozenAppSeconds: Double = 0

	mutating func add(_ o: MemoryStats) {
		shortSeconds += o.shortSeconds
		criticalSeconds += o.criticalSeconds
		measuredSeconds += o.measuredSeconds
		swapPeakBytes = max(swapPeakBytes, o.swapPeakBytes)
		swapInBytes += o.swapInBytes
		swapInBytesWhileShort += o.swapInBytesWhileShort
		freezes += o.freezes
		frozenBytes += o.frozenBytes
		frozenAppSeconds += o.frozenAppSeconds
	}

	/// Swap reads per hour of memory shortage — compare days with idle freezing on and off.
	var swapInPerShortHour: Double? { shortSeconds >= 60 ? swapInBytesWhileShort / (shortSeconds / 3600) : nil }
}

/// One measurement of the Mac's memory over a sample interval.
struct MemorySample {
	var pressure: Int			// 1 normal, 2 warning, 4 critical
	var swapUsedBytes: UInt64
	var swapInBytes: Double		// read back from swap during the interval
	var memoryFrozenApps: Int	// apps frozen for memory during the interval
}

struct DayStats: Codable, Equatable {
	var day: String					// yyyy-MM-dd, local time
	var apps: [String: AppImpact] = [:]
	var selfCPUSeconds: Double = 0	// AppWrangler's own CPU time
	var uptimeSeconds: Double = 0	// time AppWrangler was running and measuring
	var selfFootprintSum: Double = 0
	var selfFootprintSamples: Int = 0
	var selfFootprintPeak: Double = 0
	/// Time-weighted |used − limit| / limit while apps were held back.
	var accuracyErrorSum: Double = 0
	var accuracyWeight: Double = 0
	var runawayAlerts: Int = 0
	var memory: MemoryStats?
}

/// What happened to one controlled app during one sample interval.
struct ImpactTick {
	let key: String
	let name: String
	/// Present while a CPU limit is in force: measured usage, estimated demand and the limit (cores).
	var throttle: (usage: Double, demand: Double, limit: Double)?
	/// Present while frozen: the CPU it was using when it was frozen (cores).
	var frozenDemand: Double?
	var efficiency = false
	/// Current measured usage and power, used to learn the app's watts per core.
	var cpu: Double = 0
	var power: Double = 0
}

struct ImpactSummary {
	var days: Int
	var total = AppImpact(name: "")
	var apps: [(key: String, impact: AppImpact)] = []
	var selfCPUSeconds: Double = 0
	var uptimeSeconds: Double = 0
	var averageFootprint: Double = 0
	var peakFootprint: Double = 0
	var accuracyError: Double?		// e.g. 0.02 = limits held within ±2 %
	var runawayAlerts = 0
	var daily: [(day: String, savedCPUSeconds: Double)] = []
	var memory = MemoryStats()

	/// AppWrangler's average CPU use while running, in cores.
	var averageSelfCPU: Double { uptimeSeconds > 0 ? selfCPUSeconds / uptimeSeconds : 0 }
	/// How many core-seconds were saved per core-second AppWrangler spent.
	var efficiencyRatio: Double? { selfCPUSeconds > 0.5 && total.savedCPUSeconds > 0 ? total.savedCPUSeconds / selfCPUSeconds : nil }
}

final class StatsStore: ObservableObject {
	/// Bumped whenever numbers change, so views refresh.
	@Published private(set) var revision = 0

	let fileURL: URL
	private(set) var days: [DayStats] = []
	/// Hourly buckets for the last 48 hours ("last hour" view).
	private(set) var hours: [DayStats] = []
	private var wattsPerCore: [String: Double] = [:]
	private let calendar: Calendar
	private let keepDays = 35
	private var dirty = false
	private let formatter: DateFormatter
	private let hourFormatter: DateFormatter
	private let keepHours = 48

	/// Typical Apple Silicon P-core draw, used until an app's own ratio is measured.
	static let defaultWattsPerCore = 1.5
	/// Energy for the same work on performance cores ÷ on efficiency cores.
	/// Measured on an M1 with a fixed CPU workload: 5.3 J vs 1.16 J (≈ 4.6×).
	/// Real apps vary, so energy saved by efficiency cores is an estimate.
	static let efficiencyCoreEnergyFactor = 4.5

	init(directory: URL = DataDirectory.url, calendar: Calendar = .current) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		fileURL = directory.appendingPathComponent("stats.json")
		self.calendar = calendar
		formatter = DateFormatter()
		formatter.calendar = calendar
		formatter.timeZone = calendar.timeZone
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		hourFormatter = DateFormatter()
		hourFormatter.calendar = calendar
		hourFormatter.timeZone = calendar.timeZone
		hourFormatter.locale = Locale(identifier: "en_US_POSIX")
		hourFormatter.dateFormat = "yyyy-MM-dd'T'HH"
		load()
	}

	// MARK: Recording

	private func hourIndex(for date: Date) -> Int {
		let key = hourFormatter.string(from: date)
		if let i = hours.lastIndex(where: { $0.day == key }) { return i }
		hours.append(DayStats(day: key))
		hours.sort { $0.day < $1.day }
		if hours.count > keepHours { hours.removeFirst(hours.count - keepHours) }
		return hours.lastIndex(where: { $0.day == key })!
	}

	private func dayIndex(for date: Date) -> Int {
		let key = formatter.string(from: date)
		if let i = days.lastIndex(where: { $0.day == key }) { return i }
		days.append(DayStats(day: key))
		days.sort { $0.day < $1.day }
		if days.count > keepDays { days.removeFirst(days.count - keepDays) }
		return days.lastIndex(where: { $0.day == key })!
	}

	/// Record one sample interval of `dt` seconds (into the day and the hour).
	func record(_ ticks: [ImpactTick], selfCPU: Double, selfFootprint: UInt64, dt: TimeInterval, at date: Date = Date(), ncpu: Int = SystemInfo.ncpu,
				memory: MemorySample? = nil) {
		guard dt > 0 else { return }
		// Learn each app's watts per core from live measurements (once per sample).
		for t in ticks where t.cpu > 0.05 && t.power > 0 {
			let ratio = min(max(t.power / t.cpu, 0.1), 10)
			wattsPerCore[t.key] = (wattsPerCore[t.key] ?? ratio) * 0.8 + ratio * 0.2
		}
		let d = dayIndex(for: date)
		days[d] = Self.add(ticks, to: days[d], selfCPU: selfCPU, selfFootprint: selfFootprint, dt: dt, ncpu: ncpu, wattsPerCore: wattsPerCore)
		let h = hourIndex(for: date)
		hours[h] = Self.add(ticks, to: hours[h], selfCPU: selfCPU, selfFootprint: selfFootprint, dt: dt, ncpu: ncpu, wattsPerCore: wattsPerCore)
		if let memory {
			Self.add(memory, dt: dt, to: &days[d])
			Self.add(memory, dt: dt, to: &hours[h])
		}
		changed()
	}

	private static func add(_ m: MemorySample, dt: TimeInterval, to bucket: inout DayStats) {
		var s = bucket.memory ?? MemoryStats()
		let short = m.pressure >= 2
		s.measuredSeconds += dt
		if short { s.shortSeconds += dt }
		if m.pressure >= 4 { s.criticalSeconds += dt }
		s.swapPeakBytes = max(s.swapPeakBytes, Double(m.swapUsedBytes))
		s.swapInBytes += max(0, m.swapInBytes)
		if short { s.swapInBytesWhileShort += max(0, m.swapInBytes) }
		s.frozenAppSeconds += Double(max(0, m.memoryFrozenApps)) * dt
		bucket.memory = s
	}

	private static func add(_ ticks: [ImpactTick], to bucket: DayStats, selfCPU: Double, selfFootprint: UInt64, dt: TimeInterval,
							ncpu: Int, wattsPerCore: [String: Double]) -> DayStats {
		var day = bucket
		day.uptimeSeconds += dt
		day.selfCPUSeconds += max(0, selfCPU) * dt
		let fp = Double(selfFootprint)
		if fp > 0 {
			day.selfFootprintSum += fp
			day.selfFootprintSamples += 1
			day.selfFootprintPeak = max(day.selfFootprintPeak, fp)
		}
		for t in ticks {
			let wpc = wattsPerCore[t.key] ?? Self.defaultWattsPerCore
			var a = day.apps[t.key] ?? AppImpact(name: t.name)
			a.name = t.name
			if let th = t.throttle {
				let demand = min(max(th.demand, 0), Double(ncpu))
				let usage = max(th.usage, 0)
				let saved = max(0, demand - usage) * dt
				a.limitedSeconds += dt
				a.wantedCoreSeconds += demand * dt
				a.allowedCoreSeconds += usage * dt
				a.savedCPUSeconds += saved
				a.savedEnergyJ += saved * wpc
				if demand > th.limit * 1.05 && th.limit > 0 {
					a.heldBackSeconds += dt
					day.accuracyErrorSum += abs(usage - th.limit) / th.limit * dt
					day.accuracyWeight += dt
				}
			}
			if let fd = t.frozenDemand {
				a.frozenSeconds += dt
				let saved = max(0, min(fd, Double(ncpu))) * dt
				a.savedCPUSeconds += saved
				a.savedEnergyJ += saved * wpc
			}
			if t.efficiency {
				a.efficiencySeconds += dt
				let used = max(t.power, 0) * dt
				a.efficiencyEnergyJ += used
				a.efficiencySavedJ += used * (Self.efficiencyCoreEnergyFactor - 1)
			}
			day.apps[t.key] = a
		}
		return day
	}

	enum Event {
		case memoryAction(freedBytes: Double)
		case lowMemoryAction
		case runawayAlert
		/// An app frozen because of memory, and the memory it held.
		case memoryFreeze(bytes: Double)
	}

	func record(_ event: Event, key: String, name: String, at date: Date = Date()) {
		func apply(_ b: inout DayStats) {
			switch event {
			case .runawayAlert:
				b.runawayAlerts += 1
			case .memoryAction(let freed):
				var a = b.apps[key] ?? AppImpact(name: name)
				a.memoryActions += 1
				a.memoryFreedBytes += freed
				b.apps[key] = a
			case .lowMemoryAction:
				var a = b.apps[key] ?? AppImpact(name: name)
				a.lowMemoryActions += 1
				b.apps[key] = a
			case .memoryFreeze(let bytes):
				var m = b.memory ?? MemoryStats()
				m.freezes += 1
				m.frozenBytes += max(0, bytes)
				b.memory = m
			}
		}
		let d = dayIndex(for: date)
		apply(&days[d])
		let h = hourIndex(for: date)
		apply(&hours[h])
		changed()
	}

	private func changed() {
		dirty = true
		revision &+= 1
	}

	// MARK: Reading

	/// Totals for the last `hours` clock hours including the current one.
	func summary(hours count: Int, now: Date = Date()) -> ImpactSummary {
		let start = calendar.date(byAdding: .hour, value: -(count - 1), to: now)!
		let first = hourFormatter.string(from: start), last = hourFormatter.string(from: now)
		var s = ImpactSummary(days: 0)
		Self.accumulate(hours.filter { $0.day >= first && $0.day <= last }, into: &s)
		return s
	}

	private static func accumulate(_ buckets: [DayStats], into s: inout ImpactSummary) {
		var perApp: [String: AppImpact] = [:]
		var footprintSum = 0.0, footprintSamples = 0, accSum = 0.0, accWeight = 0.0
		for d in buckets {
			for (key, impact) in d.apps {
				var a = perApp[key] ?? AppImpact(name: impact.name)
				a.name = impact.name
				a.add(impact)
				perApp[key] = a
				s.total.add(impact)
			}
			s.selfCPUSeconds += d.selfCPUSeconds
			s.uptimeSeconds += d.uptimeSeconds
			footprintSum += d.selfFootprintSum
			footprintSamples += d.selfFootprintSamples
			s.peakFootprint = max(s.peakFootprint, d.selfFootprintPeak)
			accSum += d.accuracyErrorSum
			accWeight += d.accuracyWeight
			s.runawayAlerts += d.runawayAlerts
			if let m = d.memory { s.memory.add(m) }
		}
		s.averageFootprint = footprintSamples > 0 ? footprintSum / Double(footprintSamples) : 0
		s.accuracyError = accWeight > 30 ? accSum / accWeight : nil
		s.apps = perApp.map { ($0.key, $0.value) }.sorted {
			$0.impact.totalSavedEnergyJ != $1.impact.totalSavedEnergyJ
				? $0.impact.totalSavedEnergyJ > $1.impact.totalSavedEnergyJ
				: $0.impact.name.localizedCaseInsensitiveCompare($1.impact.name) == .orderedAscending
		}
	}

	/// Totals for the last `days` calendar days including today (1 = today).
	func summary(days count: Int, now: Date = Date()) -> ImpactSummary {
		var s = ImpactSummary(days: count)
		let start = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now))!
		let first = formatter.string(from: start), last = formatter.string(from: now)
		let inRange = days.filter { $0.day >= first && $0.day <= last }
		Self.accumulate(inRange, into: &s)
		var dailyMap: [String: Double] = [:]
		for d in inRange { dailyMap[d.day] = d.apps.values.reduce(0) { $0 + $1.savedCPUSeconds } }
		var cursor = start
		for _ in 0..<count {
			let key = formatter.string(from: cursor)
			s.daily.append((key, dailyMap[key] ?? 0))
			cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
		}
		return s
	}

	// MARK: Persistence

	private struct File: Codable {
		var version = 1
		var days: [DayStats]
		var hours: [DayStats]?
		var wattsPerCore: [String: Double]?
	}

	private func load() {
		guard let data = try? Data(contentsOf: fileURL),
			  let file = try? JSONDecoder().decode(File.self, from: data) else { return }
		days = file.days.sorted { $0.day < $1.day }.suffix(keepDays)
		hours = (file.hours ?? []).sorted { $0.day < $1.day }.suffix(keepHours)
		wattsPerCore = file.wattsPerCore ?? [:]
	}

	/// Re-read from disk (the CLI reads what the running app wrote).
	func reload() {
		load()
		revision &+= 1
	}

	func flush() {
		guard dirty else { return }
		dirty = false
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		if let data = try? encoder.encode(File(days: days, hours: hours, wattsPerCore: wattsPerCore)) {
			try? data.write(to: fileURL, options: .atomic)
		}
	}

	func reset() {
		days.removeAll()
		hours.removeAll()
		wattsPerCore.removeAll()
		dirty = true
		flush()
		revision &+= 1
	}
}

/// Stable identity for statistics: survives relaunches (unlike pid-based group ids).
enum ImpactKey {
	static func of(_ group: AppGroup) -> String {
		if let b = group.bundleID { return "bundle:" + b }
		if !group.path.isEmpty { return "path:" + group.path }
		return "name:" + group.name
	}
}

enum Battery {
	/// Full-charge capacity of the internal battery in watt-hours, if there is one.
	static let capacityWh: Double? = {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
		guard service != 0 else { return nil }
		defer { IOObjectRelease(service) }
		func number(_ key: String) -> Double? {
			(IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue() as? NSNumber)?.doubleValue
		}
		guard let mAh = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") ?? number("MaxCapacity"),
			  let mV = number("Voltage"), mAh > 100, mV > 1000 else { return nil }
		return mAh * mV / 1_000_000
	}()
}
