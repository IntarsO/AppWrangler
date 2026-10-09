//
//  SuggestionTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

private let gb: UInt64 = 1_073_741_824

private func input(_ groups: [AppGroup], rules: [AppRule] = [], auto: Bool = true, pressure: Int = 1,
				   swapGB: Double = 0, ram: UInt64 = 8 * gb, frontmost: pid_t = 1) -> SuggestionInput {
	SuggestionInput(groups: groups, rules: rules, autoEnabled: auto, frontmostPid: frontmost, memoryBytes: ram,
					memoryUsedBytes: ram / 2, memoryPressure: pressure, swapUsedBytes: UInt64(swapGB * Double(gb)),
					onBattery: false, ncpu: 8, week: nil, fileExists: { _ in true })
}

@Suite struct SuggestionTests {
	@Test func autoOffIsSuggested() {
		#expect(Suggestions.make(input([], auto: false)).map(\.id) == ["auto-off"])
		#expect(Suggestions.make(input([])).isEmpty, "nothing to say about an idle Mac with Auto on")
	}

	@Test func memoryHogUnderPressureGetsBrowserTipAndActions() {
		let brave = makeGroup(name: "Brave Browser", bundleID: "com.brave.Browser", pid: 10, footprintMB: 3500)
		let list = Suggestions.make(input([brave], pressure: 2, swapGB: 4))
		let hog = list.first { $0.id == "memory-hog:bundle:com.brave.Browser" }
		#expect(hog != nil)
		#expect(hog?.severity == .medium)
		#expect(hog?.tip?.contains("brave://settings/system") == true)
		let tools = hog?.actions.map { $0.arguments.keys.sorted() } ?? []
		#expect(tools.contains(["app", "memory_action", "memory_limit_mb"]))
		#expect(tools.contains(["app", "low_memory_action"]))
		#expect(hog?.actions.first?.cli.hasPrefix("appwrangler set 'Brave Browser' ") == true)
		#expect(list.contains { $0.id == "memory-short" })
		// Over half the RAM is serious.
		let huge = makeGroup(name: "Brave Browser", bundleID: "com.brave.Browser", pid: 10, footprintMB: 9000)
		let big = Suggestions.make(input([huge], pressure: 2)).first { $0.id.hasPrefix("memory-hog:") }
		#expect(big?.severity == .high)
		#expect(big?.title.contains("more than this Mac's") == true)
	}

	@Test func noMemoryAdviceWhenThereIsPlentyFree() {
		let big = makeGroup(name: "Big", bundleID: "com.example.big", pid: 10, footprintMB: 2000)
		#expect(Suggestions.make(input([big], ram: 64 * gb)).isEmpty)
	}

	@Test func messagingAppsAreNotFrozenOnLowMemory() {
		let slack = makeGroup(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 10, footprintMB: 3000)
		let hog = Suggestions.make(input([slack], pressure: 4)).first { $0.app == "Slack" }
		#expect(hog?.severity == .high)
		#expect(hog?.actions.contains { $0.arguments["low_memory_action"] != nil } == false)
	}

