//
//  V11Tests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Auto mode's idle-app freezing, the undo journal, averaged suggestions and
//  the MCP config installer.
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct AutoMemoryTests {
	let t0 = Date(timeIntervalSince1970: 3_000_000)

	@Test func candidatesAreIdleRegularAppsBiggestFirst() {
		let big = makeGroup(name: "Big", bundleID: "com.example.big", pid: 10, cpu: 0, footprintMB: 3000)
		let small = makeGroup(name: "Small", bundleID: "com.example.small", pid: 20, cpu: 0, footprintMB: 500)
		let tiny = makeGroup(name: "Tiny", bundleID: "com.example.tiny", pid: 30, footprintMB: 50)
		let recent = makeGroup(name: "Recent", bundleID: "com.example.recent", pid: 40, footprintMB: 900)
		let front = makeGroup(name: "Front", bundleID: "com.example.front", pid: 50, footprintMB: 900)
		let music = makeGroup(name: "Music", bundleID: "com.example.music", pid: 60, helpers: [61], footprintMB: 900)
		let slack = makeGroup(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 70, footprintMB: 900)
		let menu = makeGroup(name: "Menu", bundleID: "com.example.menu", pid: 80, footprintMB: 900, kind: .background)
		let ids = AutoPilot.idleFreezeCandidates([small, big, tiny, recent, front, music, slack, menu], frontmostPid: 50,
												 lastActive: [40: t0 - 120, 20: t0 - 3600], audioPids: [61],
												 idleAfter: 600, since: t0 - 7200, now: t0)
		#expect(ids == [big.id, small.id])
	}

	@Test func messagingAppsAreRecognised() {
		for (name, id) in [("Slack", "com.tinyspeck.slackmacgap"), ("WhatsApp", "net.whatsapp.WhatsApp"), ("Microsoft Teams", "com.microsoft.teams2"),
						   ("zoom.us", "us.zoom.xos"), ("Mail", "com.apple.mail"), ("Signal", "org.whispersystems.signal-desktop")] {
			#expect(AppTraits.isMessaging(name: name, bundleID: id), "\(name)")
		}
		for (name, id) in [("Brave Browser", "com.brave.Browser"), ("Linear", "com.linear"), ("Gmail Tool", "com.example.gmailtool")] {
			#expect(!AppTraits.isMessaging(name: name, bundleID: id), "\(name)")
		}
	}

	private func lowMemory() -> SystemState { var s = SystemState(); s.memoryPressure = 4; return s }

	@Test func freezesWhenLowAndResumesWhenYouSwitchToIt() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		e.pressureThawDelay = 0
		let app = makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 100, helpers: [101], footprintMB: 2000)
		let store = tempStore()
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: lowMemory(), frontmostPid: 1, autoFreeze: [app.id], autoFreezeActive: true)
		#expect(e.isFrozen(app.id))
		#expect(controller.frozenGroups.first?.pids == [100, 101])
		// Switching to it thaws it at once, even though memory is still low…
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: lowMemory(), frontmostPid: 100, autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
		#expect(controller.frozenGroups.isEmpty)
		// …and it isn't frozen again in the same low-memory episode.
		e.apply(makeSnapshot([app], seq: 2), rules: store, state: lowMemory(), frontmostPid: 1, autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
	}

	@Test func resumesWhenMemoryFreesUpAndNeedsLowMemory() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		e.pressureThawDelay = 0
		let app = makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 100, footprintMB: 2000)
		let store = tempStore()
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: SystemState(), frontmostPid: 1, autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id), "nothing happens while memory is fine")
		e.apply(makeSnapshot([app], seq: 2), rules: store, state: lowMemory(), frontmostPid: 1, autoFreeze: [app.id], autoFreezeActive: true)
		#expect(e.isFrozen(app.id))
		e.apply(makeSnapshot([app], seq: 3), rules: store, state: SystemState(), frontmostPid: 1, autoFreeze: [], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
	}

	@Test func neverFreezesAnAppAutoConsidersInUse() {
		let e = Enforcer(controller: FakeController())
		let app = makeGroup(name: "Call", bundleID: "com.example.call", pid: 100, helpers: [101], footprintMB: 2000)
		e.apply(makeSnapshot([app], seq: 1), rules: tempStore(), state: lowMemory(), frontmostPid: 1,
				auto: [app.id: AutoDecision(reason: .recent)], autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
		e.apply(makeSnapshot([app], seq: 2), rules: tempStore(), state: lowMemory(), frontmostPid: 1, audioPids: [101], autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
	}

	@Test func ruleBasedLowMemoryFreezeAlsoResumesOnFocus() {
		let controller = FakeController()
		let store = tempStore()
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "T")
		r.pressureAction = .freeze
		store.upsert(r)
		let e = Enforcer(controller: controller)
		let app = makeGroup(pid: 100)
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: lowMemory(), frontmostPid: 1)
		#expect(e.isFrozen(app.id))
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: lowMemory(), frontmostPid: 100)
		#expect(!e.isFrozen(app.id))
	}

	@Test func preferencesReachTheSettings() {
		let d = UserDefaults.standard
		let old = (d.object(forKey: Prefs.autoFreezeIdle), d.object(forKey: Prefs.autoFreezeIdleMinutes))
		defer { d.set(old.0, forKey: Prefs.autoFreezeIdle); d.set(old.1, forKey: Prefs.autoFreezeIdleMinutes) }
		d.set(true, forKey: Prefs.autoFreezeIdle)
		d.set(30, forKey: Prefs.autoFreezeIdleMinutes)
		#expect(Prefs.autoSettings.freezeIdleWhenLowMemory && Prefs.autoSettings.freezeIdleAfter == 1800)
		d.set(0, forKey: Prefs.autoFreezeIdleMinutes)
		#expect(Prefs.autoSettings.freezeIdleAfter == 60, "clamped to at least a minute")
	}
}

