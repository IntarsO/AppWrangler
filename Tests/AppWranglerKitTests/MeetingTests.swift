//
//  MeetingTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

/// You're in a call when an app has been recording for a few seconds.
@Suite struct MeetingDetectorTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	@Test func aCallStartsAfterAFewSecondsOfRecordingAndEndsAMinuteAfterItStops() {
		let m = MeetingDetector()
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0) == nil, "a dictation hotkey isn't a call")
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 3) == nil)
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 6) == "app:brave")
		#expect(m.callSince == t0)
		// The mic drops out for a moment (muted, reconnecting): still the same call.
		#expect(m.update(recording: [], cameraOn: false, now: t0 + 30) == "app:brave")
		#expect(m.update(recording: [], cameraOn: false, now: t0 + 60) == "app:brave", "54 s of quiet isn't the end")
		#expect(m.update(recording: [], cameraOn: false, now: t0 + 70) == nil, "a minute of silence since the last recording: over")
	}

	@Test func theCameraKeepsACallGoingButCannotStartOne() {
		let m = MeetingDetector()
		#expect(m.update(recording: [], cameraOn: true, now: t0) == nil)
		#expect(m.update(recording: [], cameraOn: true, now: t0 + 10) == nil, "macOS doesn't say whose camera")
		_ = m.update(recording: ["app:zoom"], cameraOn: true, now: t0 + 20)
		#expect(m.update(recording: ["app:zoom"], cameraOn: true, now: t0 + 26) == "app:zoom")
		// Muted for ten minutes with the camera on: still in the call.
		#expect(m.update(recording: [], cameraOn: true, now: t0 + 600) == "app:zoom")
		#expect(m.update(recording: [], cameraOn: false, now: t0 + 700) == nil)
	}

	@Test func theFirstAppToRecordWinsAndAnotherWaitsItsTurn() {
		let m = MeetingDetector()
		_ = m.update(recording: ["app:zoom"], cameraOn: false, now: t0)
		_ = m.update(recording: ["app:zoom", "app:brave"], cameraOn: false, now: t0 + 2)
		#expect(m.update(recording: ["app:zoom", "app:brave"], cameraOn: false, now: t0 + 8) == "app:zoom")
		// Zoom ends; a minute later Brave's call takes over.
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 20) == "app:zoom", "Brave is still recording, so the quiet clock never started; Zoom is kept until its own silence")
		_ = m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 30)
		#expect(m.callGroupID == "app:zoom")
	}

	@Test func snoozingAnAppStopsItsCallAndKeepsItOutForHalfAnHour() {
		let m = MeetingDetector()
		_ = m.update(recording: ["app:brave"], cameraOn: false, now: t0)
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 6) == "app:brave")
		m.snooze("app:brave", for: 1800, now: t0 + 10)
		#expect(m.callGroupID == nil)
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 20) == nil)
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 1700) == nil)
		#expect(m.update(recording: ["app:brave"], cameraOn: false, now: t0 + 1900) == "app:brave")
	}

	@Test func theSignalsCanBeReadWithoutAPrompt() {
		_ = CameraActivity.isAnyCameraRunning()
		let a = AudioActivity.activity()
		#expect(a.input.isSubset(of: AudioActivity.activePids()))
	}

	@Test func anAutomaticRoomIsNeverSavedAndSaysWhileTheCallLasts() {
		let d = UserDefaults(suiteName: "AppWranglerRoomAuto-\(UUID().uuidString)")!
		let room = RoomFor(name: "Brave", bundleID: "com.brave.Browser", until: nil, automatic: true)
		RoomFor.save(room, d)
		#expect(RoomFor.load(d) == nil, "it ends with the call, not with a restart")
		#expect(room.remainingText() == "while the call lasts")
		#expect(room.isActive(at: .distantFuture))
	}
}

/// A process started by a prioritized app (a test run from Codex) is prioritized too.
@Suite struct SpawnedByTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	@Test func theSpawningAppIsFoundThroughShellsAndHelpers() {
		let codex = RunningApp(pid: 100, bundleID: "com.openai.codex", name: "ChatGPT", bundlePath: "/Applications/ChatGPT.app", kind: .app)
		let apps: [pid_t: RunningApp] = [100: codex]
		let idents: [pid_t: ProcIdent] = [
			100: ProcIdent(ppid: 1, rpid: 100, uid: 501, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
			200: ProcIdent(ppid: 100, rpid: 100, uid: 501, name: "Codex Helper", path: "/Applications/ChatGPT.app/Contents/Frameworks/x"),
			300: ProcIdent(ppid: 200, rpid: 300, uid: 501, name: "zsh", path: "/bin/zsh"),
			400: ProcIdent(ppid: 300, rpid: 400, uid: 501, name: "node", path: "/opt/homebrew/bin/node"),
			500: ProcIdent(ppid: 1, rpid: 500, uid: 501, name: "node", path: "/opt/homebrew/bin/node"),
		]
		#expect(Grouping.spawningApp(of: 400, ident: idents[400]!, apps: apps, idents: idents) == 100)
		#expect(Grouping.owner(of: 400, ident: idents[400]!, apps: apps, idents: idents) == nil, "but it isn't part of the app")
		#expect(Grouping.spawningApp(of: 500, ident: idents[500]!, apps: apps, idents: idents) == nil)
	}