	@Test func busyBackgroundProcessIsSuggestedButNotProtectedOrFocusedOrAutoManaged() {
		let node = makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 1.2, kind: .process)
		let focused = makeGroup(name: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 11, cpu: 3, kind: .process)
		let ws = makeGroup(name: "WindowServer", bundleID: nil, pid: 12, cpu: 2, kind: .process)
		let app = makeGroup(name: "Busy App", bundleID: "com.example.busy", pid: 13, cpu: 2)
		let list = Suggestions.make(input([node, focused, ws, app], frontmost: 11))
		#expect(list.map(\.app) == ["node"])
		let s = list[0]
		#expect(s.actions.first?.arguments["efficiency_cores"] as? Bool == true)
		#expect(s.actions.first?.arguments["background_only"] as? Bool == false, "processes have no 'frontmost'")
		#expect(s.actions.contains { $0.arguments["cpu_limit"] as? Int == 50 })
		// With Auto off the app is unmanaged too, and handing it to Auto comes first.
		let off = Suggestions.make(input([app], auto: false)).first { $0.app == "Busy App" }
		#expect(off?.actions.first?.tool == "set_auto_mode")
		#expect(off?.severity == .high)
	}

	@Test func aShortSpikeIsNotSuggestedInTheAppButStillByTheCommandLine() {
		let blip = makeGroup(name: "env", bundleID: nil, pid: 10, cpu: 0.53, kind: .process)
		var live = input([blip])
		#expect(Suggestions.make(live).map(\.app) == ["env"], "the CLI has only a one-second sample to go on")
		live.requireHistory = true
		#expect(Suggestions.make(live).isEmpty, "the app waits for minutes of history")
		live.averages[ImpactKey.of(blip)] = UsageAverages.App(name: "env", cpu: 0.9, memoryMB: 10, minutes: 4)
		#expect(Suggestions.make(live).map(\.app) == ["env"])
	}

	@Test func aProcessSuggestionSaysWhyAutoIsntHandlingIt() {
		let node = makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 1.2, kind: .process)
		let reason = Suggestions.make(input([node])).first?.reason ?? ""
		#expect(reason.contains("Auto mode doesn't manage this kind of process"))
		let app = makeGroup(name: "Busy App", bundleID: "com.example.busy", pid: 13, cpu: 2)
		let appReason = Suggestions.make(input([app], auto: false)).first { $0.app == "Busy App" }?.reason ?? ""
		#expect(!appReason.contains("kind of process"))
	}

	@Test func appWithItsOwnLimitIsNotSuggestedAgain() {
		let node = makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 1.2, kind: .process)
		var r = AppRule(matchKind: .name, matchValue: "node", displayName: "node")
		r.backgroundMode = true
		r.onlyWhenInactive = true
		#expect(Suggestions.make(input([node], rules: [r])).isEmpty)
	}

	@Test func ruleThatAppliesWhileFocusedIsFlagged() {
		var r = AppRule(matchKind: .bundleID, matchValue: "com.tinyspeck.slackmacgap", displayName: "Slack")
		r.cpuLimitEnabled = true
		r.cpuLimit = 30
		r.onlyWhenInactive = false
		let s = Suggestions.make(input([], rules: [r])).first
		#expect(s?.id.hasPrefix("applies-while-focused:") == true)
		#expect(s?.actions.map(\.arguments).contains { $0["background_only"] as? Bool == true } == true)
		#expect(s?.actions.contains { $0.arguments["use_auto"] as? Bool == true } == true)
		#expect(s?.actions.first?.cli == "appwrangler set Slack background_only=true")
	}

	@Test func limitThatHoldsAnAppBackIsFlaggedFromStats() {
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.x", displayName: "X")
		r.cpuLimitEnabled = true
		r.cpuLimit = 25
		r.onlyWhenInactive = true
		var impact = AppImpact(name: "X")
		impact.limitedSeconds = 3600
		impact.heldBackSeconds = 3000
		impact.wantedCoreSeconds = 3600 * 1.6
		impact.allowedCoreSeconds = 3600 * 0.25
		var week = ImpactSummary(days: 7)
		week.apps = [("bundle:com.example.x", impact)]
		var i = input([], rules: [r])
		i.week = week
		let s = Suggestions.make(i).first
		#expect(s?.id.hasPrefix("limit-too-strict:") == true)
		#expect(s?.actions.first?.arguments["cpu_limit"] as? Int == 125)
	}

	@Test func memoryLimitAlwaysExceededIsRaisedOnlyWhenThatIsSensible() {
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.m", displayName: "M")
		r.memoryLimitEnabled = true
		r.memoryLimitMB = 500
		let small = makeGroup(name: "M", bundleID: "com.example.m", pid: 10, footprintMB: 800)
		let raise = Suggestions.make(input([small], rules: [r], ram: 16 * gb)).first
		#expect(raise?.actions.first?.arguments["memory_limit_mb"] as? Int == 1024)
		// Raising past most of the RAM would only hide the problem.
		r.memoryLimitMB = 4096
		let huge = makeGroup(name: "M", bundleID: "com.example.m", pid: 10, footprintMB: 6000)
		let s = Suggestions.make(input([huge], rules: [r])).first { $0.id.hasPrefix("memory-limit-exceeded:") }
		#expect(s != nil)
		#expect(s?.actions.contains { $0.arguments["memory_limit_mb"] != nil } == false)
	}

	@Test func staleRulesAndAppFilter() {
		let gone = AppRule(matchKind: .path, matchValue: "/Applications/Gone.app", displayName: "Gone")
		var i = input([], rules: [gone], auto: false)
		i.fileExists = { _ in false }
		#expect(Set(Suggestions.make(i).map(\.id)) == ["auto-off", "stale-rule:" + gone.id.uuidString])
		#expect(Suggestions.make(i, app: "gone").map(\.app) == ["Gone"])
		#expect(Suggestions.make(i).first?.id == "auto-off", "sorted by severity")
	}

	@Test func suggestedCommandsAreShellSafe() {
		#expect(Suggestions.quoted("Slack") == "Slack")
		#expect(Suggestions.quoted("com.google.Chrome") == "com.google.Chrome")
		#expect(Suggestions.quoted("Brave Browser") == "'Brave Browser'")
		#expect(Suggestions.quoted("*Helper*") == "'*Helper*'")
		#expect(Suggestions.quoted("Tom's $App") == "'Tom'\\''s $App'")
	}

	@Test func ignoredAppsGetNoAdvice() {
		let node = makeGroup(name: "node", bundleID: nil, pid: 10, cpu: 1.2, footprintMB: 6000, kind: .process)
		var r = AppRule(matchKind: .name, matchValue: "node", displayName: "node")
		r.ignored = true
		#expect(Suggestions.make(input([node], rules: [r], pressure: 4)).filter { $0.app == "node" }.isEmpty)
	}
}