@Suite struct UndoTests {
	@Test func undoWalksBackThroughChanges() throws {
		let store = tempStore()
		let apps = [RunningApp(pid: 10, bundleID: "com.example.s", name: "S", bundlePath: "/Applications/S.app", kind: .app)]
		_ = AppSettings.configure("S", changes: try RuleChanges.parse(["efficiency_cores": true]), store: store, apps: apps)
		_ = AppSettings.configure("S", changes: try RuleChanges.parse(["cpu_limit": 40]), store: store, apps: apps)
		#expect(store.rules.first?.cpuLimitEnabled == true)
		let first = ChangeJournal.undo(store: store)
		#expect(first?.entry.source == "cli")
		#expect(store.rules.first?.cpuLimitEnabled == false && store.rules.first?.backgroundMode == true)
		_ = ChangeJournal.undo(store: store)
		#expect(store.rules.isEmpty, "the rule didn't exist before the first change")
		#expect(ChangeJournal.undo(store: store) == nil)
	}

	@Test func undoRestoresARemovedRuleAndCLIRecordsChanges() {
		let store = tempStore()
		var out: [String] = []
		let run = { (args: [String]) in _ = CLI.run(args, store: store, apps: [], print: { out.append($0) }, postToApp: { _, _ in false }) }
		run(["limit", "node", "30"])
		run(["memlimit", "node", "512"])
		run(["unlimit", "node"])
		#expect(store.rules.isEmpty)
		run(["undo"])
		#expect(store.rules.first?.memoryLimitEnabled == true && store.rules.first?.cpuLimit == 30)
		run(["undo"]); run(["undo"])
		#expect(store.rules.isEmpty)
		run(["undo"])
		#expect(out.last == "Nothing to undo.")
	}

	@Test func journalKeepsTheLastFifty() {
		let store = tempStore()
		for i in 0..<60 {
			var r = AppRule(matchKind: .name, matchValue: "p\(i)", displayName: "p\(i)")
			r.backgroundMode = true
			ChangeJournal.record(before: nil, after: r, source: "cli", store: store)
		}
		let entries = ChangeJournal.entries(directory: store.fileURL.deletingLastPathComponent())
		#expect(entries.count == ChangeJournal.capacity && entries.last?.app == "p59")
	}

