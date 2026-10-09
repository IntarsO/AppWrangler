//
//  Demo.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Debug builds only: `-AWDemoFixture <file.json>` shows a made-up set of apps
//  and numbers (scripts/demo/fixture.json) instead of what's running, for
//  screenshots that don't reveal anyone's real apps. Nothing is measured or
//  enforced in this mode — no process is touched.
//

#if DEBUG
import Foundation
import ProcKit

struct DemoFixture: Decodable {
	struct App: Decodable {
		var name: String
		var bundleID: String?
		var path: String
		var kind: String			// app, background, system, process
		var cpu: Double				// cores
		var memoryMB: Double
		var helpers: Int
		var state: String			// in-use, audio, recent, ecores, frozen, none
	}

	var apps: [App]
	var systemCPU: Double
	var memoryUsedGB: Double
	var memoryTotalGB: Double
	var pressure: Int
	var swapUsedGB: Double
	var busy: Bool

	static func load(_ path: String) -> DemoFixture? {
		guard let data = FileManager.default.contents(atPath: path) else { return nil }
		return try? JSONDecoder().decode(DemoFixture.self, from: data)
	}
}

extension AppModel {
	/// A believable day of Impact numbers in the demo data folder (only if it has none).
	private func recordDemoStats() {
		guard stats.summary(days: 1).uptimeSeconds == 0 else { return }
		let now = Date()
		func tick(_ key: String, _ name: String, _ build: (inout ImpactTick) -> Void) -> ImpactTick {
			var t = ImpactTick(key: key, name: name); build(&t); return t
		}
		// Eight hours of a normal day, in 10-minute steps.
		for step in 0..<48 {
			let at = now.addingTimeInterval(-Double(48 - step) * 600)
			let short = (18..<26).contains(step)	// a memory squeeze in the afternoon
			var ticks = [
				tick("bundle:com.brave.Browser", "Brave Browser") { $0.efficiency = true; $0.power = 0.35; $0.cpu = 0.18 },
				tick("bundle:com.tinyspeck.slackmacgap", "Slack") { $0.efficiency = true; $0.power = 0.12; $0.cpu = 0.06 },
				tick("bundle:com.apple.mail", "Mail") { $0.efficiency = true; $0.power = 0.04; $0.cpu = 0.02 },
			]
			if step % 3 == 0 {
				ticks.append(tick("path:/opt/homebrew/bin/node", "node") { $0.throttle = (0.5, 1.3, 0.5); $0.cpu = 0.5; $0.power = 0.9 })
			}
			if short { ticks.append(tick("bundle:com.apple.Photos", "Photos") { $0.frozenDemand = 0.05 }) }
			stats.record(ticks, selfCPU: 0.004, selfFootprint: 46_000_000, dt: 600, at: at,
						 memory: MemorySample(pressure: short ? 2 : 1, swapUsedBytes: UInt64((short ? 2.4 : 1.1) * 1_073_741_824),
											  swapInBytes: short ? 95_000_000 : 4_000_000, memoryFrozenApps: short ? 2 : 0))
		}
		stats.record(.memoryFreeze(bytes: 880_000_000), key: "bundle:com.apple.Photos", name: "Photos", at: now.addingTimeInterval(-15_000))
		stats.record(.memoryFreeze(bytes: 520_000_000), key: "bundle:com.apple.Preview", name: "Preview", at: now.addingTimeInterval(-14_000))
	}

