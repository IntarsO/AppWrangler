//
//  MakeRoomTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

/// "Make room for" an app: it gets everything, the rest steps back.
@Suite struct MakeRoomAutoTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)
	let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.2)
	let zoom = makeGroup(name: "Zoom", bundleID: "us.zoom.xos", pid: 200, cpu: 2)
	let mail = makeGroup(name: "Mail", bundleID: "com.example.mail", pid: 300, cpu: 2)

	private func decide(_ p: AutoPilot, at t: TimeInterval, system: Double = 0.3, room: Bool = true, away: Bool = false,
						groups: [AppGroup]? = nil) -> [String: AutoDecision] {
		p.decide(groups: groups ?? [front, zoom, mail], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system,
				 onBattery: false, ncpu: 8, away: away, roomFor: room ? zoom.id : nil, now: t0 + t)
	}

	@Test func theAppGetsEverythingAndTheRestStepsBackAtOnce() {
		let p = AutoPilot()
		let d = decide(p, at: 0)
		#expect(d[zoom.id]?.reason == .room && d[zoom.id]?.efficiency == false && d[zoom.id]?.cap == nil)
		#expect(d[mail.id]?.efficiency == true, "no 30 s grace while making room")
		#expect(d[front.id] == AutoDecision(reason: .foreground), "the app in front is still the app in front")
		#expect(AutoDecision(reason: .room).label.contains("making room"))
	}

	@Test func theMacCountsAsBusySooner() {
		let p = AutoPilot(), q = AutoPilot()
		// 65% is "busy" while making room (75% otherwise).
		_ = decide(p, at: 0, system: 0.65)
		_ = decide(p, at: 2, system: 0.65)
		_ = decide(q, at: 0, system: 0.65, room: false)
		_ = decide(q, at: 2, system: 0.65, room: false)
		#expect(p.busy && !q.busy)
	}

	@Test func theRestSharesOneCoreLessAndTheAppIsNeverCapped() {
		// Editor 0.2 + Zoom 2 + a hungry background app 5 = 7.2 of 8 cores.
		let hog = makeGroup(name: "Hog", bundleID: "com.example.hog", pid: 400, cpu: 5)
		let groups = [front, zoom, hog]
		let p = AutoPilot(), q = AutoPilot()
		_ = decide(p, at: 0, system: 0.9, groups: groups)
		let making = decide(p, at: 2, system: 0.9, groups: groups)
		_ = decide(q, at: 0, system: 0.9, room: false, groups: groups)
		let normal = decide(q, at: 2, system: 0.9, room: false, groups: groups)
		let tight = making[hog.id]?.cap ?? 0, usual = normal[hog.id]?.cap ?? 0
		#expect(tight > 0 && usual > 0)
		#expect(abs((usual - tight) - 1) < 0.001, "one more core kept for the app")
		#expect(making[zoom.id]?.cap == nil)
	}

	@Test func nothingRunsFreeAndAwayIsIgnored() {
		let p = AutoPilot()
		for t in stride(from: 0.0, through: 60, by: 4) {
			let d = decide(p, at: t, away: true)
			#expect(d[mail.id]?.efficiency == true && d[mail.id]?.lifted == false && d[mail.id]?.away == false)
		}
	}

	@Test func hotProcessesStepBackWhileMakingRoomEvenOnACalmMac() {
		let p = AutoPilot()
		var node = AppGroup(id: "proc:node", ownerPid: 600, name: "node", bundleID: nil, path: "/opt/homebrew/bin/node", kind: .process)
		node.processes = [ProcessStat(pid: 600, name: "node", path: node.path, footprint: 1, measured: true)]
		node.cpu = 0.8
		node.measured = true
		_ = decide(p, at: 0, groups: [front, zoom, node])
		#expect(decide(p, at: 25, groups: [front, zoom, node])[node.id]?.efficiency == true)
	}

	@Test func ifTheAppIsntRunningNothingChanges() {
		let p = AutoPilot()
		let d = p.decide(groups: [front, mail], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.3,
						 onBattery: false, ncpu: 8, roomFor: "app:not.running", now: t0)
		#expect(d[mail.id]?.efficiency == false, "the usual grace")
	}
}

