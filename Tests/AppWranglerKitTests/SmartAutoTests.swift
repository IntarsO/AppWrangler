//
//  SmartAutoTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

private func proc(_ name: String, cpu: Double, path: String = "/opt/homebrew/bin/x", pid: pid_t = 600) -> AppGroup {
	var g = AppGroup(id: "proc:\(name)", ownerPid: pid, name: name, bundleID: nil, path: path, kind: .process)
	g.processes = [ProcessStat(pid: pid, name: name, path: path, footprint: 100 * 1_048_576, measured: true)]
	g.cpu = cpu
	g.measured = true
	return g
}

/// Auto also looks after hot command-line processes, but only while the Mac needs its resources.
@Suite struct ProcessAutoTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)
	private let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)

	private func decide(_ p: AutoPilot, _ g: AppGroup, at t: TimeInterval, system: Double = 0.2, battery: Bool = false) -> AutoDecision? {
		p.decide(groups: [front, g], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system, onBattery: battery,
				 ncpu: 8, now: t0 + t)[g.id]
	}

	@Test func aHotProcessIsHeldOnlyWhileTheMacNeedsItsResources() {
		let p = AutoPilot()
		let node = proc("node", cpu: 0.8)
		// A calm Mac: followed, but left alone.
		for t in stride(from: 0.0, through: 60, by: 4) { #expect(decide(p, node, at: t)?.efficiency == false) }
		#expect(p.watchedProcessIDs == [node.id])
		// The Mac gets busy: after the process has been hot for a while, it's held on the efficiency cores. Never capped.
		_ = decide(p, node, at: 64, system: 0.95)
		let busy = decide(p, node, at: 66, system: 0.95)
		#expect(busy?.efficiency == true && busy?.cap == nil)
		#expect(p.summary.processes == 1 && p.summary.managed == 1, "processes aren't counted as apps")
		// And let go once the Mac has calmed down.
		_ = decide(p, node, at: 80, system: 0.2)
		let calm = decide(p, node, at: 82, system: 0.2)
		#expect(calm?.efficiency == false)
	}

	@Test func aProcessMustBeHotForAWhileFirst() {
		let p = AutoPilot()
		let node = proc("node", cpu: 0.8)
		_ = decide(p, node, at: 0, system: 0.95)
		_ = decide(p, node, at: 2, system: 0.95)
		#expect(decide(p, node, at: 10, system: 0.95)?.efficiency == false, "hot for 10 s isn't enough")
		#expect(decide(p, node, at: 24, system: 0.95)?.efficiency == true)
	}

	@Test func onBatteryItIsHeldWithoutWaitingForTheMacToBeBusy() {
		let p = AutoPilot()
		let node = proc("node", cpu: 0.8)
		_ = decide(p, node, at: 0, battery: true)
		#expect(decide(p, node, at: 25, battery: true)?.efficiency == true)
	}

	@Test func anIdleProcessIsNotListedAtAll() {
		let p = AutoPilot()
		let quiet = proc("quiet", cpu: 0.01)
		for t in stride(from: 0.0, through: 60, by: 4) { #expect(decide(p, quiet, at: t, system: 0.95) == nil) }
		#expect(p.watchedProcessIDs.isEmpty && p.summary.managed == 1)
	}

	@Test func onlySafeProcessesAreEligible() {
		#expect(AutoPilot.processEligible(proc("worker", cpu: 1, path: "/opt/homebrew/bin/worker")))
		#expect(!AutoPilot.processEligible(proc("swiftc", cpu: 1, path: "/Applications/Xcode.app/Contents/swiftc")), "build tool")
		#expect(!AutoPilot.processEligible(proc("WindowServer", cpu: 1, path: "/System/Library/x/WindowServer")), "protected")
		#expect(!AutoPilot.processEligible(proc("thing", cpu: 1, path: "/System/Library/CoreServices/thing")), "system path")
		#expect(!AutoPilot.processEligible(proc("tool", cpu: 1, path: "/usr/libexec/tool")), "system path")
		#expect(!AutoPilot.processEligible(proc("docker", cpu: 1, path: "/Applications/Docker.app/Contents/MacOS/docker")), "keeps your containers running")
		#expect(!AutoPilot.processEligible(makeGroup(name: "App", bundleID: "com.example.app", pid: 1)), "apps aren't processes")
	}

	@Test func processesCanBeSwitchedOff() {
		let p = AutoPilot()
		p.settings.processes = false
		let node = proc("node", cpu: 0.8)
		for t in stride(from: 0.0, through: 60, by: 4) { #expect(decide(p, node, at: t, system: 0.95) == nil) }
	}

	@Test func aTerminalsForegroundJobIsNeverSlowed() {
		let controller = FakeController()
		controller.terminalJobs = [600]
		let e = Enforcer(controller: controller)
		let job = proc("job", cpu: 1.0, pid: 600), other = proc("other", cpu: 1.0, pid: 700)
		var held = AutoDecision(reason: .background)
		held.efficiency = true
		e.apply(makeSnapshot([job, other], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 1,
				auto: [job.id: held, other.id: held])
		#expect(controller.background[600] == nil, "the shell is waiting for it")
		#expect(controller.background[700] == true)
	}
}

/// You're away: nothing is held back.
@Suite struct AwayAutoTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func decide(_ p: AutoPilot, _ groups: [AppGroup], at t: TimeInterval, away: Bool, system: Double = 0.2,
						priorities: [String: AppPriority] = [:]) -> [String: AutoDecision] {
		p.decide(groups: groups, frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system, onBattery: false, ncpu: 8,
				 priorities: priorities, away: away, now: t0 + t)
	}

	@Test func whenAwayBackgroundAppsRunAtFullSpeed() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)
		let bg = makeGroup(name: "Mail", bundleID: "com.example.mail", pid: 200, cpu: 0.05)
		_ = decide(p, [front, bg], at: 0, away: false)
		#expect(decide(p, [front, bg], at: 60, away: false)[bg.id]?.efficiency == true, "held when you're here")
		let away = decide(p, [front, bg], at: 62, away: true)[bg.id]
		#expect(away?.efficiency == false && away?.cap == nil && away?.away == true && away?.lifted == true)
		#expect(p.summary.away && p.summary.runningFree == 1)
		#expect(away?.label.contains("while you're away") == true)
		// You're back: held again at once (the grace period is long past).
		#expect(decide(p, [front, bg], at: 64, away: false)[bg.id]?.efficiency == true)
		#expect(!p.summary.away)
	}

	@Test func awayLiftsCapsEvenWhenTheMacIsBusyAndFreesLowPriorityWork() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)
		let hog = makeGroup(name: "Hog", bundleID: "com.example.hog", pid: 200, cpu: 5)
		let indexer = makeGroup(name: "Indexer", bundleID: "com.example.indexer", pid: 300, cpu: 1)
		let prio = [indexer.id: AppPriority.low]
		_ = decide(p, [front, hog, indexer], at: 0, away: false, system: 0.95, priorities: prio)
		let here = decide(p, [front, hog, indexer], at: 2, away: false, system: 0.95, priorities: prio)
		#expect(here[hog.id]?.cap != nil && here[indexer.id]?.efficiency == true)
		let away = decide(p, [front, hog, indexer], at: 4, away: true, system: 0.95, priorities: prio)
		#expect(away[hog.id]?.cap == nil && away[indexer.id]?.efficiency == false && away[indexer.id]?.away == true)
	}

	@Test func theAppInFrontIsStillTheAppInFront() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)
		#expect(decide(p, [front], at: 0, away: true)[front.id] == AutoDecision(reason: .foreground))
	}

	@Test func awayNeedsIdleTimeTheChargerAndACoolMac() {
		func away(idle: TimeInterval = 400, enabled: Bool = true, battery: Bool = false, lowPower: Bool = false, hot: Bool = false) -> Bool {
			AwayMode.isAway(idle: idle, after: 300, enabled: enabled, onBattery: battery, lowPower: lowPower, hot: hot)
		}
		#expect(away())
		#expect(!away(idle: 299))
		#expect(!away(enabled: false))
		#expect(!away(battery: true))
		#expect(!away(lowPower: true))
		#expect(!away(hot: true))
	}

	@Test func theIdleTimeIsReadable() {
		let idle = AwayMode.idleSeconds()
		#expect(idle >= 0 && idle < 10 * 365 * 86_400)
	}
}

