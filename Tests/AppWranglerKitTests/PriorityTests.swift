//
//  PriorityTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct PriorityClassificationTests {
	@Test func wordsSplitAtCamelCaseAndPunctuation() {
		#expect(Priorities.words("GoogleSoftwareUpdateAgent") == ["google", "software", "update", "agent"])
		#expect(Priorities.words("Microsoft AutoUpdate") == ["microsoft", "auto", "update"])
		#expect(Priorities.words("mdworker_shared") == ["mdworker", "shared"])
	}

	@Test func updatersAndIndexersAreMaintenance() {
		#expect(Priorities.isMaintenance(name: "mdworker_shared", bundleID: nil, path: "/System/Library/Frameworks/CoreServices.framework/mdworker_shared", kind: .process))
		#expect(Priorities.isMaintenance(name: "photoanalysisd", bundleID: nil, path: "/System/Library/PrivateFrameworks/x/photoanalysisd", kind: .process))
		#expect(Priorities.isMaintenance(name: "GoogleSoftwareUpdateAgent", bundleID: "com.google.keystone.agent",
										 path: "/Users/me/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/MacOS/GoogleSoftwareUpdateAgent.app/Contents/MacOS/x",
										 kind: .process))
		#expect(Priorities.isMaintenance(name: "Microsoft AutoUpdate", bundleID: "com.microsoft.autoupdate2",
										 path: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/x", kind: .background))
	}

	@Test func theListIsDeliberatelyConservative() {
		// An app you use is never maintenance, whatever it's called.
		#expect(!Priorities.isMaintenance(name: "Update Tool", bundleID: "com.example.tool", path: "/Applications/Update Tool.app/Contents/MacOS/x", kind: .app))
		// Apple's own updaters are left alone.
		#expect(!Priorities.isMaintenance(name: "softwareupdate_notify_agent", bundleID: "com.apple.softwareupdate", path: "/System/Library/CoreServices/x.app/Contents/MacOS/x", kind: .process))
		// Command-line tools from Homebrew or your projects, build tools and protected processes.
		#expect(!Priorities.isMaintenance(name: "brew-update", bundleID: nil, path: "/opt/homebrew/bin/brew-update", kind: .process))
		#expect(!Priorities.isMaintenance(name: "swiftc", bundleID: nil, path: "/Applications/Xcode.app/Contents/x/swiftc", kind: .process))
		#expect(!Priorities.isMaintenance(name: "WindowServer", bundleID: nil, path: "/System/Library/x/WindowServer", kind: .process))
	}

	@Test func yourChoiceWinsOverTheBuiltInList() {
		let g = AppGroup(id: "bundle:com.google.keystone.agent", ownerPid: 500, name: "GoogleSoftwareUpdateAgent", bundleID: "com.google.keystone.agent",
						 path: "/Users/me/Library/Google/GoogleSoftwareUpdate/x.app/Contents/MacOS/x", kind: .process)
		#expect(Priorities.of(g, rule: nil) == .low, "built in")
		var rule = AppRule.forGroup(g)
		rule.priority = .high
		#expect(Priorities.of(g, rule: rule) == .high)
		rule.priority = .normal
		#expect(Priorities.of(g, rule: rule) == .low, "a rule without a priority doesn't change the default")
		rule.ignored = true
		#expect(Priorities.of(g, rule: rule) == .normal, "ignored means leave alone")
		let browser = makeGroup(name: "Browser", bundleID: "com.example.browser", pid: 10)
		var lowRule = AppRule.forGroup(browser)
		lowRule.priority = .low
		#expect(Priorities.of(browser, rule: nil) == .normal)
		#expect(Priorities.of(browser, rule: lowRule) == .low)
	}
}