	@Test func aPrioritizedProcessIsNeverHeldEvenWhenTheMacIsBusy() {
		let p = AutoPilot()
		let front = makeGroup(name: "Editor", bundleID: "com.example.editor", pid: 10, cpu: 0.2)
		var node = AppGroup(id: "proc:node", ownerPid: 400, name: "node", bundleID: nil, path: "/opt/homebrew/bin/node", kind: .process)
		node.processes = [ProcessStat(pid: 400, name: "node", path: node.path, footprint: 1, measured: true)]
		node.cpu = 2
		node.measured = true
		node.spawnedBy = 100
		for t in stride(from: 0.0, through: 60, by: 4) {
			let d = p.decide(groups: [front, node], frontmostPid: 10, lastActive: [:], audioPids: [], systemCPU: 0.95, onBattery: false,
							 ncpu: 8, priorities: [node.id: .high], now: t0 + t)
			#expect(d[node.id]?.reason == .priority && d[node.id]?.efficiency == false && d[node.id]?.cap == nil)
		}
	}
}

/// Making room for a browser: the tab you're in stays free; idle tabs' renderers step back.
@Suite struct GranularBrowserTests {
	@Test func idleRenderersGoToTheEfficiencyCoresButNotTheCallOrTheGPU() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		var brave = AppGroup(id: "app:com.brave.Browser", ownerPid: 100, name: "Brave Browser", bundleID: "com.brave.Browser",
							 path: "/Applications/Brave Browser.app", kind: .app)
		let helper = "/Applications/Brave Browser.app/Contents/Frameworks/x/Helpers/"
		brave.processes = [
			ProcessStat(pid: 100, name: "Brave Browser", path: brave.path, cpu: 0.3, footprint: 1, measured: true),
			ProcessStat(pid: 101, name: "Brave Browser Helper (GPU)", path: helper + "gpu", cpu: 0.01, footprint: 1, measured: true),
			ProcessStat(pid: 102, name: "Brave Browser Helper (Renderer)", path: helper + "r", cpu: 0.8, footprint: 1, measured: true),	// the Meet tab
			ProcessStat(pid: 103, name: "Brave Browser Helper (Renderer)", path: helper + "r", cpu: 0.0, footprint: 1, measured: true),	// an idle tab
			ProcessStat(pid: 104, name: "Brave Browser Helper (Renderer)", path: helper + "r", cpu: 0.0, footprint: 1, measured: true),	// recording
			ProcessStat(pid: 105, name: "Brave Browser Helper", path: helper + "net", cpu: 0.0, footprint: 1, measured: true),			// network
		]
		brave.measured = true
		e.exemptGroupID = brave.id
		e.apply(makeSnapshot([brave], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 1,
				auto: [brave.id: AutoDecision(reason: .room)], audioPids: [104])
		#expect(controller.background[103] == true, "an idle tab's renderer steps back")
		for pid: pid_t in [100, 101, 102, 104, 105] { #expect(controller.background[pid] != true, "\(pid) stays at full speed") }
		#expect(controller.limitedGroups.isEmpty && controller.frozenGroups.isEmpty)
		// Not when it's just a prioritized app without making room.
		let f = FakeController()
		let e2 = Enforcer(controller: f)
		e2.apply(makeSnapshot([brave], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 1,
				 auto: [brave.id: AutoDecision(reason: .priority)], audioPids: [104])
		#expect(f.background[103] != true)
	}
}

@Suite struct MemoryLeverTests {
	@Test func chromiumBrowsersGetAOneClickMemorySaver() {
		let action = Suggestions.memorySaverAction(bundleID: "com.brave.Browser", appName: "Brave Browser")
		#expect(action.tool == "browser_memory_saver" && action.arguments["bundle_id"] as? String == "com.brave.Browser")
		#expect(action.cli.contains("MemorySaverModeSavings -int 2") && action.cli.contains("\"meet.google.com\""))
		#expect(Suggestions.chromiumPolicyBundles.contains("com.google.Chrome") && !Suggestions.chromiumPolicyBundles.contains("com.apple.Safari"))
	}

	@Test func dockerGetsAMemoryTipNotABrowserOne() {
		let docker = makeGroup(name: "Docker", bundleID: "com.docker.docker", pid: 10, footprintMB: 3000)
		let input = SuggestionInput(groups: [docker], rules: [], autoEnabled: true, frontmostPid: 1, memoryBytes: 8 * 1_073_741_824,
									memoryUsedBytes: 7 * 1_073_741_824, memoryPressure: 2, swapUsedBytes: 4 * 1_073_741_824,
									onBattery: false, ncpu: 8, week: nil, fileExists: { _ in true })
		let hog = Suggestions.make(input).first { $0.id.hasPrefix("memory-hog:") }
		#expect(hog?.tip?.contains("Docker Desktop") == true && hog?.tip?.contains("tab sleeping") == false)
		#expect(hog?.actions.contains { $0.tool == "browser_memory_saver" } == false)
	}

	@Test func theMeetingSettingExists() {
		#expect(PreferenceSettings.specs.contains { $0.key == "auto_meeting" })
		#expect(AutoSettings().meeting)
	}
}