@Suite struct AppSettingsTests {
	@Test func parsesCLIAndJSONValues() throws {
		let cli = try RuleChanges.parse(cli: ["cpu_limit=50%", "efficiency-cores=on", "background_only=yes", "memory_action=forcequit",
											  "schedule=22:00-07:00", "weekdays=2,3,4,5,6", "power=battery"])
		#expect(cli.cpuLimit == 50 && cli.efficiencyCores == true && cli.backgroundOnly == true)
		#expect(cli.memoryAction == .forceQuit && cli.power == .battery)
		#expect(cli.schedule?.enabled == true && cli.schedule?.start == 22 * 60 && cli.schedule?.end == 7 * 60)
		#expect(cli.schedule?.weekdays == [2, 3, 4, 5, 6])
		let json = try RuleChanges.parse(["app": "X", "cpu_limit": 0, "memory_limit_mb": 1024, "use_auto": true,
										  "schedule": "off", "low_memory_action": "freeze"])
		#expect(json.cpuLimit == 0 && json.memoryLimitMB == 1024 && json.useAuto == true && json.schedule?.enabled == false)
		#expect(json.lowMemoryAction == .freeze)
	}

	@Test func rejectsBadValues() {
		for bad: [String: Any] in [["nope": 1], ["cpu_limit": -5], ["cpu_limit": "abc"], ["memory_limit_mb": 3],
								   ["efficiency_cores": "maybe"], ["memory_action": "explode"], ["schedule": "9-5"],
								   ["weekdays": [0, 8]], ["cpu_limit": Double.infinity]] {
			#expect(throws: RuleChanges.ParseError.self) { try RuleChanges.parse(bad) }
		}
		#expect(throws: RuleChanges.ParseError.self) { try RuleChanges.parse(cli: ["cpu_limit"]) }
	}