@Suite struct ShedderTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func c(_ id: String, cpu: Double = 0.5, mb: UInt64 = 300) -> Shedder.Candidate {
		Shedder.Candidate(id: id, name: id, cpu: cpu, footprint: mb * 1_048_576)
	}

	@Test func nothingIsPausedUntilTheNeedHasLasted() {
		let s = Shedder()
		#expect(s.update([c("a")], need: .cpu, now: t0).isEmpty)
		#expect(s.update([c("a")], need: .cpu, now: t0 + 10).isEmpty)
		#expect(s.update([c("a")], need: .cpu, now: t0 + 16).pause == ["a"])
	}

	@Test func onlyWorkThatIsActuallyRunningIsPaused() {
		let s = Shedder()
		_ = s.update([c("busy"), c("idle", cpu: 0.0)], need: .cpu, now: t0)
		let plan = s.update([c("busy"), c("idle", cpu: 0.0)], need: .cpu, now: t0 + 16)
		#expect(plan.pause == ["busy"])
	}

	@Test func whenMemoryIsShortItStartsSoonerAndLooksAtMemory() {
		let s = Shedder()
		let big = c("big", cpu: 0, mb: 400), small = c("small", cpu: 0, mb: 20)
		_ = s.update([big, small], need: .memory, now: t0)
		let plan = s.update([big, small], need: .memory, now: t0 + 6)
		#expect(plan.pause == ["big"])
	}

	@Test func itResumesOnlyAfterTheMacHasHadRoomForAWhile() {
		let s = Shedder()
		_ = s.update([c("a")], need: .cpu, now: t0)
		#expect(s.update([c("a")], need: .cpu, now: t0 + 16).pause == ["a"])
		#expect(s.update([c("a", cpu: 0)], need: .none, now: t0 + 20).isEmpty)
		#expect(s.update([c("a", cpu: 0)], need: .none, now: t0 + 40).isEmpty, "20 s of room isn't enough")
		#expect(s.update([c("a", cpu: 0)], need: .none, now: t0 + 55).resume == ["a"])
		#expect(s.paused.isEmpty)
	}

	@Test func aFlickerOfRoomDoesNotResumeAnything() {
		let s = Shedder()
		_ = s.update([c("a")], need: .cpu, now: t0)
		_ = s.update([c("a")], need: .cpu, now: t0 + 16)
		_ = s.update([c("a")], need: .none, now: t0 + 20)
		_ = s.update([c("a")], need: .cpu, now: t0 + 30)
		#expect(s.update([c("a")], need: .none, now: t0 + 40).isEmpty)
		#expect(s.update([c("a")], need: .none, now: t0 + 60).isEmpty, "the 30 s of room restarted at t+40")
		#expect(s.update([c("a")], need: .none, now: t0 + 75).resume == ["a"])
	}

	@Test func nothingIsPausedForLongSoUpdatesStillFinish() {
		let s = Shedder()
		_ = s.update([c("a")], need: .cpu, now: t0)
		#expect(s.update([c("a")], need: .cpu, now: t0 + 16).pause == ["a"])
		let released = s.update([c("a")], need: .cpu, now: t0 + 16 + 601)
		#expect(released.resume == ["a"] && released.pause.isEmpty)
		// It rests for five minutes even though the need continues…
		#expect(s.update([c("a")], need: .cpu, now: t0 + 16 + 700).pause.isEmpty)
		// …and can be paused again afterwards.
		#expect(s.update([c("a")], need: .cpu, now: t0 + 16 + 601 + 301).pause == ["a"])
	}

	@Test func resumeNowResumesEverythingAndHoldsOff() {
		let s = Shedder()
		_ = s.update([c("a"), c("b")], need: .cpu, now: t0)
		_ = s.update([c("a"), c("b")], need: .cpu, now: t0 + 16)
		#expect(Set(s.resumeAll(holdOff: 600, now: t0 + 20)) == ["a", "b"])
		#expect(s.paused.isEmpty)
		#expect(s.update([c("a"), c("b")], need: .cpu, now: t0 + 100).pause.isEmpty, "held off for ten minutes")
		#expect(s.update([c("a"), c("b")], need: .cpu, now: t0 + 700).pause.count == 2)
	}

	@Test func workThatQuitIsForgotten() {
		let s = Shedder()
		_ = s.update([c("a")], need: .cpu, now: t0)
		_ = s.update([c("a")], need: .cpu, now: t0 + 16)
		_ = s.update([], need: .cpu, now: t0 + 20)
		#expect(s.paused.isEmpty)
	}

	@Test func syncDropsWhatIsNoLongerFrozen() {
		let s = Shedder()
		_ = s.update([c("a")], need: .cpu, now: t0)
		_ = s.update([c("a")], need: .cpu, now: t0 + 16)
		s.sync(stillPaused: [])	// you resumed it by hand
		#expect(s.paused.isEmpty)
	}
}

