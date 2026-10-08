//
//  RulesTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct RulesTests {
	@Test func decodesRulesFromVersion2_0() throws {
		// Written by the first rebuild: no conditions / pressure / ignored keys.
		let json = """
		[{"matchKind":"name","matchValue":"burner","displayName":"burner","cpuLimitEnabled":true,"cpuLimit":30,"backgroundMode":true}]
		"""
		let rules = try JSONDecoder().decode([AppRule].self, from: Data(json.utf8))
		#expect(rules.count == 1)
		#expect(rules[0].cpuLimit == 30)
		#expect(rules[0].conditions == RuleConditions())
		#expect(rules[0].pressureAction == .none)
		#expect(!rules[0].ignored)
	}

	@Test func mostSpecificRuleWins() {
		let store = tempStore()
		store.upsert(AppRule(matchKind: .pattern, matchValue: "*test*", displayName: "pattern"))
		store.upsert(AppRule(matchKind: .name, matchValue: "Test App", displayName: "name"))
		store.upsert(AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "bundle"))
		#expect(store.rule(for: makeGroup())?.displayName == "bundle")
		#expect(store.rule(for: makeGroup(bundleID: nil))?.displayName == "name")
		#expect(store.rule(for: makeGroup(name: "my-test-tool", bundleID: nil))?.displayName == "pattern")
	}

	@Test func patternsIgnoreCaseAndMatchBundleIDs() {
		let r = AppRule(matchKind: .pattern, matchValue: "*helper*", displayName: "")
		#expect(r.matches(bundleID: nil, path: "", name: "Google Chrome Helper (Renderer)"))
		#expect(!r.matches(bundleID: nil, path: "", name: "Safari"))
		let b = AppRule(matchKind: .pattern, matchValue: "com.google.*", displayName: "")
		#expect(b.matches(bundleID: "com.google.Chrome", path: "", name: "Google Chrome"))
	}

	private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
		// 2026-10-04 is a Sunday (weekday 1).
		var c = DateComponents(year: 2026, month: 10, day: 3 + weekday, hour: hour, minute: minute)
		c.calendar = Calendar(identifier: .gregorian)
		return c.date!
	}

	@Test func scheduleDaytimeWindow() {
		let s = Schedule(enabled: true, start: 9 * 60, end: 17 * 60, weekdays: [2, 3, 4, 5, 6])
		#expect(s.contains(date(weekday: 2, hour: 10)))
		#expect(!s.contains(date(weekday: 2, hour: 8, minute: 59)))
		#expect(!s.contains(date(weekday: 2, hour: 17)))
		#expect(!s.contains(date(weekday: 1, hour: 10)), "Sunday excluded")
	}

	@Test func scheduleOvernightWindowBelongsToStartDay() {
		let s = Schedule(enabled: true, start: 22 * 60, end: 6 * 60, weekdays: [6])	// Friday night
		#expect(s.contains(date(weekday: 6, hour: 23)))
		#expect(s.contains(date(weekday: 7, hour: 3)), "Saturday 03:00 is still Friday night")
		#expect(!s.contains(date(weekday: 7, hour: 23)))
		#expect(!s.contains(date(weekday: 6, hour: 3)), "Friday 03:00 is Thursday night")
	}

	@Test func disabledScheduleAlwaysApplies() {
		#expect(Schedule().contains(Date()))
	}

	@Test func conditionsCombine() {
		var c = RuleConditions()
		c.power = .battery
		c.hotOnly = true
		var s = SystemState()
		s.onBattery = true
		#expect(!c.applies(s))
		s.thermal = 2
		#expect(c.applies(s))
		c.power = .charger
		#expect(!c.applies(s))
	}

	@Test func persistsAndReloads() {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerTests-\(UUID().uuidString)")
		let a = RuleStore(directory: dir)
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "Test")
		r.cpuLimitEnabled = true
		r.conditions.schedule.enabled = true
		a.upsert(r)
		a.saveNow()
		let b = RuleStore(directory: dir)
		#expect(b.rules == a.rules)
	}

	@Test func externalEditIsPickedUpButOwnWritesAreNot() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerTests-\(UUID().uuidString)")
		let app = RuleStore(directory: dir)
		app.upsert(AppRule(matchKind: .name, matchValue: "a", displayName: "a"))
		app.saveNow()
		#expect(!app.reloadFromDisk(), "our own write isn't an external change")

		let cli = RuleStore(directory: dir)
		cli.upsert(AppRule(matchKind: .name, matchValue: "b", displayName: "b"))
		cli.saveNow()
		#expect(app.reloadFromDisk())
		#expect(app.rules.map(\.matchValue) == ["a", "b"])
	}

	@Test func importMergesBySameApp() throws {
		let store = tempStore()
		var existing = AppRule(matchKind: .bundleID, matchValue: "com.x", displayName: "X")
		existing.cpuLimit = 10
		store.upsert(existing)
		var incoming = AppRule(matchKind: .bundleID, matchValue: "com.x", displayName: "X")
		incoming.cpuLimit = 70
		let other = AppRule(matchKind: .name, matchValue: "y", displayName: "Y")
		let n = try store.importData(JSONEncoder().encode([incoming, other]))
		#expect(n == 2)
		#expect(store.rules.count == 2)
		#expect(store.rules.first { $0.matchValue == "com.x" }?.cpuLimit == 70)
		#expect(store.rules.first { $0.matchValue == "com.x" }?.id == existing.id)
	}

	@Test func migratesAppWrangler1Limits() {
		let defaults = UserDefaults(suiteName: "AppWranglerTests-\(UUID().uuidString)")!
		defaults.set(["Safari": 0.5, "Mail": 0, "node": 2.5], forKey: "APApplicationLimits")
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerTests-\(UUID().uuidString)")
		let store = RuleStore(directory: dir, defaults: defaults)
		#expect(store.rules.map(\.matchValue) == ["node", "Safari"])
		#expect(store.rules.first { $0.matchValue == "node" }?.cpuLimit == 250)
	}

	@Test func importsRulesFromAppPolice2() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerTests-\(UUID().uuidString)")
		let old = tmp.appendingPathComponent("AppPolice"), new = tmp.appendingPathComponent("AppWrangler")
		try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
		try Data(#"[{"matchKind":"name","matchValue":"node","cpuLimitEnabled":true}]"#.utf8).write(to: old.appendingPathComponent("rules.json"))
		#expect(Migration.importAppPoliceRules(from: old, into: new))
		#expect(RuleStore(directory: new).rules.first?.matchValue == "node")
		#expect(!Migration.importAppPoliceRules(from: old, into: new), "never overwrites existing rules")
	}

	@Test func matcherOnlyIncludesRulesInEffect() {
		let store = tempStore()
		var a = AppRule(matchKind: .bundleID, matchValue: "com.a", displayName: "a")
		a.cpuLimitEnabled = true
		var b = AppRule(matchKind: .bundleID, matchValue: "com.b", displayName: "b")
		b.cpuLimitEnabled = true
		b.conditions.power = .battery
		let c = AppRule(matchKind: .bundleID, matchValue: "com.c", displayName: "c")	// no limits
		[a, b, c].forEach(store.upsert)
		#expect(store.matcher(for: SystemState()).bundleIDs == ["com.a"])
		var s = SystemState()
		s.onBattery = true
		#expect(store.matcher(for: s).bundleIDs == ["com.a", "com.b"])
	}

	@Test func summaryDescribesLimits() {
		var r = AppRule(matchKind: .name, matchValue: "x", displayName: "x")
		#expect(r.summary == "No limits")
		r.cpuLimitEnabled = true
		r.cpuLimit = 25
		r.backgroundMode = true
		r.conditions.power = .battery
		#expect(r.summary == "CPU 25% · E-cores — on battery")
	}
}