	@Test func mcpConfigureReturnsPreviousSettingsAndUndoes() {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerUndoMCP-\(UUID().uuidString)")
		let apps = [RunningApp(pid: 10, bundleID: "com.example.s", name: "S", bundlePath: "/Applications/S.app", kind: .app)]
		let s = MCPServer(readOnly: false, directory: dir, runningApps: { apps }, postToApp: { _, _ in false }, sampleSeconds: 0.2)
		func tool(_ name: String, _ args: [String: Any]) -> [String: Any] {
			let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
			let reply = s.handle(String(decoding: try! JSONSerialization.data(withJSONObject: req), as: UTF8.self))!
			return ((try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any])["result"] as! [String: Any])
		}
		_ = tool("configure_app", ["app": "S", "memory_limit_mb": 1024])
		let second = tool("configure_app", ["app": "S", "memory_limit_mb": 2048])["structuredContent"] as? [String: Any]
		#expect((second?["previous"] as? [String: Any])?["memory_limit_mb"] as? Double == 1024)
		#expect(second?["undo"] as? String == "undo_last_change")
		let undone = tool("undo_last_change", [:])["structuredContent"] as? [String: Any]
		#expect(undone?["undone"] as? Bool == true)
		#expect((undone?["settings"] as? [String: Any])?["memory_limit_mb"] as? Double == 1024)
		#expect(ChangeJournal.entries(directory: dir).first?.source == "mcp")
	}
}

@Suite struct AveragedSuggestionTests {
	private func input(_ groups: [AppGroup], averages: [String: UsageAverages.App]) -> SuggestionInput {
		SuggestionInput(groups: groups, rules: [], autoEnabled: true, frontmostPid: 1, memoryBytes: 16 << 30,
						averages: averages, fileExists: { _ in true })
	}

	@Test func aShortSpikeIsNotFlaggedWhenTheAverageIsLow() {
		let node = makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 2.0, kind: .process)
		let calm = UsageAverages.App(name: "node", cpu: 0.1, memoryMB: 100, minutes: 8)
		#expect(Suggestions.make(input([node], averages: [ImpactKey.of(node): calm])).isEmpty)
		let busy = UsageAverages.App(name: "node", cpu: 1.2, memoryMB: 100, minutes: 8)
		let s = Suggestions.make(input([makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 0.0, kind: .process)],
										averages: [ImpactKey.of(node): busy])).first
		#expect(s?.reason.contains("8 min") == true)
		#expect(s?.title.contains("120%") == true)
	}

	@Test func averagesAreComputedFromHistory() {
		let history = HistoryStore()
		var g = makeGroup(name: "A", bundleID: "com.example.a", pid: 10, cpu: 1.0, footprintMB: 300)
		let t0 = Date(timeIntervalSince1970: 4_000_000)
		for i in 0..<10 {
			g.cpu = i % 2 == 0 ? 1.0 : 0.0
			var snap = makeSnapshot([g], seq: UInt64(i + 1))
			snap.date = t0 + Double(i) * 30
			history.record(snap)
		}
		let avg = UsageAverages.compute(groups: [g], history: history)[ImpactKey.of(g)]
		#expect(avg.map { abs($0.cpu - 0.5) < 0.001 } == true)
		#expect(avg?.minutes == 4.5 && avg?.memoryMB == 300)
		// Too little history: no average yet.
		let fresh = HistoryStore()
		fresh.record(makeSnapshot([g], seq: 1))
		#expect(UsageAverages.compute(groups: [g], history: fresh).isEmpty)
	}

	@Test func averagesRoundTripAndExpire() {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerUsage-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let now = Date()
		UsageAverages(updated: now, apps: ["bundle:x": .init(name: "X", cpu: 0.7, memoryMB: 10, minutes: 5)]).write(directory: dir)
		#expect(UsageAverages.read(directory: dir, now: now)?.apps["bundle:x"]?.cpu == 0.7)
		#expect(UsageAverages.read(directory: dir, now: now + 600) == nil, "stale when AppWrangler stopped writing")
	}

	@Test func idleFreezeIsSuggestedWhenMemoryIsShort() {
		var i = input([makeGroup(name: "Big", bundleID: "com.example.big", pid: 10, footprintMB: 4000)], averages: [:])
		i.memoryBytes = 8 << 30
		i.memoryPressure = 2
		let s = Suggestions.make(i).first { $0.id == "auto-freeze-idle" }
		#expect(s?.actions.first?.arguments["freeze_idle_apps"] as? Bool == true)
		#expect(s?.actions.first?.cli == "appwrangler auto freeze-idle on")
		i.autoFreezeIdle = true
		#expect(!Suggestions.make(i).contains { $0.id == "auto-freeze-idle" })
	}
}