/// Apps you usually use around now stay at full speed longer.
@Suite struct LikelyAutoTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	@Test func anAppYouUsuallyUseNowGetsALongerGrace() {
		func efficiencyAt(_ seconds: TimeInterval, likely: Bool, battery: Bool = false) -> Bool? {
			let p = AutoPilot()
			let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.1)
			let bg = makeGroup(name: "Slack", bundleID: "com.example.slack", pid: 200, cpu: 0.05)
			_ = p.decide(groups: [front, bg], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: battery, ncpu: 8,
						 likely: likely ? [bg.id] : [], now: t0)
			return p.decide(groups: [front, bg], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.2, onBattery: battery, ncpu: 8,
							likely: likely ? [bg.id] : [], now: t0 + seconds)[bg.id]?.efficiency
		}
		#expect(efficiencyAt(60, likely: false) == true)
		#expect(efficiencyAt(60, likely: true) == false, "kept at full speed for 5 minutes")
		#expect(efficiencyAt(301, likely: true) == true)
		#expect(efficiencyAt(60, likely: true, battery: true) == true, "never when the Mac is strained")
	}
}

/// What you use when, kept on this Mac.
@Suite struct UsagePatternsTests {
	private var calendar: Calendar {
		var c = Calendar(identifier: .gregorian)
		c.timeZone = TimeZone(secondsFromGMT: 0)!
		return c
	}
	/// Monday 2026-10-05 09:30 UTC.
	private let monday = Date(timeIntervalSince1970: 1_791_192_600)

	private func patterns(url: URL? = nil) -> UsagePatterns {
		let p = UsagePatterns(url: url, now: Date(timeIntervalSince1970: 1_791_192_600))
		p.calendar = calendar
		return p
	}