/// Prioritized apps get room, but not past the point where the Mac stalls.
@Suite struct PrioritizedTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	@Test func prioritizedAppsShareAllButOneCoreWhenTheMacIsSaturated() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.5)
		let a = makeGroup(name: "Render", bundleID: "com.example.render", pid: 200, cpu: 4)
		let b = makeGroup(name: "Encode", bundleID: "com.example.encode", pid: 300, cpu: 4)
		let prio: [String: AppPriority] = [a.id: .high, b.id: .high]
		func decide(_ t: TimeInterval, _ system: Double) -> [String: AutoDecision] {
			p.decide(groups: [front, a, b], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: system, onBattery: false,
					 ncpu: 8, priorities: prio, now: t0 + t)
		}
		let calm = decide(0, 0.5)
		#expect(calm[a.id]?.reason == .priority && calm[a.id]?.cap == nil)
		_ = decide(2, 0.98)
		let saturated = decide(4, 0.98)
		let caps = [saturated[a.id]?.cap, saturated[b.id]?.cap].compactMap { $0 }
		#expect(caps.count == 2)
		#expect(caps.reduce(0, +) <= 7.001, "one core stays free for the app in front")
		#expect(saturated[a.id]?.efficiency == false, "still never on the efficiency cores")
		#expect(saturated[a.id]?.label.contains("prioritized") == true)
	}

	@Test func aSinglePrioritizedAppWithinTheLimitIsLeftAlone() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 100, cpu: 0.5)
		let a = makeGroup(name: "Render", bundleID: "com.example.render", pid: 200, cpu: 3)
		_ = p.decide(groups: [front, a], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.98, onBattery: false,
					 ncpu: 8, priorities: [a.id: .high], now: t0)
		let d = p.decide(groups: [front, a], frontmostPid: 100, lastActive: [:], audioPids: [], systemCPU: 0.98, onBattery: false,
						 ncpu: 8, priorities: [a.id: .high], now: t0 + 2)
		#expect(d[a.id]?.cap == nil)
	}

	@Test func theTiersReadAsPrioritizedNormalAndCanWait() {
		#expect(AppPriority.allCases.map(\.title) == ["Prioritized", "Normal", "Can wait"])
	}
}

@Suite struct RoomForTests {
	@Test func durations() {
		#expect(RoomFor.parseDuration("30m") == 30)
		#expect(RoomFor.parseDuration("1h") == 60)
		#expect(RoomFor.parseDuration("1.5h") == 90)
		#expect(RoomFor.parseDuration("2h30m") == 150)
		#expect(RoomFor.parseDuration("45") == 45)
		#expect(RoomFor.parseDuration("until-stop") == 0)
		#expect(RoomFor.parseDuration("on") == 0)
		#expect(RoomFor.parseDuration("soon") == nil)
		#expect(RoomFor.parseDuration("30h") == nil, "at most a day")
		#expect(RoomFor.parseDuration("-5") == nil)
	}

	@Test func itEndsByItselfAndSurvivesARestart() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let room = RoomFor(name: "Zoom", bundleID: "us.zoom.xos", until: now.addingTimeInterval(3600))
		#expect(room.isActive(at: now) && !room.isActive(at: now.addingTimeInterval(3601)))
		#expect(RoomFor(name: "Zoom", bundleID: nil, until: nil).isActive(at: .distantFuture), "until you stop it")
		#expect(room.remainingText(at: now) == "1 h 0 min left")
		#expect(room.remainingText(at: now.addingTimeInterval(3600 - 47 * 60)) == "47 min left")

		let d = UserDefaults(suiteName: "AppWranglerRoom-\(UUID().uuidString)")!
		RoomFor.save(room, d)
		#expect(RoomFor.load(d, now: now) == room)
		#expect(RoomFor.load(d, now: now.addingTimeInterval(4000)) == nil, "an expired one isn't restored")
		RoomFor.save(nil, d)
		#expect(RoomFor.load(d, now: now) == nil)
	}

	@Test func itMatchesByBundleIDOrName() {
		let zoom = makeGroup(name: "zoom.us", bundleID: "us.zoom.xos", pid: 1)
		#expect(RoomFor(name: "Zoom", bundleID: "us.zoom.xos").matches(zoom))
		#expect(!RoomFor(name: "zoom.us", bundleID: "other.id").matches(zoom))
		#expect(RoomFor(name: "ZOOM.US", bundleID: nil).matches(zoom))
	}

	@Test func linksMakeAndStopRoom() {
		#expect(AppURL(URL(string: "appwrangler://make-room/Zoom?minutes=30")!) == .makeRoom(app: "Zoom", minutes: 30))
		#expect(AppURL(URL(string: "appwrangler://make-room/Google%20Chrome")!) == .makeRoom(app: "Google Chrome", minutes: 60))
		#expect(AppURL(URL(string: "appwrangler://make-room/Zoom?minutes=0")!) == .makeRoom(app: "Zoom", minutes: 0))
		#expect(AppURL(URL(string: "appwrangler://make-room/off")!) == .stopRoom)
		#expect(AppURL(URL(string: "appwrangler://make-room")!) == nil)
	}
}