@Suite struct AutoPriorityTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func decide(_ p: AutoPilot, _ g: AppGroup, at t: TimeInterval, priority: AppPriority?, system: Double = 0.2) -> AutoDecision {
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)
		return p.decide(groups: [front, g], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system, onBattery: false, ncpu: 8,
						priorities: priority.map { [g.id: $0] } ?? [:], now: t0 + t)[g.id]!
	}

	@Test func highPriorityIsNeverHeldOrCapped() {
		let p = AutoPilot()
		let g = makeGroup(name: "Server", bundleID: "com.example.server", pid: 200, cpu: 2)
		for t in stride(from: 0.0, through: 200, by: 4) {
			let d = decide(p, g, at: t, priority: .high, system: t > 100 ? 0.95 : 0.2)
			#expect(d.reason == .priority && !d.efficiency && d.cap == nil)
		}
		#expect(AutoDecision(reason: .priority).label.contains("prioritized"))
	}

	@Test func lowPriorityGoesToTheEfficiencyCoresAtOnceAndNeverRunsFree() {
		let p = AutoPilot()
		let g = makeGroup(name: "Indexer", bundleID: "com.example.indexer", pid: 200, cpu: 0.9)
		#expect(decide(p, g, at: 0, priority: .low).efficiency, "no 30 s grace")
		for t in stride(from: 4.0, through: 100, by: 4) {
			let d = decide(p, g, at: t, priority: .low)
			#expect(d.efficiency && !d.lifted)
		}
		// A normal app in the same situation waits and may run free.
		let q = AutoPilot()
		let n = makeGroup(name: "Normal", bundleID: "com.example.normal", pid: 300, cpu: 0.9)
		#expect(!decide(q, n, at: 0, priority: nil).efficiency)
	}
}

@Suite struct PriorityRuleTests {
	@Test func rulesRoundTripAndOldFilesStillLoad() throws {
		var rule = AppRule(matchKind: .bundleID, matchValue: "com.example.app", displayName: "App")
		rule.priority = .low
		let data = try JSONEncoder().encode(rule)
		#expect(try JSONDecoder().decode(AppRule.self, from: data).priority == .low)
		let old = #"{"matchKind":"bundleID","matchValue":"com.example.app"}"#.data(using: .utf8)!
		#expect(try JSONDecoder().decode(AppRule.self, from: old).priority == .normal)
		let bad = #"{"matchKind":"bundleID","matchValue":"x","priority":"urgent"}"#.data(using: .utf8)!
		#expect(try JSONDecoder().decode(AppRule.self, from: bad).priority == .normal, "an unknown value doesn't lose the rule")
	}

	@Test func aPriorityIsAReasonToKeepTheRule() {
		var rule = AppRule(matchKind: .bundleID, matchValue: "com.example.app", displayName: "App")
		#expect(!rule.hasLimits)
		rule.priority = .high
		#expect(rule.hasLimits && rule.isActive)
		#expect(rule.summary.contains("prioritized"))
	}

	@Test func priorityIsASettingForTheCommandLineAndAssistants() throws {
		let changes = try RuleChanges.parse(["priority": "low"])
		#expect(changes.priority == .low && changes.addsSomething && !changes.isEmpty)
		#expect(throws: RuleChanges.ParseError.self) { try RuleChanges.parse(["priority": "urgent"]) }
		#expect(RuleChanges.keyNames.contains("priority"))

		let store = tempStore()
		let apps = [RunningApp(pid: 999_999, bundleID: "com.example.updater", name: "Example Updater", bundlePath: "/Applications/Example.app", kind: .background)]
		guard case .saved(let rule, _) = AppSettings.configure("Example Updater", changes: changes, store: store, apps: apps) else {
			Issue.record("expected the rule to be saved")
			return
		}
		#expect(rule.priority == .low)
		#expect(AppSettings.settings(rule)["priority"] as? String == "low")
		// Back to normal with nothing else set: the rule goes away.
		let normal = try RuleChanges.parse(["priority": "normal"])
		guard case .removed = AppSettings.configure("Example Updater", changes: normal, store: store, apps: apps) else {
			Issue.record("expected the empty rule to be removed")
			return
		}
		#expect(store.rules.isEmpty)
	}

	@Test func aShedFreezeEndsWhenYouSwitchToTheApp() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		let app = makeGroup(name: "Indexer", bundleID: "com.example.indexer", pid: 100, helpers: [101])
		e.apply(makeSnapshot([app], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 1)
		e.freeze(app, reason: .shed)
		#expect(e.isFrozen(app.id))
		e.apply(makeSnapshot([app], seq: 2), rules: tempStore(), state: SystemState(), frontmostPid: 1)
		#expect(e.isFrozen(app.id), "a shed freeze stays until the shedder lets it go")
		e.apply(makeSnapshot([app], seq: 3), rules: tempStore(), state: SystemState(), frontmostPid: 100)
		#expect(!e.isFrozen(app.id), "but switching to the app resumes it")
	}
}