	@Test func slotsAreWeekdayAndHour() {
		let p = patterns()
		#expect(p.slot(monday) == 1 * 24 + 9)
		#expect(p.slot(monday.addingTimeInterval(-9.5 * 3600)) == 1 * 24 + 0)
		#expect(p.slot(monday.addingTimeInterval(-10 * 3600)) == 0 * 24 + 23, "Sunday 23:30")
	}

	@Test func aRoutineIsLearnedOverAFewWeeks() {
		let p = patterns()
		#expect(p.expected("bundle:slack", at: monday) == 0)
		p.record("bundle:slack", minutes: 20, at: monday)
		#expect(abs(p.expected("bundle:slack", at: monday) - 20 / 45) < 0.001, "one Monday isn't a routine yet")
		p.record("bundle:slack", minutes: 25, at: monday.addingTimeInterval(7 * 86_400))
		#expect(p.expected("bundle:slack", at: monday) == 1)
		#expect(p.expected("bundle:slack", at: monday.addingTimeInterval(86_400)) == 0, "Tuesday is a different slot")
		#expect(p.likely(at: monday) == ["bundle:slack"])
		#expect(p.likely(at: monday.addingTimeInterval(86_400)).isEmpty)
	}

	@Test func likelySoonLooksAnHourAhead() {
		let p = patterns()
		p.record("bundle:mail", minutes: 45, at: monday.addingTimeInterval(3600))		// Monday 10:30
		#expect(p.expected("bundle:mail", at: monday) == 0)
		#expect(p.likelySoon("bundle:mail", at: monday) == 1)
		#expect(p.likelySoon("bundle:mail", at: monday.addingTimeInterval(-3 * 3600)) == 0)
	}

	@Test func theWeekWrapsAround() {
		let p = patterns()
		let sundayNight = monday.addingTimeInterval(-10 * 3600)			// Sunday 23:30
		p.record("bundle:x", minutes: 45, at: monday.addingTimeInterval(-9 * 3600))	// Monday 00:30
		#expect(p.likelySoon("bundle:x", at: sundayNight) == 1)
	}

	@Test func invalidMinutesAreIgnored() {
		let p = patterns()
		p.record("bundle:x", minutes: 0, at: monday)
		p.record("bundle:x", minutes: -3, at: monday)
		p.record("bundle:x", minutes: .nan, at: monday)
		#expect(p.isEmpty)
	}

	@Test func whatWasLearnedFadesWeekByWeekAndOldAppsDropOut() {
		let p = patterns()
		p.record("bundle:old", minutes: 1, at: monday)
		p.record("bundle:slack", minutes: 45, at: monday)
		p.decayIfDue(now: monday.addingTimeInterval(3 * 86_400))
		#expect(p.expected("bundle:slack", at: monday) == 1, "not a week yet")
		p.decayIfDue(now: monday.addingTimeInterval(7 * 86_400))
		#expect(abs(p.expected("bundle:slack", at: monday) - 0.9) < 0.001)
		#expect(p.minutes["bundle:old"] == nil, "under a minute left")
		p.decayIfDue(now: monday.addingTimeInterval(14 * 86_400))
		#expect(abs(p.expected("bundle:slack", at: monday) - 0.81) < 0.001)
	}

	@Test func itSurvivesARestartAndCanBeForgotten() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerPatterns-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }
		let p = patterns(url: url)
		p.record("bundle:slack", minutes: 40.04, at: monday)
		p.save()
		let again = patterns(url: url)
		#expect(abs(again.expected("bundle:slack", at: monday) - 40.0 / 45) < 0.001)
		again.reset()
		#expect(again.isEmpty && !FileManager.default.fileExists(atPath: url.path))
		#expect(patterns(url: url).isEmpty)
	}

	@Test func aDamagedFileIsIgnored() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerPatterns-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }
		try Data("not json".utf8).write(to: url)
		#expect(patterns(url: url).isEmpty)
		try Data(#"{"updated":"2026-10-01T00:00:00Z","lastDecay":"2026-10-01T00:00:00Z","minutes":{"bundle:x":[1,2,3]}}"#.utf8).write(to: url)
		#expect(patterns(url: url).isEmpty, "wrong number of slots")
	}

	@Test func onlyIdentifiersAndMinutesAreStored() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerPatterns-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }
		let p = patterns(url: url)
		p.record("bundle:com.example.app", minutes: 12, at: monday)
		p.save()
		let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
		#expect(Set(object.keys) == ["updated", "lastDecay", "minutes"])
		#expect(Set((object["minutes"] as! [String: Any]).keys) == ["bundle:com.example.app"])
	}

	@Test func settingsDefaultToOnAndAreEditableFromTheCommandLine() {
		let keys = Set(PreferenceSettings.specs.map(\.key))
		#expect(keys.isSuperset(of: ["auto_processes", "auto_away", "auto_away_minutes", "auto_learn"]))
		let defaults = AutoSettings()
		#expect(defaults.processes && defaults.away && defaults.learn && defaults.awayAfter == 300)
	}
}
