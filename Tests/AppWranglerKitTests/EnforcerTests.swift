//
//  EnforcerTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct EnforcerTests {
	let controller = FakeController()
	let store = tempStore()
	var enforcer: Enforcer { Enforcer(controller: controller) }

	private func rule(_ edit: (inout AppRule) -> Void) -> AppRule {
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "Test App")
		edit(&r)
		store.upsert(r)
		return r
	}

	@Test func cpuLimitAppliesToAppAndHelpers() {
		_ = rule { $0.cpuLimitEnabled = true; $0.cpuLimit = 50 }
		let e = enforcer
		e.apply(makeSnapshot([makeGroup(helpers: [50_001, 50_002])], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.limitedGroups.count == 1)
		#expect(controller.limitedGroups.first?.pids == [50_000, 50_001, 50_002])
		#expect(controller.limitedGroups.first?.limit == 0.5)
	}

	@Test func excludingHelpersLimitsOnlyMainProcess() {
		_ = rule { $0.cpuLimitEnabled = true; $0.includeHelpers = false }
		enforcer.apply(makeSnapshot([makeGroup(helpers: [50_001])], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.limitedGroups.first?.pids == [50_000])
	}

	@Test func steadyStateDoesNotResetTheLimiter() {
		_ = rule { $0.cpuLimitEnabled = true }
		let e = enforcer
		for seq in 1...5 {
			e.apply(makeSnapshot([makeGroup()], seq: UInt64(seq)), rules: store, state: SystemState(), frontmostPid: 0)
		}
		#expect(controller.sets.count == 1)
	}

	@Test func limitIsLiftedWhenRuleRemoved() {
		let r = rule { $0.cpuLimitEnabled = true }
		let e = enforcer
		e.apply(makeSnapshot([makeGroup()], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		store.remove(id: r.id)
		e.apply(makeSnapshot([makeGroup()], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.groups.isEmpty)
	}

	@Test func onlyWhileInBackgroundFollowsFocus() {
		_ = rule { $0.cpuLimitEnabled = true; $0.onlyWhenInactive = true }
		let e = enforcer
		let snap = makeSnapshot([makeGroup()], seq: 1)
		e.apply(snap, rules: store, state: SystemState(), frontmostPid: 50_000)
		#expect(controller.groups.isEmpty, "frontmost app must not be limited")
		e.apply(snap, rules: store, state: SystemState(), frontmostPid: 123)
		#expect(controller.limitedGroups.count == 1, "limit applies as soon as it loses focus")
	}

	// Audit bug #2: re-applying the same sample (focus change) counted as a new strike.
	@Test func memoryLimitNeedsTwoFreshSamples() {
		_ = rule { $0.memoryLimitEnabled = true; $0.memoryLimitMB = 100; $0.memoryAction = .quit }
		let e = enforcer
		let big = makeGroup(footprintMB: 300)
		let first = makeSnapshot([big], seq: 1)
		e.apply(first, rules: store, state: SystemState(), frontmostPid: 0)
		e.apply(first, rules: store, state: SystemState(), frontmostPid: 1)	// focus change
		e.apply(first, rules: store, state: SystemState(), frontmostPid: 2)
		#expect(controller.terminated.isEmpty)
		e.apply(makeSnapshot([big], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.terminated == [50_000])
		e.apply(makeSnapshot([big], seq: 3), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.terminated.count == 1, "acts once per excursion")
	}

	@Test func memoryLimitIgnoresHelpersWhenExcluded() {
		_ = rule { $0.memoryLimitEnabled = true; $0.memoryLimitMB = 100; $0.memoryAction = .freeze; $0.includeHelpers = false }
		let e = enforcer
		let g = makeGroup(helpers: [50_001], footprintMB: 50, helperFootprintMB: 500)
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		e.apply(makeSnapshot([g], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.frozenGroups.isEmpty)
	}

	@Test func memoryFreezeFreezesWholeGroup() {
		_ = rule { $0.memoryLimitEnabled = true; $0.memoryLimitMB = 100; $0.memoryAction = .freeze }
		let e = enforcer
		let g = makeGroup(helpers: [50_001], footprintMB: 300)
		var events: [String] = []
		e.onEvent = { _, message, _ in events.append(message) }
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		e.apply(makeSnapshot([g], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.frozenGroups.first?.pids == [50_000, 50_001])
		#expect(e.isFrozen(g.id))
		#expect(events.count == 1)
	}

	// Audit bug #1 (enforcer side): pausing must not drop frozen groups.
	@Test func pauseKeepsFrozenGroups() {
		let e = enforcer
		let g = makeGroup()
		e.freeze(g)
		e.setPaused(true)
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.paused)
		#expect(controller.frozenGroups.count == 1)
		#expect(controller.removed.isEmpty)
	}

	@Test func frozenEntryIsDroppedWhenTheAppQuits() {
		let e = enforcer
		let g = makeGroup()
		e.freeze(g)
		controller.alive = [50_000]
		e.apply(makeSnapshot([], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(e.isFrozen(g.id), "missing from one sample but still running → stays frozen")
		controller.alive = []
		e.apply(makeSnapshot([], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(!e.isFrozen(g.id), "exited → not frozen, so a relaunch isn't frozen")
		#expect(controller.groups.isEmpty)
	}

	@Test func commandsOnlyReachTheirOwnInstance() {
		#expect(IPC.isForThisInstance(["command": "pause", "dataDir": "/a"], dataDir: "/a"))
		#expect(!IPC.isForThisInstance(["command": "pause", "dataDir": "/tmp/test"], dataDir: "/a"))
		#expect(!IPC.isForThisInstance(["command": "pause"], dataDir: "/a"), "unscoped commands are ignored")
	}

	@Test func unfreezeReleases() {
		let e = enforcer
		let g = makeGroup()
		e.freeze(g)
		e.unfreeze(g.id)
		#expect(controller.groups.isEmpty)
		#expect(!e.isFrozen(g.id))
	}

	@Test func conditionsGateTheRule() {
		_ = rule { $0.cpuLimitEnabled = true; $0.conditions.power = .battery }
		let e = enforcer
		let snap = makeSnapshot([makeGroup()], seq: 1)
		var state = SystemState()
		e.apply(snap, rules: store, state: state, frontmostPid: 0)
		#expect(controller.groups.isEmpty, "plugged in: rule waits")
		state.onBattery = true
		e.apply(snap, rules: store, state: state, frontmostPid: 0)
		#expect(controller.limitedGroups.count == 1, "unplugged: applies immediately")
		state.onBattery = false
		e.apply(snap, rules: store, state: state, frontmostPid: 0)
		#expect(controller.groups.isEmpty, "plugged back in: lifted")
	}

	@Test func lowMemoryFreezesAndThaws() {
		_ = rule { $0.pressureAction = .freeze }
		let e = enforcer
		let g = makeGroup()
		var state = SystemState()
		state.memoryPressure = 4
		let t0 = Date(timeIntervalSince1970: 5_000_000)
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: state, frontmostPid: 0, now: t0)
		#expect(controller.frozenGroups.count == 1)
		// Memory has to stay fine for a while before apps are thawed…
		state.memoryPressure = 1
		e.apply(makeSnapshot([g], seq: 2), rules: store, state: state, frontmostPid: 0, now: t0 + 1)
		#expect(e.isFrozen(g.id), "no thaw on the first good sample")
		// …a brief dip back to low memory restarts the wait…
		state.memoryPressure = 4
		e.apply(makeSnapshot([g], seq: 3), rules: store, state: state, frontmostPid: 0, now: t0 + 30)
		state.memoryPressure = 1
		e.apply(makeSnapshot([g], seq: 4), rules: store, state: state, frontmostPid: 0, now: t0 + 40)
		e.apply(makeSnapshot([g], seq: 5), rules: store, state: state, frontmostPid: 0, now: t0 + 80)
		#expect(e.isFrozen(g.id), "only 40 s of good memory")
		// …and then it thaws.
		e.apply(makeSnapshot([g], seq: 6), rules: store, state: state, frontmostPid: 0, now: t0 + 101)
		#expect(controller.groups.isEmpty)
		#expect(!e.isFrozen(g.id))
	}

	@Test func lowMemorySparesTheAppYouAreUsing() {
		_ = rule { $0.pressureAction = .freeze }
		let e = enforcer
		var state = SystemState()
		state.memoryPressure = 4
		e.apply(makeSnapshot([makeGroup()], seq: 1), rules: store, state: state, frontmostPid: 50_000)
		#expect(controller.frozenGroups.isEmpty, "frontmost app not frozen")
		let audio = [makeGroup().id: AutoDecision(reason: .audio)]
		e.apply(makeSnapshot([makeGroup()], seq: 2), rules: store, state: state, frontmostPid: 1, auto: audio)
		#expect(controller.frozenGroups.isEmpty, "app on a call / playing audio not frozen")
		e.apply(makeSnapshot([makeGroup()], seq: 3), rules: store, state: state, frontmostPid: 1)
		#expect(controller.frozenGroups.count == 1, "in the background: frozen")
	}

	@Test func manualFreezeSurvivesMemoryRecovery() {
		let e = enforcer
		let g = makeGroup()
		e.freeze(g, reason: .manual)
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(e.isFrozen(g.id))
	}

	@Test func efficiencyModeAppliedAndReverted() {
		let r = rule { $0.backgroundMode = true }
		let e = enforcer
		e.apply(makeSnapshot([makeGroup(helpers: [50_001])], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.background == [50_000: true, 50_001: true])
		store.remove(id: r.id)
		e.apply(makeSnapshot([makeGroup(helpers: [50_001])], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.background == [50_000: false, 50_001: false])
	}

	@Test func turningOffEfficiencyAlsoRestoresInheritingDescendants() {
		let r = rule { $0.backgroundMode = true }
		let e = enforcer
		// A terminal app whose shell (outside the app group) started a build.
		controller.children = [50_000: [60_000], 60_000: [60_001]]
		e.apply(makeSnapshot([makeGroup()], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		store.remove(id: r.id)
		e.apply(makeSnapshot([makeGroup()], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.background[60_000] == false)
		#expect(controller.background[60_001] == false)
	}

	@Test func descendantsWithTheirOwnEfficiencyRuleKeepIt() {
		let r = rule { $0.backgroundMode = true }
		var other = AppRule(matchKind: .bundleID, matchValue: "com.example.child", displayName: "Child")
		other.backgroundMode = true
		store.upsert(other)
		let e = enforcer
		let child = makeGroup(name: "Child", bundleID: "com.example.child", pid: 60_000)
		controller.children = [50_000: [60_000]]
		e.apply(makeSnapshot([makeGroup(), child], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		store.remove(id: r.id)
		e.apply(makeSnapshot([makeGroup(), child], seq: 2), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.background[50_000] == false)
		#expect(controller.background[60_000] == true, "its own rule still wants E-cores")
	}

	@Test func protectedProcessesAreNeverTouched() {
		var r = AppRule(matchKind: .name, matchValue: "WindowServer", displayName: "WindowServer")
		r.cpuLimitEnabled = true
		store.upsert(r)
		let e = enforcer
		let ws = makeGroup(name: "WindowServer", bundleID: nil, pid: 400, kind: .process)
		e.apply(makeSnapshot([ws], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		e.freeze(ws)
		#expect(controller.groups.isEmpty)
	}

	@Test func ignoredRulesDoNothing() {
		_ = rule { $0.cpuLimitEnabled = true; $0.ignored = true }
		enforcer.apply(makeSnapshot([makeGroup()], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.groups.isEmpty)
	}
}
