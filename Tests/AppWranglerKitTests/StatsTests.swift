//
//  StatsTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct StatsTests {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerStats-\(UUID().uuidString)")
	let noon = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 8, hour: 12).date!

	private func store() -> StatsStore { StatsStore(directory: dir, calendar: Calendar(identifier: .gregorian)) }

	private func throttled(_ key: String = "bundle:x", usage: Double, demand: Double, limit: Double, cpu: Double = 0, power: Double = 0) -> ImpactTick {
		var t = ImpactTick(key: key, name: "X")
		t.throttle = (usage, demand, limit)
		t.cpu = cpu
		t.power = power
		return t
	}

	@Test func throttlingCreditsDemandMinusUsage() {
		let s = store()
		// Wanted 2 cores, allowed 0.5, for 10 s → 15 core-seconds saved.
		s.record([throttled(usage: 0.5, demand: 2, limit: 0.5)], selfCPU: 0.002, selfFootprint: 50_000_000, dt: 10, at: noon, ncpu: 8)
		let sum = s.summary(days: 1, now: noon)
		#expect(abs(sum.total.savedCPUSeconds - 15) < 0.001)
		#expect(sum.total.heldBackSeconds == 10)
		#expect(abs(sum.total.averageWanted - 2) < 0.001)
		#expect(abs(sum.total.averageAllowed - 0.5) < 0.001)
		#expect(abs(sum.selfCPUSeconds - 0.02) < 0.0001)
		#expect(sum.uptimeSeconds == 10)
	}

	@Test func appUnderItsLimitSavesNothing() {
		let s = store()
		s.record([throttled(usage: 0.1, demand: 0.1, limit: 0.5)], selfCPU: 0, selfFootprint: 0, dt: 10, at: noon)
		let sum = s.summary(days: 1, now: noon)
		#expect(sum.total.savedCPUSeconds == 0)
		#expect(sum.total.heldBackSeconds == 0, "not held back if it didn't want more")
		#expect(sum.total.limitedSeconds == 10)
	}

	@Test func demandIsCappedAtCoreCount() {
		let s = store()
		s.record([throttled(usage: 0.5, demand: 50, limit: 0.5)], selfCPU: 0, selfFootprint: 0, dt: 1, at: noon, ncpu: 8)
		#expect(abs(s.summary(days: 1, now: noon).total.savedCPUSeconds - 7.5) < 0.001)
	}

	@Test func frozenAppsAreCreditedWithPreFreezeUsage() {
		let s = store()
		var t = ImpactTick(key: "bundle:y", name: "Y")
		t.frozenDemand = 1.2
		s.record([t], selfCPU: 0, selfFootprint: 0, dt: 5, at: noon)
		let sum = s.summary(days: 1, now: noon)
		#expect(abs(sum.total.savedCPUSeconds - 6) < 0.001)
		#expect(sum.total.frozenSeconds == 5)
	}

	@Test func energyUsesTheAppsMeasuredWattsPerCore() {
		let s = store()
		// The app draws 3 W at 1 core → 3 W/core; 10 core-seconds saved ≈ 30 J.
		s.record([throttled(usage: 1, demand: 2, limit: 1, cpu: 1, power: 3)], selfCPU: 0, selfFootprint: 0, dt: 10, at: noon)
		#expect(abs(s.summary(days: 1, now: noon).total.savedEnergyJ - 30) < 0.5)
	}

	@Test func energyFallsBackToDefaultRatio() {
		let s = store()
		s.record([throttled(usage: 0, demand: 1, limit: 0.1)], selfCPU: 0, selfFootprint: 0, dt: 10, at: noon)
		#expect(abs(s.summary(days: 1, now: noon).total.savedEnergyJ - 10 * StatsStore.defaultWattsPerCore) < 0.001)
	}

	@Test func accuracyMeasuresDistanceFromLimit() {
		let s = store()
		s.record([throttled(usage: 0.52, demand: 2, limit: 0.5)], selfCPU: 0, selfFootprint: 0, dt: 60, at: noon)
		let acc = s.summary(days: 1, now: noon).accuracyError
		#expect(acc != nil && abs(acc! - 0.04) < 0.0001)
	}

	@Test func efficiencyRatioComparesSavedToSpent() {
		let s = store()
		s.record([throttled(usage: 0.5, demand: 1.5, limit: 0.5)], selfCPU: 0.001, selfFootprint: 0, dt: 1000, at: noon)
		// saved 1000 core-s, spent 1 core-s → 1000×
		#expect(abs((s.summary(days: 1, now: noon).efficiencyRatio ?? 0) - 1000) < 0.01)
	}

	@Test func eventsAreCounted() {
		let s = store()
		s.record(.memoryAction(freedBytes: 400_000_000), key: "bundle:z", name: "Z", at: noon)
		s.record(.lowMemoryAction, key: "bundle:z", name: "Z", at: noon)
		s.record(.runawayAlert, key: "bundle:q", name: "Q", at: noon)
		let sum = s.summary(days: 1, now: noon)
		#expect(sum.total.memoryActions == 1)
		#expect(sum.total.memoryFreedBytes == 400_000_000)
		#expect(sum.total.lowMemoryActions == 1)
		#expect(sum.runawayAlerts == 1)
	}

	@Test func daysAreBucketedAndSummarised() {
		let s = store()
		let cal = Calendar(identifier: .gregorian)
		for back in 0..<10 {
			let day = cal.date(byAdding: .day, value: -back, to: noon)!
			s.record([throttled(usage: 0, demand: 1, limit: 0.1)], selfCPU: 0, selfFootprint: 0, dt: 60, at: day)
		}
		#expect(abs(s.summary(days: 1, now: noon).total.savedCPUSeconds - 60) < 0.001)
		let week = s.summary(days: 7, now: noon)
		#expect(abs(week.total.savedCPUSeconds - 420) < 0.001)
		#expect(week.daily.count == 7)
		#expect(week.daily.last?.day == "2026-10-08")
		#expect(s.summary(days: 30, now: noon).daily.count == 30)
	}

	@Test func persistsAcrossRestartsAndResets() {
		let a = store()
		a.record([throttled(usage: 0.5, demand: 1.5, limit: 0.5)], selfCPU: 0, selfFootprint: 0, dt: 10, at: noon)
		a.flush()
		let b = store()
		#expect(abs(b.summary(days: 1, now: noon).total.savedCPUSeconds - 10) < 0.001)
		b.reset()
		#expect(store().summary(days: 1, now: noon).total.savedCPUSeconds == 0)
	}

	@Test func perAppRowsAreSortedBySavings() {
		let s = store()
		s.record([throttled("bundle:a", usage: 0.5, demand: 1, limit: 0.5),
				  throttled("bundle:b", usage: 0.5, demand: 3, limit: 0.5)], selfCPU: 0, selfFootprint: 0, dt: 10, at: noon)
		#expect(s.summary(days: 1, now: noon).apps.map(\.key) == ["bundle:b", "bundle:a"])
	}

	@Test func efficiencyCoresAreCreditedWithEnergySaved() {
		let s = store()
		var t = ImpactTick(key: "bundle:slack", name: "Slack")
		t.efficiency = true
		t.power = 0.1		// 0.1 W measured on the E-cores
		s.record([t], selfCPU: 0, selfFootprint: 0, dt: 100, at: noon)
		let sum = s.summary(days: 1, now: noon)
		#expect(abs(sum.total.efficiencyEnergyJ - 10) < 0.001)
		#expect(abs(sum.total.efficiencySavedJ - 10 * (StatsStore.efficiencyCoreEnergyFactor - 1)) < 0.001)
		#expect(abs(sum.total.totalSavedEnergyJ - sum.total.efficiencySavedJ) < 0.001)
	}

	@Test func lastHourOnlyCountsTheCurrentHour() {
		let s = store()
		s.record([throttled(usage: 0, demand: 1, limit: 0.1)], selfCPU: 0, selfFootprint: 0, dt: 60, at: noon - 3 * 3600)
		s.record([throttled(usage: 0, demand: 1, limit: 0.1)], selfCPU: 0, selfFootprint: 0, dt: 30, at: noon)
		#expect(abs(s.summary(hours: 1, now: noon).total.savedCPUSeconds - 30) < 0.001)
		#expect(abs(s.summary(days: 1, now: noon).total.savedCPUSeconds - 90) < 0.001)
	}

	@Test func readsStatsWrittenByTheEarlierVersion() throws {
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let old = #"{"version":1,"days":[{"day":"2026-10-08","apps":{"bundle:x":{"name":"X","savedCPUSeconds":42,"savedEnergyJ":1,"limitedSeconds":1,"heldBackSeconds":1,"wantedCoreSeconds":1,"allowedCoreSeconds":1,"frozenSeconds":0,"efficiencySeconds":5,"memoryActions":0,"memoryFreedBytes":0,"lowMemoryActions":0}},"selfCPUSeconds":1,"uptimeSeconds":10,"selfFootprintSum":0,"selfFootprintSamples":0,"selfFootprintPeak":0,"accuracyErrorSum":0,"accuracyWeight":0,"runawayAlerts":0}]}"#
		try Data(old.utf8).write(to: dir.appendingPathComponent("stats.json"))
		#expect(store().summary(days: 1, now: noon).total.savedCPUSeconds == 42, "old data kept, not discarded")
	}

	@Test func formatting() {
		#expect(Fmt.coreTime(30) == "30 core-s")
		#expect(Fmt.coreTime(600) == "10 core-min")
		#expect(Fmt.coreTime(9000) == "2.5 core-h")
		#expect(Fmt.energy(3600) == "1.0 Wh")
		#expect(Fmt.energy(360) == "100 mWh")
	}
}