	func startDemo(_ fixture: DemoFixture) {
		var groups: [AppGroup] = []
		var decisions: [String: AutoDecision] = [:]
		var frozen: [String] = []
		var efficiency: [pid_t: String] = [:]
		var summary = AutoSummary()
		var nextPid: pid_t = 900_000
		for app in fixture.apps {
			let kind: AppKind = ["background": .background, "system": .system, "process": .process][app.kind] ?? .app
			let id = (kind == .process ? "proc:" : "app:") + (app.bundleID ?? app.name)
			var g = AppGroup(id: id, ownerPid: nextPid, name: app.name, bundleID: app.bundleID, path: app.path, kind: kind)
			let total = UInt64(app.memoryMB * 1_048_576)
			for i in 0...max(0, app.helpers) {
				let share = i == 0 ? total / 2 : total / 2 / UInt64(max(1, app.helpers))
				g.processes.append(ProcessStat(pid: nextPid + pid_t(i), name: i == 0 ? app.name : app.name + " Helper", path: app.path,
											   cpu: i == 0 ? app.cpu * 0.6 : app.cpu * 0.4 / Double(max(1, app.helpers)),
											   footprint: share, measured: true))
			}
			nextPid += pid_t(app.helpers + 1)
			g.cpu = app.cpu
			g.footprint = total
			g.power = app.cpu * 1.4
			g.threads = 12 + app.helpers * 6
			g.measured = true
			groups.append(g)
			switch app.state {
			case "in-use": decisions[id] = AutoDecision(reason: .foreground); summary.inUse += 1
			case "audio": decisions[id] = AutoDecision(reason: .audio); summary.inUse += 1
			case "recent": decisions[id] = AutoDecision(reason: .recent); summary.inUse += 1
			case "ecores":
				decisions[id] = AutoDecision(reason: .background, efficiency: true); summary.onEfficiency += 1
				for p in g.pids { efficiency[p] = id }
			case "frozen": frozen.append(id)
			default: break
			}
			if kind == .app || kind == .background { summary.managed += 1 }
		}
		summary.busy = fixture.busy
		recordDemoStats()
		var snap = Snapshot()
		snap.seq = 1
		snap.full = true
		snap.groups = groups
		snap.systemCPU = fixture.systemCPU
		snap.memory.used = UInt64(fixture.memoryUsedGB * 1_073_741_824)
		snap.memory.pressure_level = Int32(fixture.pressure)
		var state = SystemState()
		state.memoryPressure = fixture.pressure
		enforcer.setDemoState(decisions: decisions, frozen: frozen, efficiency: efficiency)
		setDemo(snapshot: snap, state: state, summary: summary,
				advice: Suggestions.make(SuggestionInput(
					groups: groups, rules: rules.rules, autoEnabled: true, frontmostPid: 900_000,
					memoryBytes: UInt64(fixture.memoryTotalGB * 1_073_741_824), memoryUsedBytes: snap.memory.used,
					memoryPressure: fixture.pressure, swapUsedBytes: UInt64(fixture.swapUsedGB * 1_073_741_824),
					autoFreezeIdle: true, fileExists: { _ in true })))
		recordDemoPanel(fixture, groups: groups)
	}

	/// Ten minutes of believable chart data, a card and recent activity.
	private func recordDemoPanel(_ fixture: DemoFixture, groups: [AppGroup]) {
		let now = Date()
		let gb = 1_073_741_824.0
		var points: [SystemPoint] = []
		for i in 0..<300 {	// every 2 s
			let t = Double(i) / 300
			let wave = 0.5 + 0.5 * sin(t * 19) * cos(t * 7)
			let cpu = fixture.systemCPU * (0.55 + 0.6 * wave) + (i > 120 && i < 150 ? 0.25 : 0)
			let memory = (fixture.memoryUsedGB - 0.9 + 0.9 * min(1, t * 1.4)) * gb
			points.append(SystemPoint(time: now.addingTimeInterval(-Double(300 - i) * 2), cpu: min(cpu, 1),
									  efficiency: cpu * (0.25 + 0.1 * wave), memoryUsed: UInt64(memory),
									  pressure: t > 0.62 ? fixture.pressure : 1))
		}
		var actions: [PanelAction] = []
		if let photos = groups.first(where: { $0.name == "Photos" }) {
			actions.append(PanelAction(date: now.addingTimeInterval(-40), kind: .autoFreeze, groupID: photos.id, name: photos.name,
									   bundleID: photos.bundleID, path: photos.path, title: L("Auto froze %@", photos.name),
									   detail: L("Mac is low on memory. It resumes when you switch to it.")))
		}
		let events = [
			ActivityEvent(date: now.addingTimeInterval(-40), app: "Photos", message: L("Mac is low on memory — frozen by Auto mode until you switch to it")),
			ActivityEvent(date: now.addingTimeInterval(-260), app: "Slack", message: L("Resumed — you switched to it")),
			ActivityEvent(date: now.addingTimeInterval(-540), app: "node", message: L("Has used %@ CPU for %d minutes in the background.", Fmt.percent(0.5), 5)),
		]
		setDemoPanel(history: points, actions: actions, events: events)
	}
}
#endif
