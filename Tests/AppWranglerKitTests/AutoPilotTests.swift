//
//  AutoPilotTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct AutoPilotTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func app(_ name: String, pid: pid_t, cpu: Double = 0.1, helpers: [pid_t] = []) -> AppGroup {
		makeGroup(name: name, bundleID: "com.example.\(name.lowercased())", pid: pid, helpers: helpers, cpu: cpu)
	}

	private func pilot() -> AutoPilot {
		let p = AutoPilot()
		p.settings.efficiencyAfter = 30
		p.settings.focusGrace = 15
		return p
	}

	@Test func focusedAppRunsFreeAndOthersMoveToEfficiencyAfterTheGrace() {
		let p = pilot()
		let slack = app("Slack", pid: 100), mail = app("Mail", pid: 200)
		var d = p.decide(groups: [slack, mail], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: false, ncpu: 8, now: t0)
		#expect(d[slack.id] == AutoDecision(reason: .foreground))
		#expect(d[mail.id]?.efficiency == false, "not yet: background for 0 s")
		d = p.decide(groups: [slack, mail], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: false, ncpu: 8, now: t0 + 31)
		#expect(d[mail.id]?.efficiency == true)
		#expect(d[mail.id]?.cap == nil, "Mac not busy → no caps")
		#expect(d[slack.id]?.efficiency == false)
	}

	@Test func recentlyUsedAppKeepsFullSpeedDuringGrace() {
		let p = pilot()
		let a = app("A", pid: 100)
		let d = p.decide(groups: [a], frontmostPid: 999, lastActive: [100: t0 - 5], audioPids: [], systemCPU: 0.9, onBattery: false, ncpu: 8, now: t0)
		#expect(d[a.id]?.reason == .recent)
		#expect(d[a.id]?.efficiency == false && d[a.id]?.cap == nil)
	}

	@Test func appsUsingAudioAreTreatedAsInUse() {
		let p = pilot()
		// Whispr dictating: its helper process holds the microphone.
		let whispr = app("Whispr", pid: 300, helpers: [301])
		_ = p.decide(groups: [whispr], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.9, onBattery: false, ncpu: 8, now: t0)
		let d = p.decide(groups: [whispr], frontmostPid: 1, lastActive: [:], audioPids: [301], systemCPU: 0.9, onBattery: false, ncpu: 8, now: t0 + 60)
		#expect(d[whispr.id] == AutoDecision(reason: .audio))
	}

	@Test func switchingToAnAppRestoresItImmediately() {
		let p = pilot()
		let mail = app("Mail", pid: 200)
		_ = p.decide(groups: [mail], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: false, ncpu: 8, now: t0)
		let bg = p.decide(groups: [mail], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: false, ncpu: 8, now: t0 + 40)
		#expect(bg[mail.id]?.efficiency == true)
		let fg = p.refocus(frontmostPid: 200, lastActive: [:])
		#expect(fg[mail.id] == AutoDecision(reason: .foreground))
		let left = p.refocus(frontmostPid: 1, lastActive: [200: Date()])
		#expect(left[mail.id]?.reason == .recent, "leaving it keeps full speed for the grace period")
	}

	@Test func busyNeedsTwoSamplesAndCalmsWithHysteresis() {
		let p = pilot()
		let hog = app("Hog", pid: 400, cpu: 4)
		func step(_ cpu: Double, _ s: TimeInterval) -> Bool {
			_ = p.decide(groups: [hog], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: cpu, onBattery: false, ncpu: 8, now: t0 + s)
			return p.busy
		}
		#expect(!step(0.9, 0), "one busy sample isn't enough")
		#expect(step(0.9, 2), "two busy samples → busy")
		#expect(step(0.7, 4), "still busy until clearly calm")
		#expect(step(0.5, 6))
		#expect(!step(0.5, 8), "two calm samples → not busy")
	}

	@Test func aBusyMacCapsTheHogOnlyWhenOthersNeedTheCPU() {
		let p = pilot()
		let hog = app("Hog", pid: 400, cpu: 4)
		func cap(_ cpu: Double, _ s: TimeInterval) -> Double? {
			p.decide(groups: [hog], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: cpu, onBattery: false, ncpu: 8, now: t0 + s)[hog.id]?.cap
		}
		_ = cap(0.8, 0)
		// 6.4 cores in use, 4 by the hog: others need 2.4 → hog may keep 8 − 2.4 − 1 = 4.6 → no cap needed.
		#expect(cap(0.8, 2) == nil)
		// 7.6 in use: others need 3.6 → hog gets 3.4 of the 4 it wants.
		let c = cap(0.95, 4)
		#expect(c != nil && abs(c! - 3.4) < 0.01)
	}

	@Test func batteryLowersTheBusyThreshold() {
		let p = pilot()
		let hog = app("Hog", pid: 400, cpu: 3)
		_ = p.decide(groups: [hog], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.55, onBattery: true, ncpu: 8, now: t0)
		_ = p.decide(groups: [hog], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.55, onBattery: true, ncpu: 8, now: t0 + 2)
		#expect(p.busy, "55 % counts as busy on battery (threshold 50 %), not on AC (75 %)")
	}

	@Test func busyMacSharesWhatTheForegroundLeavesFairly() {
		let p = pilot()
		// 8 cores: foreground uses 3, three background apps want 4, 1 and 0.1 cores.
		let fg = app("Editor", pid: 100, cpu: 3)
		let big = app("Big", pid: 200, cpu: 4), mid = app("Mid", pid: 300, cpu: 1), small = app("Small", pid: 400, cpu: 0.1)
		let groups = [fg, big, mid, small]
		let total = (3 + 4 + 1 + 0.1) / 8
		_ = p.decide(groups: groups, frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: total, onBattery: false, ncpu: 8, now: t0)
		let d = p.decide(groups: groups, frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: total, onBattery: false, ncpu: 8, now: t0 + 2)
		// Budget = 8 − 3 (foreground) − 1 (headroom) = 4 cores for background.
		#expect(d[fg.id]?.cap == nil)
		#expect(d[small.id]?.cap == nil, "light apps keep what they use")
		#expect(d[mid.id]?.cap == nil, "1 core fits within an equal share")
		let bigCap = d[big.id]?.cap ?? 0
		#expect(abs(bigCap - 2.9) < 0.01, "the heavy app gets the rest: 4 − 1 − 0.1")
	}

	@Test func fairShareKeepsAFloor() {
		let caps = AutoPilot.fairShare([("a", 3), ("b", 3), ("c", 3)], budget: 0.3, floor: 0.15)
		#expect(caps.values.allSatisfy { $0 == 0.15 })
	}

	@Test func disabledDoesNothing() {
		let p = pilot()
		p.settings.enabled = false
		#expect(p.decide(groups: [app("A", pid: 1)], frontmostPid: 0, lastActive: [:], audioPids: [], systemCPU: 1, onBattery: false, ncpu: 8).isEmpty)
	}

	@Test func enforcerAppliesAutoButNotOverManualRules() {
		let controller = FakeController()
		let store = tempStore()
		var manual = AppRule(matchKind: .bundleID, matchValue: "com.example.manual", displayName: "Manual")
		manual.cpuLimitEnabled = true
		manual.cpuLimit = 30
		store.upsert(manual)
		let e = Enforcer(controller: controller)
		let auto = app("Auto", pid: 500), man = app("Manual", pid: 600)
		let decisions = [auto.id: AutoDecision(reason: .background, efficiency: true, cap: 0.5),
						 man.id: AutoDecision(reason: .background, efficiency: true, cap: 2)]
		e.apply(makeSnapshot([auto, man], seq: 1), rules: store, state: SystemState(), frontmostPid: 0, auto: decisions)
		#expect(e.effectiveLimit[auto.id] == 0.5)
		#expect(controller.background[500] == true)
		#expect(e.effectiveLimit[man.id] == 0.3, "the manual rule wins")
		#expect(controller.background[600] == nil, "Auto's E-cores not applied over a manual CPU rule")
	}

	@Test func appsInUseAreForcedBackToFullSpeedOnce() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		let claude = app("Claude", pid: 800, helpers: [801])
		let inUse = [claude.id: AutoDecision(reason: .foreground)]
		e.apply(makeSnapshot([claude], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 800, auto: inUse)
		#expect(controller.background[800] == false && controller.background[801] == false, "cleared stale efficiency mode")
		controller.background = [:]
		e.apply(makeSnapshot([claude], seq: 2), rules: tempStore(), state: SystemState(), frontmostPid: 800, auto: inUse)
		#expect(controller.background.isEmpty, "not repeated every tick")
	}

	@Test func manualRulesNowDefaultToBackgroundOnlyForEfficiencyToo() {
		let controller = FakeController()
		let store = tempStore()
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.slack", displayName: "Slack")
		r.cpuLimitEnabled = true
		r.backgroundMode = true
		#expect(r.onlyWhenInactive, "new rules default to background-only")
		store.upsert(r)
		let e = Enforcer(controller: controller)
		let slack = app("Slack", pid: 700)
		e.apply(makeSnapshot([slack], seq: 1), rules: store, state: SystemState(), frontmostPid: 700)
		#expect(controller.groups.isEmpty && controller.background[700] == nil, "in front: full speed, P-cores")
		e.apply(makeSnapshot([slack], seq: 2), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(controller.limitedGroups.count == 1 && controller.background[700] == true)
	}
}