@Suite struct MCPInstallerTests {
	let home = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerHome-\(UUID().uuidString)")
	let exe = "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler"

	private func run(_ args: [String], running: Set<MCPInstaller.Client> = []) -> (Int32, [String]) {
		var out: [String] = []
		let code = MCPInstaller.run(args, home: home, executable: exe, isRunning: { running.contains($0) }, print: { out.append($0) })
		return (code, out)
	}

	private func setUpClients() throws {
		let fm = FileManager.default
		try fm.createDirectory(at: home.appendingPathComponent("Library/Application Support/Claude"), withIntermediateDirectories: true)
		try Data(#"{"preferences":{"x":1},"mcpServers":{"other":{"command":"/bin/other"}}}"#.utf8)
			.write(to: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
		try Data(#"{"numStartups":5,"projects":{}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
		try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
		try "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
	}

	@Test func installStatusUninstallRoundTrip() throws {
		try setUpClients()
		#expect(run(["install"]).0 == 0)
		for client in MCPInstaller.Client.allCases {
			#expect(try MCPInstaller.read(client, home: home) == .init(command: exe, args: ["mcp"]), "\(client)")
		}
		// Other settings are kept.
		let desktop = try JSONSerialization.jsonObject(with: Data(contentsOf: MCPInstaller.Client.claudeDesktop.configFile(home: home))) as! [String: Any]
		#expect((desktop["mcpServers"] as? [String: Any])?["other"] != nil && desktop["preferences"] != nil)
		let code = try JSONSerialization.jsonObject(with: Data(contentsOf: MCPInstaller.Client.claudeCode.configFile(home: home))) as! [String: Any]
		#expect(code["numStartups"] as? Int == 5)
		let toml = try String(contentsOf: MCPInstaller.Client.codex.configFile(home: home), encoding: .utf8)
		#expect(toml.contains("[mcp_servers.other]") && toml.contains("model = \"o4\""))
		#expect(FileManager.default.fileExists(atPath: MCPInstaller.Client.codex.configFile(home: home).path + ".appwrangler-backup"))
		// Installing again changes nothing; switching to read-only updates in place.
		#expect(run(["install"]).1.allSatisfy { $0.hasSuffix("already configured") })
		_ = run(["install", "--read-only", "codex"])
		#expect(try MCPInstaller.read(.codex, home: home)?.readOnly == true)
		#expect(try String(contentsOf: MCPInstaller.Client.codex.configFile(home: home), encoding: .utf8).components(separatedBy: "[mcp_servers.appwrangler]").count == 2)
		#expect(run(["status"]).1.contains { $0.contains("OpenAI Codex: configured (read-only)") })
		// Uninstall removes only our entry.
		#expect(run(["uninstall"]).0 == 0)
		for client in MCPInstaller.Client.allCases { #expect(try MCPInstaller.read(client, home: home) == nil) }
		#expect(try String(contentsOf: MCPInstaller.Client.codex.configFile(home: home), encoding: .utf8).contains("[mcp_servers.other]"))
	}

	@Test func skipsMissingClientsAndRefusesWhileClaudeDesktopIsOpen() throws {
		try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Claude"), withIntermediateDirectories: true)
		let (code, out) = run(["install"], running: [.claudeDesktop])
		#expect(code == 1)
		#expect(out.contains { $0.hasPrefix("Claude Desktop: quit it first") })
		#expect(out.contains("Claude Code: not installed — skipped") && out.contains("OpenAI Codex: not installed — skipped"))
		#expect(try MCPInstaller.read(.claudeDesktop, home: home) == nil)
		#expect(run(["install", "bogus"]).0 == 1)
		#expect(run([]).0 == 1)
	}

	@Test func tomlStringsAreParsedAndEscaped() {
		#expect(MCPInstaller.tomlStrings(#"args = ["mcp", "--read-only"]"#) == ["mcp", "--read-only"])
		#expect(MCPInstaller.tomlString(#"/a "b"\c"#) == #""/a \"b\"\\c""#)
		#expect(MCPInstaller.tomlStrings("command = " + MCPInstaller.tomlString(#"/a "b"\c"#)) == [#"/a "b"\c"#])
	}
}

@Suite struct FreezeSafetyTests {
	private func lowMemory() -> SystemState { var s = SystemState(); s.memoryPressure = 4; return s }

	@Test func memoryLimitFreezeEndsWhenTheRuleStopsFreezing() {
		let controller = FakeController()
		let store = tempStore()
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "T")
		r.memoryLimitEnabled = true
		r.memoryLimitMB = 50
		r.memoryAction = .freeze
		store.upsert(r)
		let e = Enforcer(controller: controller)
		let g = makeGroup(pid: 100, footprintMB: 500)
		e.apply(makeSnapshot([g], seq: 1), rules: store, state: SystemState(), frontmostPid: 1)
		e.apply(makeSnapshot([g], seq: 2), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(e.isFrozen(g.id), "two samples over the limit")
		// Switching the action to notify (or removing the rule, or undo) resumes it.
		r.memoryAction = .notify
		store.upsert(r)
		e.apply(makeSnapshot([g], seq: 3), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(!e.isFrozen(g.id))
		#expect(controller.frozenGroups.isEmpty)
	}

	@Test func lowMemoryFreezeEndsWhenTheFeatureIsTurnedOff() {
		let e = Enforcer(controller: FakeController())
		let app = makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 100, footprintMB: 2000)
		e.apply(makeSnapshot([app], seq: 1), rules: tempStore(), state: lowMemory(), frontmostPid: 1,
				autoFreeze: [app.id], autoFreezeActive: true)
		#expect(e.isFrozen(app.id))
		// Still low on memory, but you switched idle freezing (or Auto) off.
		e.apply(makeSnapshot([app], seq: 2), rules: tempStore(), state: lowMemory(), frontmostPid: 1, autoFreezeActive: false)
		#expect(!e.isFrozen(app.id))
	}

	@Test func terminalForegroundJobsAreNeverFrozen() {
		let controller = FakeController()
		controller.terminalJobs = [200]
		let e = Enforcer(controller: controller)
		let job = makeGroup(name: "node", bundleID: nil, pid: 200, kind: .process)
		e.freeze(job)
		#expect(!e.isFrozen(job.id))
		#expect(controller.frozenGroups.isEmpty)
		// A group with a foreground job and a background helper: only the helper stops.
		let mixed = makeGroup(name: "tool", bundleID: nil, pid: 200, helpers: [201], kind: .process)
		e.freeze(mixed)
		#expect(controller.frozenGroups.first?.pids == [201])
	}

	@Test func nothingNewIsFrozenWhilePaused() {
		let e = Enforcer(controller: FakeController())
		e.setPaused(true)
		let app = makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 100, footprintMB: 2000)
		e.apply(makeSnapshot([app], seq: 1), rules: tempStore(), state: lowMemory(), frontmostPid: 1,
				autoFreeze: [app.id], autoFreezeActive: true)
		#expect(!e.isFrozen(app.id))
	}

	@Test func aFrozenAppMissingFromAPartialSampleStaysFrozen() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		let app = makeGroup(pid: 100)
		e.freeze(app, reason: .manual)
		// A re-apply with a sample that doesn't include it (Auto off, UI closed).
		e.apply(makeSnapshot([], seq: 0), rules: tempStore(), state: SystemState(), frontmostPid: 1)
		#expect(controller.frozenGroups.count == 1)
		#expect(controller.removed.isEmpty)
	}

	@Test func busyAppsTerminalsAndVMsAreNotIdleFrozen() {
		let t0 = Date(timeIntervalSince1970: 3_000_000)
		let groups = [
			makeGroup(name: "Busy", bundleID: "com.example.busy", pid: 10, cpu: 0.4, footprintMB: 900),
			makeGroup(name: "Terminal", bundleID: "com.apple.Terminal", pid: 20, cpu: 0, footprintMB: 900),
			makeGroup(name: "Docker Desktop", bundleID: "com.docker.docker", pid: 30, cpu: 0, footprintMB: 900),
			makeGroup(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", pid: 40, cpu: 0, footprintMB: 900),
			makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 50, cpu: 0, footprintMB: 900),
		]
		let ids = AutoPilot.idleFreezeCandidates(groups, frontmostPid: 1, lastActive: [:], audioPids: [],
												 idleAfter: 600, since: t0 - 7200, now: t0)
		#expect(ids == ["app:com.example.idle"])
	}

	@Test func switchingToAnyWindowOfAnAppCountsAsInUse() {
		let p = AutoPilot()
		p.settings.efficiencyAfter = 0
		let app = makeGroup(name: "A", bundleID: "com.example.a", pid: 300, helpers: [301])
		_ = p.decide(groups: [app], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.1, onBattery: false, ncpu: 8)
		let d = p.refocus(frontmostPid: 301, lastActive: [:])
		#expect(d[app.id]?.reason == .foreground)
	}
}

@Suite struct MCPInstallerEdgeCaseTests {
	let home = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerHomeEdge-\(UUID().uuidString)")
	let exe = "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler"
	var codex: URL { home.appendingPathComponent(".codex/config.toml") }
	var claude: URL { home.appendingPathComponent(".claude.json") }

	private func run(_ args: [String]) -> (Int32, [String]) {
		var out: [String] = []
		let code = MCPInstaller.run(args, home: home, executable: exe, isRunning: { _ in false }, print: { out.append($0) })
		return (code, out)
	}

	private func writeCodex(_ text: String) throws {
		try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
		try text.write(to: codex, atomically: true, encoding: .utf8)
	}

	@Test func codexEntryWithCRLFCommentsQuotedKeyAndSubtableIsReplacedNotDuplicated() throws {
		try writeCodex("model = \"o4\"\r\n\r\n[mcp_servers.\"appwrangler\"]   # added by hand\r\ncommand = \"/old/AppWrangler\"\r\nargs = [\r\n  \"mcp\",\r\n  \"--read-only\",\r\n]\r\n\r\n[mcp_servers.appwrangler.env]\r\nX = \"1\"\r\n\r\n[mcp_servers.other]\r\ncommand = \"/bin/other\"\r\n")
		let before = try MCPInstaller.read(.codex, home: home)
		#expect(before == .init(command: "/old/AppWrangler", args: ["mcp", "--read-only"]), "multi-line args are read")
		#expect(run(["install", "codex"]).0 == 0)
		let text = try String(contentsOf: codex, encoding: .utf8)
		#expect(text.components(separatedBy: "mcp_servers.appwrangler]").count == 2, "exactly one appwrangler table")
		#expect(!text.contains("appwrangler.env"), "its sub-table went with it")
		#expect(text.contains("[mcp_servers.other]") && text.contains("model = \"o4\""))
		#expect(try MCPInstaller.read(.codex, home: home) == .init(command: exe, args: ["mcp"]))
	}

	@Test func inlineCodexEntriesAreLeftAlone() throws {
		try writeCodex("[mcp_servers]\nappwrangler = { command = \"/x\", args = [\"mcp\"] }\n")
		let (code, out) = run(["install", "codex"])
		#expect(code == 1)
		#expect(out.contains { $0.contains("edit that entry by hand") })
		#expect(try String(contentsOf: codex, encoding: .utf8).contains("appwrangler = {"), "unchanged")
	}

	@Test func claudeEntryIsMergedSymlinksKeptAndFirstBackupKept() throws {
		let fm = FileManager.default
		try fm.createDirectory(at: home, withIntermediateDirectories: true)
		let real = home.appendingPathComponent("dotfiles-claude.json")
		try Data(#"{"mcpServers":{"appwrangler":{"command":"/old","args":["mcp"],"env":{"APPWRANGLER_DATA_DIR":"/tmp/x"}}}}"#.utf8).write(to: real)
		try fm.createSymbolicLink(at: claude, withDestinationURL: real)
		#expect(run(["install", "claude-code"]).0 == 0)
		// The symlink is still a symlink, and the real file was updated.
		#expect((try? fm.destinationOfSymbolicLink(atPath: claude.path)) != nil)
		let json = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
		let server = (json["mcpServers"] as! [String: Any])["appwrangler"] as! [String: Any]
		#expect(server["command"] as? String == exe)
		#expect((server["env"] as? [String: String])?["APPWRANGLER_DATA_DIR"] == "/tmp/x", "user's env kept")
		// A second change keeps the original backup.
		_ = run(["install", "--read-only", "claude-code"])
		let backup = try String(contentsOf: real.appendingPathExtension("appwrangler-backup"), encoding: .utf8)
		#expect(backup.contains("/old"))
	}

	@Test func commentsInsideStringsSurvive() {
		#expect(MCPInstaller.stripComment(#"command = "/a#b" # note"#).trimmingCharacters(in: .whitespaces) == #"command = "/a#b""#)
		#expect(MCPInstaller.tomlHeader(#"[ mcp_servers . "appwrangler" ]  # x"#) == "mcp_servers.appwrangler")
	}
}

@Suite struct NameResolutionTests {
	let store = tempStore()
	let apps = [RunningApp(pid: 1, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", kind: .app),
				RunningApp(pid: 2, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundlePath: nil, kind: .app),
				RunningApp(pid: 3, bundleID: "com.apple.dt.Xcode", name: "Xcode", bundlePath: nil, kind: .app)]

	private func resolve(_ t: String) -> Result<AppRule, RuleTargets.Problem> {
		RuleTargets.resolveForWrite(t, store: store, apps: apps, installed: { $0.lowercased() == "safari" ? ("Safari", "com.apple.Safari") : nil },
									installedByID: { $0 == "org.mozilla.firefox" ? "Firefox" : nil })
	}

	@Test func bundleIDsAndInstalledAppsBecomeBundleIDRules() throws {
		let ff = try resolve("org.mozilla.firefox").get()
		#expect(ff.matchKind == .bundleID && ff.displayName == "Firefox")
		let safari = try resolve("safari").get()
		#expect(safari.matchKind == .bundleID && safari.matchValue == "com.apple.Safari")
	}

	@Test func partialNamesWorkWhenUnambiguous() throws {
		#expect(try resolve("chrome").get().matchValue == "com.google.Chrome")
		guard case .failure(.ambiguous(_, let names)) = resolve("code") else { Issue.record("expected ambiguity"); return }
		#expect(names == ["Visual Studio Code", "Xcode"])
	}

	@Test func protectedAndTooBroadAreRefused() {
		guard case .failure(.protected) = resolve("windowserver") else { Issue.record("case-insensitive protection"); return }
		guard case .failure(.tooBroad) = resolve("*") else { Issue.record("bare wildcard"); return }
		guard case .failure(.tooBroad) = resolve("*a*") else { Issue.record("near-bare wildcard"); return }
		#expect((try? resolve("*Helper*").get())?.matchKind == .pattern)
	}

	@Test func processNameRulesIgnoreCase() {
		let r = AppRule(matchKind: .name, matchValue: "Node", displayName: "Node")
		#expect(r.matches(bundleID: nil, path: "/usr/local/bin/node", name: "node"))
	}

	@Test func undoRefusesToOverwriteLaterEdits() throws {
		let changes = try RuleChanges.parse(["cpu_limit": 50])
		_ = AppSettings.configure("Google Chrome", changes: changes, store: store, apps: apps)
		// Edited in the panel afterwards (not journaled).
		var r = store.rules[0]
		r.memoryLimitEnabled = true
		store.upsert(r)
		guard case .conflict = ChangeJournal.undoLast(store: store) else { Issue.record("expected a conflict"); return }
		#expect(store.rules.count == 1 && store.rules[0].memoryLimitEnabled, "nothing lost")
		guard case .undone = ChangeJournal.undoLast(store: store, force: true) else { Issue.record("force undoes"); return }
		#expect(store.rules.isEmpty)
	}

	@Test func aCorruptJournalIsSetAsideNotWiped() throws {
		let dir = store.fileURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try Data("not json".utf8).write(to: ChangeJournal.url(dir))
		#expect(ChangeJournal.entries(directory: dir).isEmpty)
		let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
		#expect(names.contains { $0.hasPrefix("changes.unreadable-") })
	}
}

@Suite struct PreferenceSettingsTests {
	let d = UserDefaults(suiteName: "AppWranglerPrefsTest-\(UUID().uuidString)")!

	@Test func setsKnownKeysWithinRange() throws {
		let now = try PreferenceSettings.set(["freeze_idle": "on", "freeze_idle_minutes": "30", "low_memory_level": "warning",
											  "auto_busy_percent": 60, "runaway_alerts": false], d)
		#expect(now["freeze_idle"] as? Bool == true && now["freeze_idle_minutes"] as? Double == 30)
		#expect(d.integer(forKey: Prefs.pressureLevel) == 2 && now["low_memory_level"] as? String == "warning")
		#expect(d.double(forKey: Prefs.autoBusyPercent) == 60 && !d.bool(forKey: Prefs.runawayEnabled))
	}

	@Test func rejectsEverythingIfOneValueIsBad() {
		#expect(throws: RuleChanges.ParseError.self) { try PreferenceSettings.set(["freeze_idle": "on", "auto_busy_percent": 5], d) }
		#expect(d.object(forKey: Prefs.autoFreezeIdle) == nil, "nothing written")
		for bad: [String: Any] in [["nope": 1], ["low_memory_level": "panic"], ["notifications": "maybe"], ["runaway_minutes": "abc"]] {
			#expect(throws: RuleChanges.ParseError.self) { try PreferenceSettings.set(bad, d) }
		}
	}

	@Test func everyKeyIsShownAndMapsToARealPreference() {
		let now = PreferenceSettings.current(d)
		#expect(Set(now.keys) == Set(PreferenceSettings.specs.map(\.key)))
		#expect(Set(PreferenceSettings.specs.map(\.defaultsKey)).count == PreferenceSettings.specs.count)
	}
}

@Suite struct ConcurrentRuleWriteTests {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerRaces-\(UUID().uuidString)")
	private func store() -> RuleStore { RuleStore(directory: dir, defaults: UserDefaults(suiteName: UUID().uuidString)!) }
	private func rule(_ name: String) -> AppRule {
		var r = AppRule(matchKind: .name, matchValue: name, displayName: name)
		r.backgroundMode = true
		return r
	}

	@Test func twoWritersDoNotOverwriteEachOther() {
		let app = store(), cli = store()	// both loaded the same (empty) file
		app.upsert(rule("a"))
		cli.upsert(rule("b"))
		app.saveNow()
		cli.saveNow()		// would have written only [b] before
		#expect(Set(store().rules.map(\.displayName)) == ["a", "b"])
		#expect(Set(cli.rules.map(\.displayName)) == ["a", "b"], "the writer picks up the other's change")
	}

	@Test func editsAndRemovalsMergeByRule() {
		let first = store()
		first.upsert(rule("a")); first.upsert(rule("b")); first.saveNow()
		let app = store(), cli = store()
		var a = app.rules.first { $0.displayName == "a" }!
		a.cpuLimitEnabled = true
		a.cpuLimit = 30
		app.upsert(a)								// the app edits a…
		cli.remove(id: cli.rules.first { $0.displayName == "b" }!.id)	// …while the CLI removes b
		cli.saveNow()
		app.saveNow()
		let final = store().rules
		#expect(final.map(\.displayName) == ["a"])
		#expect(final.first?.cpuLimit == 30)
	}

	@Test func mergeIsPure() {
		let a = rule("a"), b = rule("b"), c = rule("c")
		var a2 = a; a2.cpuLimitEnabled = true
		// base [a, b]; local changed a, removed b; disk meanwhile added c.
		let merged = RuleStore.merge(local: [a2], base: [a, b], disk: [a, b, c])
		#expect(merged.map(\.displayName) == ["a", "c"] && merged[0].cpuLimitEnabled)
	}
}