@Suite struct GroupingTests {
	let chrome = RunningApp(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome",
							bundlePath: "/Applications/Google Chrome.app", kind: .app)
	let terminal = RunningApp(pid: 200, bundleID: "com.apple.Terminal", name: "Terminal",
							  bundlePath: "/System/Applications/Utilities/Terminal.app", kind: .app)

	private var apps: [pid_t: RunningApp] { [100: chrome, 200: terminal] }

	@Test func helperInsideBundleJoinsItsApp() {
		let renderer = ProcIdent(ppid: 100, rpid: 100, uid: 501, name: "Google Chrome Helper (Renderer)",
								 path: "/Applications/Google Chrome.app/Contents/Frameworks/x.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
		#expect(Grouping.owner(of: 101, ident: renderer, apps: apps, idents: [:]) == 100)
	}

	@Test func shellStartedFromTerminalStaysSeparate() {
		let zsh = ProcIdent(ppid: 200, rpid: 200, uid: 501, name: "zsh", path: "/bin/zsh")
		#expect(Grouping.owner(of: 201, ident: zsh, apps: apps, idents: [:]) == nil)
	}

	@Test func xpcServiceJoinsResponsibleApp() {
		let web = ProcIdent(ppid: 1, rpid: 100, uid: 501, name: "com.apple.WebKit.WebContent",
							path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
		#expect(Grouping.owner(of: 300, ident: web, apps: apps, idents: [:]) == 100)
	}

	@Test func grandchildFoundThroughParentChain() {
		let child = ProcIdent(ppid: 150, rpid: 150, uid: 501, name: "gpu", path: "/Applications/Google Chrome.app/Contents/gpu")
		let parent = ProcIdent(ppid: 100, rpid: 100, uid: 501, name: "mid", path: "/Applications/Google Chrome.app/Contents/mid")
		#expect(Grouping.owner(of: 151, ident: child, apps: apps, idents: [150: parent]) == 100)
	}
}
