//
//  AuditFixTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Regression tests for the second audit's findings.
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct AuditFixTests {
	// #1 — huge numbers from a file, CLI or MCP must not crash conversions.
	@Test func absurdNumbersAreClampedOnLoadAndSave() throws {
		let json = #"[{"matchKind":"name","matchValue":"x","cpuLimitEnabled":true,"cpuLimit":1e19,"memoryLimitEnabled":true,"memoryLimitMB":-5}]"#
		let r = try JSONDecoder().decode([AppRule].self, from: Data(json.utf8))[0]
		#expect(r.cpuLimit == AppRule.cpuLimitRange.upperBound)
		#expect(r.memoryLimitMB == AppRule.memoryLimitRange.lowerBound)
		#expect(!r.summary.isEmpty)
		let store = tempStore()
		var big = AppRule(matchKind: .name, matchValue: "y", displayName: "y")
		big.memoryLimitMB = 1e300
		store.upsert(big)
		#expect(store.rules[0].memoryLimitMB == AppRule.memoryLimitRange.upperBound)
	}

	@Test func cliRejectsAbsurdOrEmptyInput() {
		let store = tempStore()
		func run(_ a: String...) -> Int32 { CLI.run(a, store: store, apps: [], print: { _ in }, postToApp: { _, _ in true }) }
		#expect(run("memlimit", "Safari", "1e14") == 1)
		#expect(run("memlimit", "Safari", "inf") == 1)
		#expect(run("limit", "Safari", "nan") == 1)
		#expect(run("limit", "", "50") == 1)
		#expect(store.rules.isEmpty)
	}

	// #12 — updating a limit keeps "background only" unless asked.
	@Test func cliLimitKeepsBackgroundOnly() {
		let store = tempStore()
		func run(_ a: String...) { _ = CLI.run(a, store: store, apps: [], print: { _ in }, postToApp: { _, _ in true }) }
		run("limit", "node", "40")
		#expect(store.rules[0].onlyWhenInactive, "new rules are background-only")
		run("limit", "node", "60")
		#expect(store.rules[0].onlyWhenInactive, "still background-only after an update")
		run("limit", "node", "60", "--always")
		#expect(!store.rules[0].onlyWhenInactive)
	}

	// #3 — never SIGSTOP a shell's foreground job.
	@Test func terminalForegroundJobsAreNotStopped() {
		let controller = FakeController()
		let store = tempStore()
		var r = AppRule(matchKind: .name, matchValue: "node", displayName: "node")
		r.cpuLimitEnabled = true
		r.backgroundMode = true
		r.onlyWhenInactive = false
		store.upsert(r)
		controller.terminalJobs = [7000]
		var events: [String] = []
		let e = Enforcer(controller: controller)
		e.onEvent = { _, m, _ in events.append(m) }
		let node = makeGroup(name: "node", bundleID: nil, pid: 7000, kind: .process)
		e.apply(makeSnapshot([node], seq: 1), rules: store, state: SystemState(), frontmostPid: 0)
		#expect(controller.groups.isEmpty, "no SIGSTOP-based limit")
		#expect(controller.background[7000] == true, "efficiency cores still apply")
		#expect(events.count == 1)
	}

	// #14 — a frozen app that's relaunched starts unfrozen.
	@Test func relaunchedAppIsNotFrozen() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		let old = makeGroup(pid: 100)
		e.freeze(old)
		controller.alive = []
		let relaunched = makeGroup(pid: 200)
		e.apply(makeSnapshot([relaunched], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 0)
		#expect(!e.isFrozen(relaunched.id))
		#expect(controller.frozenGroups.isEmpty)
	}

	// #6 — low-memory actions spare apps using audio even without Auto.
	@Test func lowMemorySparesAudioAppsWithoutAuto() {
		let controller = FakeController()
		let store = tempStore()
		var r = AppRule(matchKind: .bundleID, matchValue: "com.example.test", displayName: "T")
		r.pressureAction = .quit
		store.upsert(r)
		var state = SystemState()
		state.memoryPressure = 4
		let e = Enforcer(controller: controller)
		e.apply(makeSnapshot([makeGroup(helpers: [50_001])], seq: 1), rules: store, state: state, frontmostPid: 0, audioPids: [50_001])
		#expect(controller.terminated.isEmpty)
	}

	// #5 — bookkeeping for vanished processes is pruned.
	@Test func bookkeepingDoesNotGrowWithShortLivedProcesses() {
		let e = Enforcer(controller: FakeController())
		for i in 0..<500 {
			let p = makeGroup(name: "build\(i)", bundleID: nil, pid: pid_t(10_000 + i), kind: .process)
			e.apply(makeSnapshot([p], seq: UInt64(i + 1)), rules: tempStore(), state: SystemState(), frontmostPid: 0)
		}
		#expect(e.knownGroup(matching: "build0") == nil)
		#expect(e.knownGroup(matching: "build499") != nil)
	}

	// #19 + E-core timing.
	@Test func foregroundIsDetectedByAnyProcessAndEcoresStartWhenYouLeave() {
		let p = AutoPilot()
		p.settings.efficiencyAfter = 30
		p.settings.focusGrace = 15
		let t0 = Date(timeIntervalSince1970: 2_000_000)
		let app = makeGroup(name: "A", bundleID: "com.example.a", pid: 300, helpers: [301])
		#expect(p.decide(groups: [app], frontmostPid: 301, lastActive: [:], audioPids: [], systemCPU: 0, onBattery: false, ncpu: 8, now: t0)[app.id]?.reason == .foreground)
		// Left at t0; at t0+20 it's past the grace; E-cores at t0+30, not t0+45.
		var d = p.decide(groups: [app], frontmostPid: 1, lastActive: [300: t0], audioPids: [], systemCPU: 0, onBattery: false, ncpu: 8, now: t0 + 20)
		#expect(d[app.id]?.efficiency == false)
		d = p.decide(groups: [app], frontmostPid: 1, lastActive: [300: t0], audioPids: [], systemCPU: 0, onBattery: false, ncpu: 8, now: t0 + 31)
		#expect(d[app.id]?.efficiency == true)
	}

	// #10 — quick extra samples don't count towards "busy".
	@Test func quickSamplesDontFlipBusy() {
		let p = AutoPilot()
		let t0 = Date(timeIntervalSince1970: 3_000_000)
		let g = makeGroup(cpu: 1)
		for i in 0..<5 {
			_ = p.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + Double(i) * 0.05)
		}
		#expect(!p.busy, "five samples within 0.25 s are one sample")
		_ = p.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 1)
		#expect(p.busy)
		// A middle-band reading breaks the streak.
		let q = AutoPilot()
		_ = q.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0)
		_ = q.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.7, onBattery: false, ncpu: 8, now: t0 + 1)
		_ = q.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false, ncpu: 8, now: t0 + 2)
		#expect(!q.busy)
	}

	// #11 — turning Auto off forgets old decisions.
	@Test func disablingAutoResetsState() {
		let p = AutoPilot()
		let g = makeGroup()
		_ = p.decide(groups: [g], frontmostPid: 1, lastActive: [:], audioPids: [], systemCPU: 0, onBattery: false, ncpu: 8)
		#expect(!p.decisions.isEmpty)
		p.reset()
		#expect(p.decisions.isEmpty && !p.busy)
		#expect(p.refocus(frontmostPid: 1, lastActive: [:]).isEmpty)
	}

	// #7, #16 — MCP robustness.
	@Test func mcpRejectsBadInputWithoutCrashing() throws {
		let s = MCPServer(readOnly: false, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
						  runningApps: { [] }, postToApp: { _, _ in true }, sampleSeconds: 0.2)
		func reply(_ line: String) throws -> [String: Any] {
			try JSONSerialization.jsonObject(with: Data(s.handle(line)!.utf8)) as! [String: Any]
		}
		let neg = try reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_apps","arguments":{"limit":-1}}}"#)
		#expect(neg["result"] != nil, "clamped, not crashed")
		let batch = try reply(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
		#expect((batch["error"] as? [String: Any])?["code"] as? Int == -32600)
		let missing = try reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_cpu_limit","arguments":{"percent":10}}}"#)
		#expect((missing["error"] as? [String: Any])?["code"] as? Int == -32602)
		let empty = try reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remove_rule","arguments":{"app":"  "}}}"#)
		#expect((empty["error"] as? [String: Any])?["code"] as? Int == -32602)
	}

	@Test func commandsCarryTheirDataFolder() {
		#expect(IPC.isForThisInstance(["command": "x", "dataDir": IPC.dataDirKey]))
	}
}