@Suite struct MakeRoomCommandTests {
	private let apps = [RunningApp(pid: 999_999, bundleID: "us.zoom.xos", name: "Zoom", bundlePath: "/Applications/zoom.us.app", kind: .app)]

	private func run(_ args: [String]) -> (code: Int32, out: [String], sent: [(String, String?)]) {
		var out: [String] = [], sent: [(String, String?)] = []
		let code = CLI.run(args, store: tempStore(), apps: apps, print: { out.append($0) }, postToApp: { sent.append(($0, $1)); return true })
		return (code, out, sent)
	}

	@Test func makeRoomSendsTheAppAndTheDuration() {
		let r = run(["make-room", "Zoom", "30m"])
		#expect(r.code == 0 && r.sent.first?.0 == "make-room" && r.sent.first?.1 == "30.0|Zoom")
		#expect(run(["make-room", "Zoom"]).sent.first?.1 == "60.0|Zoom", "an hour by default")
		#expect(run(["make-room", "Zoom", "until-stop"]).sent.first?.1 == "0.0|Zoom")
		#expect(run(["make-room", "off"]).sent.first?.1 == "off")
	}

	@Test func mistakesAreReported() {
		#expect(run(["make-room", "Zoom", "soon"]).code != 0)
		let missing = run(["make-room", "Teams"])
		#expect(missing.code != 0 && missing.sent.isEmpty)
	}

	@Test func assistantsCanMakeRoomToo() throws {
		let server = MCPServer(readOnly: false, directory: FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerMCPRoom-\(UUID().uuidString)"),
							   runningApps: { self.apps }, postToApp: { _, _ in true }, sampleSeconds: 0.2)
		let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
		let data = try JSONSerialization.data(withJSONObject: request)
		let reply = server.handle(String(data: data, encoding: .utf8)!) ?? ""
		#expect(reply.contains("\"make_room\""))
	}
}

@Suite struct UnfreezeOneTests {
	@Test func somethingYouUnfrozeIsntPausedAgainStraightAway() {
		let s = Shedder()
		let t0 = Date(timeIntervalSince1970: 1_000_000)
		let c = Shedder.Candidate(id: "a", name: "a", cpu: 0.5, footprint: 1)
		_ = s.update([c], need: .cpu, now: t0)
		#expect(s.update([c], need: .cpu, now: t0 + 16).pause == ["a"])
		s.rest("a", for: 1800, now: t0 + 20)
		#expect(s.update([c], need: .cpu, now: t0 + 60).pause.isEmpty)
		#expect(s.update([c], need: .cpu, now: t0 + 1830).pause == ["a"])
	}

	@Test func everyFreezeHasAReason() {
		for r in [FreezeReason.manual, .memoryLimit, .memoryPressure, .idle, .shed] { #expect(!r.label.isEmpty) }
	}

	@Test func makingRoomSetsTheAppsOwnCPULimitAside() {
		let controller = FakeController()
		let store = tempStore()
		var rule = AppRule(matchKind: .bundleID, matchValue: "us.zoom.xos", displayName: "Zoom")
		rule.cpuLimitEnabled = true
		rule.cpuLimit = 25
		rule.onlyWhenInactive = false
		store.upsert(rule)
		let zoom = makeGroup(name: "Zoom", bundleID: "us.zoom.xos", pid: 200, cpu: 2)
		let e = Enforcer(controller: controller)
		e.apply(makeSnapshot([zoom], seq: 1), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(!controller.limitedGroups.isEmpty, "its rule limits it normally")
		e.exemptGroupID = zoom.id
		e.apply(makeSnapshot([zoom], seq: 2), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(controller.limitedGroups.isEmpty, "not while making room for it")
	}
}