	@Test func configureCreatesMergesAndRemoves() throws {
		let store = tempStore()
		let apps = [RunningApp(pid: 10, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", bundlePath: "/Applications/Slack.app", kind: .app)]
		guard case .saved(let r1, let before) = AppSettings.configure("Slack", changes: try RuleChanges.parse(["efficiency_cores": true]), store: store, apps: apps) else {
			Issue.record("expected a saved rule"); return
		}
		#expect(before == "no rule")
		#expect(r1.matchKind == .bundleID && r1.backgroundMode && r1.enabled)
		guard case .saved(let r2, _) = AppSettings.configure("slack", changes: try RuleChanges.parse(["memory_limit_mb": 1500, "cpu_limit": 9999]), store: store, apps: apps) else {
			Issue.record("expected a saved rule"); return
		}
		#expect(r2.id == r1.id && r2.backgroundMode && r2.memoryLimitEnabled && r2.memoryLimitMB == 1500)
		#expect(r2.cpuLimit <= Double(SystemInfo.ncpu * 100), "capped at the core count")
		// use_auto keeps the memory limit but drops CPU/E-cores…
		guard case .saved(let r3, _) = AppSettings.configure("Slack", changes: try RuleChanges.parse(["use_auto": true]), store: store, apps: apps) else {
			Issue.record("expected a saved rule"); return
		}
		#expect(!r3.cpuLimitEnabled && !r3.backgroundMode && r3.memoryLimitEnabled)
		#expect(AppSettings.managedBy(nil, rule: r3, autoEnabled: true) == "auto")
		// …and a rule with nothing left is removed.
		guard case .removed = AppSettings.configure("Slack", changes: try RuleChanges.parse(["memory_limit_mb": 0]), store: store, apps: apps) else {
			Issue.record("expected the rule to be removed"); return
		}
		#expect(store.rules.isEmpty)
	}

	@Test func configureRefusesProtectedEmptyAndUnknown() throws {
		let store = tempStore()
		if case .failed = AppSettings.configure("WindowServer", changes: try RuleChanges.parse(["cpu_limit": 50]), store: store, apps: []) {} else { Issue.record("protected") }
		if case .failed = AppSettings.configure("X", changes: RuleChanges(), store: store, apps: []) {} else { Issue.record("empty") }
		if case .failed = AppSettings.configure("Nope", changes: try RuleChanges.parse(["efficiency_cores": false]), store: store, apps: []) {} else { Issue.record("turning off on no rule") }
		#expect(store.rules.isEmpty)
	}

	@Test func settingsUseTheConfigureKeys() {
		var r = AppRule(matchKind: .name, matchValue: "x", displayName: "x")
		r.cpuLimitEnabled = true
		r.cpuLimit = 40
		r.conditions.schedule = Schedule(enabled: true, start: 9 * 60, end: 18 * 60, weekdays: [2, 6])
		let s = AppSettings.settings(r)
		#expect(Set(s.keys).isSubset(of: RuleChanges.keyNames))
		#expect(s["cpu_limit"] as? Double == 40 && s["schedule"] as? String == "09:00-18:00" && s["weekdays"] as? [Int] == [2, 6])
		// Round trip: what we show can be fed straight back.
		var copy = AppRule(matchKind: .name, matchValue: "x", displayName: "x")
		(try? RuleChanges.parse(s))?.apply(to: &copy)
		#expect(copy.cpuLimitEnabled && copy.cpuLimit == 40 && copy.conditions.schedule == r.conditions.schedule)
	}

	@Test func managedBy() {
		let app = makeGroup()
		#expect(AppSettings.managedBy(app, rule: nil, autoEnabled: true) == "auto")
		#expect(AppSettings.managedBy(app, rule: nil, autoEnabled: false) == "nothing")
		#expect(AppSettings.managedBy(makeGroup(name: "Dock", bundleID: "com.apple.dock"), rule: nil, autoEnabled: true) == "protected")
		var r = AppRule.forGroup(app)
		r.backgroundMode = true
		#expect(AppSettings.managedBy(app, rule: r, autoEnabled: true) == "rule")
		r.ignored = true
		#expect(AppSettings.managedBy(app, rule: r, autoEnabled: true) == "ignored")
	}
}

@Suite struct SuggestionMCPTests {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerSuggestMCP-\(UUID().uuidString)")
	let apps = [RunningApp(pid: 10, bundleID: "com.brave.Browser", name: "Brave Browser", bundlePath: "/Applications/Brave Browser.app", kind: .app)]

	private func server(readOnly: Bool = false) -> MCPServer {
		let brave = makeGroup(name: "Brave Browser", bundleID: "com.brave.Browser", pid: 10, cpu: 0.3, footprintMB: 6000)
		return MCPServer(readOnly: readOnly, directory: dir, runningApps: { apps }, postToApp: { _, _ in true }, sampleSeconds: 0.2,
						 suggestionInput: { store, _, _ in
							 var i = input([brave], pressure: 2, swapGB: 3)
							 i.rules = store.rules
							 return i
						 })
	}

	private func tool(_ s: MCPServer, _ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
		let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
		let reply = s.handle(String(decoding: try! JSONSerialization.data(withJSONObject: req), as: UTF8.self))!
		return (try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any])["result"] as! [String: Any]
	}

	@Test func suggestSettingsReturnsActionsThatConfigureAppAccepts() {
		let s = server()
		let r = tool(s, "suggest_settings")
		let list = (r["structuredContent"] as? [String: Any])?["suggestions"] as? [[String: Any]] ?? []
		let hog = list.first { ($0["id"] as? String)?.hasPrefix("memory-hog:") == true }
		#expect(hog != nil)
		let action = (hog?["actions"] as? [[String: Any]])?.first { $0["tool"] as? String == "configure_app" }
		#expect(action != nil)
		// Feed the suggested call straight back in.
		let applied = tool(s, "configure_app", action?["arguments"] as? [String: Any] ?? [:])
		#expect(applied["isError"] as? Bool == false)
		let store = RuleStore(directory: dir, defaults: UserDefaults(suiteName: UUID().uuidString)!)
		#expect(store.rules.first?.matchValue == "com.brave.Browser")
		// Focus filter.
		let cpu = tool(s, "suggest_settings", ["focus": "cpu"])
		#expect(((cpu["structuredContent"] as? [String: Any])?["suggestions"] as? [Any])?.isEmpty == true)
	}

	@Test func getAppSettingsAndConfigure() {
		let s = server()
		let before = tool(s, "get_app_settings", ["app": "brave"])["structuredContent"] as? [String: Any]
		#expect(before?["app"] as? String == "Brave Browser")
		#expect(before?["managedBy"] as? String == "auto" || before?["managedBy"] as? String == "nothing")
		#expect((before?["settings"] as? [String: Any])?["cpu_limit"] as? Double == 0)
		#expect((before?["settingKeys"] as? [String: String])?["use_auto"] != nil)
		let set = tool(s, "configure_app", ["app": "Brave Browser", "efficiency_cores": true, "background_only": true, "schedule": "09:00-18:00"])
		#expect(set["isError"] as? Bool == false)
		let after = tool(s, "get_app_settings", ["app": "Brave Browser"])["structuredContent"] as? [String: Any]
		#expect(after?["managedBy"] as? String == "rule")
		#expect((after?["settings"] as? [String: Any])?["schedule"] as? String == "09:00-18:00")
		#expect(tool(s, "configure_app", ["app": "Brave Browser", "cpu_limit": "lots"])["isError"] as? Bool == true)
		#expect(tool(s, "configure_app", ["app": "Brave Browser"])["isError"] as? Bool == true, "nothing to change")
		#expect(tool(s, "get_app_settings", ["app": "Not Running Thing"])["isError"] as? Bool == true)
	}

	@Test func readOnlyServerCannotConfigure() {
		let s = server(readOnly: true)
		let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"configure_app","arguments":{"app":"x","cpu_limit":5}}}"#
		#expect(s.handle(req)?.contains("-32602") == true)
		#expect(((tool(s, "suggest_settings")["structuredContent"] as? [String: Any])?["note"] as? String)?.contains("read-only") == true)
	}

	@Test func tuneAppPromptExists() {
		#expect(MCPServer.prompts.contains { $0.name == "tune_app" })
	}
}

@Suite struct BuildToolSuggestionTests {
	@Test func compilersAreNotSuggestedForLimits() {
		let compiler = makeGroup(name: "swift-frontend", bundleID: nil, pid: 10, cpu: 3.5, kind: .process)
		let input = SuggestionInput(groups: [compiler], rules: [], autoEnabled: true, frontmostPid: 1, memoryBytes: 16 << 30,
									fileExists: { _ in true })
		#expect(Suggestions.make(input).isEmpty, "you're waiting for the build; don't slow it down")
	}
}
