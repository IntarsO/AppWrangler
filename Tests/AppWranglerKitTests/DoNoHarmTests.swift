//
//  DoNoHarmTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

/// 1.7.1: AppWrangler must not stop what you're working with.
@Suite struct NeverFreezeTests {
	@Test func theAppsYouWorkInAreNeverFrozenOrCapped() {
		let never: [(String, String?)] = [
			("Finder", "com.apple.finder"), ("Activity Monitor", "com.apple.ActivityMonitor"), ("System Settings", "com.apple.systempreferences"),
			("Safari", "com.apple.Safari"), ("Brave Browser", "com.brave.Browser"), ("Google Chrome", "com.google.Chrome"), ("Firefox", "org.mozilla.firefox"),
			("Claude", "com.anthropic.claudefordesktop"), ("ChatGPT", "com.openai.codex"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
			("Whispr", "one.whispr.desktop"), ("Slack", "com.tinyspeck.slackmacgap"), ("WhatsApp", "net.whatsapp.WhatsApp"), ("Zoom", "us.zoom.xos"),
			("Terminal", "com.apple.Terminal"), ("Docker", "com.docker.docker"),
		]
		for (name, id) in never { #expect(AppTraits.neverIdleFreeze(name: name, bundleID: id), "\(name)") }
	}

	@Test func ordinaryAppsCanStillBeFrozenWhenYouAskForIt() {
		for (name, id) in [("Photos", "com.apple.Photos"), ("Preview", "com.apple.Preview"), ("Pixelmator", "com.pixelmator.x"), ("Notion", "notion.id")] {
			#expect(!AppTraits.neverIdleFreeze(name: name, bundleID: id), "\(name)")
		}
	}

	@Test func idleFreezingSkipsThemEvenWhenTheyAreHeavyAndIdle() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let apps = [("Finder", "com.apple.finder"), ("Brave Browser", "com.brave.Browser"), ("Claude", "com.anthropic.claudefordesktop"), ("Photos", "com.apple.Photos")]
		var groups: [AppGroup] = []
		for (i, a) in apps.enumerated() { groups.append(makeGroup(name: a.0, bundleID: a.1, pid: pid_t(100 + i), cpu: 0, footprintMB: 900)) }
		let ids = AutoPilot.idleFreezeCandidates(groups, frontmostPid: 1, lastActive: [:], audioPids: [], idleAfter: 60, since: now - 3600, now: now)
		#expect(ids == ["app:com.apple.Photos"])
	}

	@Test func caps_dont_stall_messagingBrowsersOrAgents() {
		let t0 = Date(timeIntervalSince1970: 1_000_000)
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 1)
		let slack = makeGroup(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 200, cpu: 3)
		let hog = makeGroup(name: "Renderer", bundleID: "com.example.render", pid: 300, cpu: 3)
		_ = p.decide(groups: [front, slack, hog], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0)
		_ = p.decide(groups: [front, slack, hog], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 2)
		let d = p.decide(groups: [front, slack, hog], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 40)
		#expect(d[slack.id]?.cap == nil && d[slack.id]?.efficiency == true, "Slack still moves to the efficiency cores, but isn't stop/go throttled")
		#expect(d[hog.id]?.cap != nil)
	}

	@Test func theRuleEditorWarnsAboutFreezingThem() {
		var rule = AppRule(matchKind: .bundleID, matchValue: "net.whatsapp.WhatsApp", displayName: "WhatsApp")
		rule.pressureAction = .freeze
		#expect(AppTraits.neverIdleFreeze(name: rule.displayName, bundleID: rule.matchValue))
	}
}

/// Spotlight and photo-analysis helpers are slowed on the efficiency cores, never stopped.
@Suite struct MaintenanceNotStoppedTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func mdworker(cpu: Double) -> AppGroup {
		var g = AppGroup(id: "proc:mdworker_shared", ownerPid: 700, name: "mdworker_shared", bundleID: nil,
						 path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared", kind: .process)
		g.processes = [ProcessStat(pid: 700, name: "mdworker_shared", path: g.path, footprint: 1, measured: true)]
		g.cpu = cpu
		g.measured = true
		return g
	}

	@Test func theyAreEligibleForTheEfficiencyCoresDespiteLivingInSystem() {
		#expect(AutoPilot.processEligible(mdworker(cpu: 1)))
		#expect(!AutoPilot.processEligible(AppGroup(id: "proc:x", ownerPid: 1, name: "WindowServer", bundleID: nil, path: "/System/Library/x/WindowServer", kind: .process)))
	}

	@Test func theyGoToTheEfficiencyCoresWhenTheMacIsBusy() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 1)
		let m = mdworker(cpu: 1.2)
		_ = p.decide(groups: [front, m], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0)
		_ = p.decide(groups: [front, m], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 2)
		let d = p.decide(groups: [front, m], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 30)[m.id]
		#expect(d?.efficiency == true && d?.cap == nil)
	}

	@Test func theCanWaitPauseOnlyTouchesAppsYouMarkedYourself() {
		// The shedder itself decides on candidates; the model only offers apps whose own rule says Can wait.
		let s = Shedder()
		let t = Date(timeIntervalSince1970: 1_000_000)
		let marked = Shedder.Candidate(id: "app:com.example.updater", name: "Example Updater", cpu: 0.5, footprint: 1)
		_ = s.update([marked], need: .cpu, now: t)
		#expect(s.update([marked], need: .cpu, now: t + 16).pause == ["app:com.example.updater"])
		#expect(Priorities.isMaintenance(name: "mdworker_shared", bundleID: nil, path: "/System/x", kind: .process), "still the built-in Can wait: slowed, not paused")
	}
}

/// What AppWrangler did is kept between runs, so you can tell what it did to you.
@Suite struct ActivityLogTests {
	private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerLog-\(UUID().uuidString).json") }

	@Test func eventsSurviveARestartNewestFirst() {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		let log = ActivityLog(url: url)
		log.add("Photos", "frozen: memory was short")
		log.add("Slack", "resumed")
		log.saveNow()
		let again = ActivityLog(url: url)
		#expect(again.events.map(\.app) == ["Slack", "Photos"])
		#expect(again.events.first?.message == "resumed")
	}

	@Test func itKeepsAtMostFiveHundredAndSurvivesAMissingOrDamagedFile() throws {
		let url = tempURL()
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(ActivityLog(url: url).events.isEmpty)
		try Data("not json".utf8).write(to: url)
		#expect(ActivityLog(url: url).events.isEmpty)
		let log = ActivityLog(url: url)
		for i in 0..<520 { log.add("app", "event \(i)") }
		#expect(log.events.count == 500 && log.events.first?.message == "event 519")
	}

	@Test func theCommandLineShowsItWithoutTheAppRunning() throws {
		let store = tempStore()
		let dir = store.fileURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let log = ActivityLog(url: ActivityLog.fileURL(directory: dir))
		log.add("Photos", "frozen: memory was short")
		log.add("Slack", "resumed")
		log.saveNow()
		var out: [String] = []
		let code = CLI.run(["log", "5"], store: store, apps: [], print: { out.append($0) }, postToApp: { _, _ in true })
		#expect(code == 0 && out.count == 2)
		#expect(out[0].contains("Slack — resumed") && out[1].contains("Photos — frozen: memory was short"))
		var empty: [String] = []
		_ = CLI.run(["log"], store: tempStore(), apps: [], print: { empty.append($0) }, postToApp: { _, _ in true })
		#expect(empty == ["Nothing logged yet."])
	}
}
