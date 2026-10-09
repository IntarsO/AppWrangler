//
//  AdaptiveTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

/// Adaptive Auto: it follows what the Mac needs right now.
@Suite struct AdaptiveAutoTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func app(_ name: String, pid: pid_t, cpu: Double) -> AppGroup {
		makeGroup(name: name, bundleID: "com.example.\(name.lowercased())", pid: pid, cpu: cpu)
	}

	/// An editor in front and a renderer in the background, decided at `t` seconds.
	private struct Scene {
		let pilot: AutoPilot
		let t0: Date
		let front: AppGroup

		func render(_ t: TimeInterval, cpu: Double = 0.8, system: Double = 0.2, battery: Bool = false,
					lowPower: Bool = false, hot: Bool = false) -> AutoDecision {
			let g = makeGroup(name: "Render", bundleID: "com.example.render", pid: 200, cpu: cpu)
			return pilot.decide(groups: [front, g], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system,
								onBattery: battery, ncpu: 8, lowPower: lowPower, hot: hot, now: t0 + t)[g.id]!
		}
	}

	private func scene(adaptive: Bool = true) -> Scene {
		let p = AutoPilot()
		p.settings.efficiencyAfter = 30
		p.settings.adaptive = adaptive
		return Scene(pilot: p, t0: t0, front: app("Editor", pid: 100, cpu: 0.1))
	}

	@Test func aWorkingBackgroundAppRunsFreeWhenTheMacHasRoom() {
		let s = scene()
		#expect(s.render(0).efficiency == false, "still in the grace period")
		#expect(s.render(31).efficiency == true, "held on the efficiency cores at first")
		#expect(s.render(35).lifted == false, "it must be working for a few seconds first")
		let d = s.render(42)
		#expect(d.lifted && !d.efficiency && d.cap == nil)
		#expect(s.pilot.summary.runningFree == 1)
		#expect(d.label.contains("running free"))
	}

	@Test func aQuietBackgroundAppStaysOnTheEfficiencyCores() {
		let s = scene()
		for t in stride(from: 0.0, through: 120, by: 2) {
			let d = s.render(t, cpu: 0.1)
			#expect(!d.lifted)
		}
	}

	@Test func itGoesBackWhenTheAppHasBeenQuietForAWhile() {
		let s = scene()
		_ = s.render(0)
		_ = s.render(31)
		#expect(s.render(42).lifted)
		#expect(s.render(50, cpu: 0.05).lifted, "a brief lull doesn't take it back")
		#expect(s.render(75, cpu: 0.05).lifted)
		let back = s.render(85, cpu: 0.05)
		#expect(!back.lifted && back.efficiency)
	}

	@Test func onBatteryItNeverRunsFreeAndIsHeldSooner() {
		let s = scene()
		#expect(s.render(0, battery: true).efficiency == false)
		#expect(s.render(11, battery: true).efficiency == true, "10 s instead of 30 s")
		for t in stride(from: 12.0, through: 80, by: 4) { #expect(!s.render(t, battery: true).lifted) }
	}

	@Test func lowPowerModeAndHeatAlsoHoldAppsSooner() {
		for (lowPower, hot) in [(true, false), (false, true)] {
			let s = scene()
			_ = s.render(0, lowPower: lowPower, hot: hot)
			let d = s.render(11, lowPower: lowPower, hot: hot)
			#expect(d.efficiency && !d.lifted)
		}
	}

	@Test func withoutAdaptiveNothingChanges() {
		let s = scene(adaptive: false)
		_ = s.render(0)
		#expect(s.render(11, battery: true).efficiency == false, "30 s grace even on battery")
		_ = s.render(31)
		for t in stride(from: 32.0, through: 120, by: 4) { #expect(!s.render(t).lifted) }
	}

	@Test func aBusyMacTakesItBackAndNothingRunsFreeForTwoMinutes() {
		let s = scene()
		_ = s.render(0)
		_ = s.render(31)
		#expect(s.render(42).lifted)
		// The Mac gets busy: the app is held again.
		_ = s.render(50, system: 0.9)
		let busy = s.render(52, system: 0.9)
		#expect(!busy.lifted && busy.efficiency)
		// It calms down, but the cooldown (2 min since it was last busy) keeps the app held.
		_ = s.render(60, system: 0.2)
		_ = s.render(62, system: 0.2)
		for t in stride(from: 64.0, through: 170, by: 6) { #expect(!s.render(t).lifted) }
		// After the cooldown it has to prove it's working again first, then runs free.
		_ = s.render(181)
		#expect(!s.render(184).lifted)
		#expect(s.render(195).lifted)
	}

	@Test func theAppYouUseIsNeverTouched() {
		let s = scene()
		let editor = s.pilot.decide(groups: [s.front], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.2,
									onBattery: false, ncpu: 8, now: t0 + 60)[s.front.id]
		#expect(editor == AutoDecision(reason: .foreground))
	}
}

/// Memory: Auto acts early (at the first warning), holds while memory is short and resumes apps one at a time.
@Suite struct AdaptiveMemoryTests {
	private func state(_ pressure: Int) -> SystemState { var s = SystemState(); s.memoryPressure = pressure; return s }
	private func idle(_ name: String, pid: pid_t) -> AppGroup {
		makeGroup(name: name, bundleID: "com.example.\(name.lowercased())", pid: pid, footprintMB: 2000)
	}

	@Test func atWarningAutoDoesNothingUnlessItsOwnMeasureSaysSo() {
		let e = Enforcer(controller: FakeController())
		let a = idle("Idle", pid: 100)
		e.apply(makeSnapshot([a], seq: 1), rules: tempStore(), state: state(2), frontmostPid: 1, autoFreeze: [a.id], autoFreezeActive: true)
		#expect(!e.isFrozen(a.id), "the shared threshold is critical")
		e.apply(makeSnapshot([a], seq: 2), rules: tempStore(), state: state(2), frontmostPid: 1, autoFreeze: [a.id], autoFreezeActive: true,
				autoLowMemory: true)
		#expect(e.isFrozen(a.id), "Auto steps in at the first warning")
	}

	@Test func freezesAreHeldWhileMemoryIsStillShortByAutosMeasure() {
		let e = Enforcer(controller: FakeController())
		e.pressureThawDelay = 0
		let a = idle("Idle", pid: 100)
		e.apply(makeSnapshot([a], seq: 1), rules: tempStore(), state: state(2), frontmostPid: 1, autoFreeze: [a.id], autoFreezeActive: true,
				autoLowMemory: true)
		#expect(e.isFrozen(a.id))
		// Still at warning (below the critical threshold): not resumed, so it doesn't freeze and thaw in a loop.
		e.apply(makeSnapshot([a], seq: 2), rules: tempStore(), state: state(2), frontmostPid: 1, autoFreeze: [], autoFreezeActive: true,
				autoLowMemory: true)
		#expect(e.isFrozen(a.id))
		// Memory is fine: resumed.
		e.apply(makeSnapshot([a], seq: 3), rules: tempStore(), state: state(1), frontmostPid: 1, autoFreeze: [], autoFreezeActive: true,
				autoLowMemory: false)
		#expect(!e.isFrozen(a.id))
	}

	@Test func gradualThawResumesOneAppAtATime() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		e.pressureThawDelay = 0
		e.gradualThaw = true
		e.thawGap = 10
		let a = idle("One", pid: 100), b = idle("Two", pid: 200)
		let t0 = Date(timeIntervalSince1970: 1_000_000)
		e.apply(makeSnapshot([a, b], seq: 1), rules: tempStore(), state: state(4), frontmostPid: 1, autoFreeze: [a.id, b.id],
				autoFreezeActive: true, now: t0)
		#expect(e.isFrozen(a.id) && e.isFrozen(b.id))
		e.apply(makeSnapshot([a, b], seq: 2), rules: tempStore(), state: state(1), frontmostPid: 1, autoFreezeActive: true, now: t0 + 1)
		#expect(e.frozen.count == 1, "one resumed")
		e.apply(makeSnapshot([a, b], seq: 3), rules: tempStore(), state: state(1), frontmostPid: 1, autoFreezeActive: true, now: t0 + 5)
		#expect(e.frozen.count == 1, "the next one waits for the gap")
		e.apply(makeSnapshot([a, b], seq: 4), rules: tempStore(), state: state(1), frontmostPid: 1, autoFreezeActive: true, now: t0 + 12)
		#expect(e.frozen.isEmpty)
	}

	@Test func withoutGradualThawEverythingResumesAtOnce() {
		let e = Enforcer(controller: FakeController())
		e.pressureThawDelay = 0
		let a = idle("One", pid: 100), b = idle("Two", pid: 200)
		e.apply(makeSnapshot([a, b], seq: 1), rules: tempStore(), state: state(4), frontmostPid: 1, autoFreeze: [a.id, b.id], autoFreezeActive: true)
		e.apply(makeSnapshot([a, b], seq: 2), rules: tempStore(), state: state(1), frontmostPid: 1, autoFreezeActive: true)
		#expect(e.frozen.isEmpty)
	}
}
