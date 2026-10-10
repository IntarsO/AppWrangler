//
//  PanelView.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  The menu bar panel: charts, what Auto is doing, cards for things that just
//  happened (each with a way to set the app up by hand), the busiest apps and
//  recent activity. The full list of apps lives in the main window.
//

import AppKit
import SwiftUI

struct PanelView: View {
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore
	@ObservedObject var log: ActivityLog
	var openSettings: () -> Void
	/// Opens the main window (all apps); with an app ID, shows that app.
	var openWindow: () -> Void

	@AppStorage(Prefs.autoEnabled) private var autoEnabled = true

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			if let room = model.roomFor { roomBanner(room) }
			charts
			TimelineView(.periodic(from: .now, by: 1)) { context in
				let cards = model.panelActions.visible(at: context.date)
				if !cards.isEmpty {
					VStack(spacing: 8) {
						ForEach(cards) { ActionCard(action: $0, model: model, now: context.date, open: openWindow) }
					}
					.padding(.horizontal, 12)
					.padding(.bottom, 10)
				}
			}
			if !model.advice.isEmpty { adviceLine }
			if !model.frozenApps.isEmpty { frozenList }
			Divider()
			topApps
			Divider()
			recent
			Divider()
			footer
		}
		.frame(width: 400)
		.fixedSize(horizontal: false, vertical: true)
	}

	// MARK: Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("AppWrangler").font(.headline)
				Text(SystemInfo.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
				Spacer()
				Toggle(isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 })) {
					Text(model.paused ? L("Paused") : L("Active")).font(.caption)
				}
				.toggleStyle(.switch)
				.controlSize(.mini)
				.help(L("Pause or resume all CPU limits (%@). Frozen apps stay frozen.", HotKey.display))
			}
			HStack(spacing: 6) {
				Toggle(isOn: $autoEnabled) {
					Label(L("Auto"), systemImage: "wand.and.stars").font(.caption.weight(.semibold))
				}
				.toggleStyle(.switch)
				.controlSize(.mini)
				.help(L("Auto mode keeps the app you're using at full speed, moves background apps to efficiency cores, and shares the CPU fairly when the Mac is busy."))
				Text(autoText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
				Spacer()
				HelpButton(anchor: "auto-mode").controlSize(.mini)
			}
			if !conditionsText.isEmpty {
				Label(conditionsText, systemImage: "bolt.badge.clock").font(.caption2).foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.top, 12)
		.padding(.bottom, 10)
	}

	private var autoText: String {
		guard autoEnabled else { return L("Off — only your rules apply") }
		let s = model.autoSummary
		var text = L("%d apps · %d in use · %d on E-cores", s.managed, s.inUse, s.onEfficiency)
		if s.away { return L("You're away · background apps run at full speed") }
		if s.runningFree > 0 { text += " · " + L("%d running free", s.runningFree) }
		if s.processes > 0 { text += " · " + L("%d processes held", s.processes) }
		let frozen = model.enforcer.frozen.count
		if frozen > 0 { text += " · " + L("%d frozen", frozen) }
		if s.busy { text += " · " + L("Mac busy") }
		return text
	}

	private var conditionsText: String {
		let s = model.systemState
		var parts: [String] = []
		if s.onBattery { parts.append(L("On battery")) }
		if s.lowPowerMode { parts.append(L("Low Power Mode")) }
		if s.isHot { parts.append(L("Mac is hot")) }
		return parts.joined(separator: " · ")
	}

	// MARK: Charts

	private var charts: some View {
		let points = model.systemHistory.points
		let memory = model.snapshot.memory
		let total = Double(max(SystemInfo.memsize, 1))
		let level = Int(memory.pressure_level)
		return HStack(spacing: 10) {
			ChartTile(
				title: L("CPU"),
				value: Fmt.percent(model.snapshot.systemCPU * Double(SystemInfo.ncpu)),
				caption: autoEnabled ? L("Green: on efficiency cores") : L("Last 10 min"),
				tint: .orange,
				points: points,
				metric: { $0.cpu },
				secondary: autoEnabled ? { $0.efficiency } : nil,
				shaded: nil)
			ChartTile(
				title: L("Memory"),
				value: Fmt.bytes(memory.used) + (level >= 4 ? " · " + L("critical") : level >= 2 ? " · " + L("pressure") : ""),
				valueTint: level >= 4 ? .red : level >= 2 ? .orange : .secondary,
				caption: points.contains { $0.pressure >= 2 } ? L("Shaded: short of memory") : L("Last 10 min"),
				tint: .purple,
				points: points,
				metric: { Double($0.memoryUsed) / total },
				secondary: nil,
				shaded: { $0.pressure >= 2 })
		}
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
	}

	// MARK: Suggestions

	private var adviceLine: some View {
		Button(action: openWindow) {
			HStack(spacing: 6) {
				Image(systemName: "lightbulb").foregroundStyle(.yellow)
				Text(L("Suggestions (%d)", model.advice.count)).font(.caption.weight(.semibold))
				if let first = model.advice.first {
					Text(first.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
				}
				Spacer()
				Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
		.help(L("Open the main window to see and apply suggestions"))
	}

	// MARK: Make room

	private func roomBanner(_ room: RoomFor) -> some View {
		TimelineView(.periodic(from: .now, by: 30)) { context in
			HStack(spacing: 8) {
				Image(systemName: "person.wave.2.fill").foregroundStyle(.green)
				VStack(alignment: .leading, spacing: 1) {
					Text(L("Making room for %@", room.name)).font(.caption.weight(.semibold))
					Text(room.remainingText(at: context.date) + " · " + L("everything else steps back"))
						.font(.caption2).foregroundStyle(.secondary)
				}
				Spacer()
				Button(L("Stop")) { model.stopMakingRoom() }.controlSize(.small)
			}
			.padding(8)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
		}
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
	}

	// MARK: Frozen

	/// Each frozen app with its own Unfreeze button. There's deliberately no "unfreeze all":
	/// you take back the one you need, and the rest stays tamed.
	private var frozenList: some View {
		let frozen = model.frozenApps
		return VStack(alignment: .leading, spacing: 3) {
			Text(L("Frozen (%d)", frozen.count)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
			ForEach(frozen.prefix(4), id: \.id) { app in
				HStack(spacing: 6) {
					Image(systemName: "snowflake").foregroundStyle(.cyan).font(.caption)
					Text(app.name).font(.caption).lineLimit(1)
					Text(app.reason.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
					Spacer(minLength: 4)
					Button(L("Unfreeze")) { model.unfreezeByYou(app.id) }.controlSize(.small)
				}
			}
			if frozen.count > 4 {
				Text(L("and %d more — right-click the menu bar icon", frozen.count - 4)).font(.caption2).foregroundStyle(.tertiary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
	}

	// MARK: Busiest apps

	private var topApps: some View {
		let me = getpid()
		let groups = model.snapshot.groups
			.filter { $0.measured && $0.ownerPid != me && $0.kind != .system }
			.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.footprint > $1.footprint }
			.prefix(5)
		return VStack(alignment: .leading, spacing: 2) {
			Text(L("Busiest apps")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
				.padding(.bottom, 2)
			if groups.isEmpty {
				Text(L("Measuring…")).font(.caption).foregroundStyle(.secondary)
			}
			ForEach(Array(groups)) { g in
				Button {
					model.focusRequest = g.id
					openWindow()
				} label: {
					HStack(spacing: 8) {
						Image(nsImage: IconCache.icon(for: g)).resizable().frame(width: 16, height: 16)
							.accessibilityHidden(true)
						Text(g.name).font(.caption).lineLimit(1)
						Text(state(of: g)).font(.caption2).foregroundStyle(stateTint(of: g)).lineLimit(1)
						Spacer(minLength: 4)
						Text(Fmt.percent(g.cpu)).font(.caption.monospacedDigit())
							.foregroundStyle(g.cpu > 1 ? .orange : .primary)
						Text(Fmt.bytes(g.footprint)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
							.frame(width: 58, alignment: .trailing)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help(L("Show %@ in the main window", g.name))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private func state(of g: AppGroup) -> String {
		if model.isFrozen(g) { return L("Frozen") }
		if let rule = rules.rule(for: g), rule.enabled, rule.hasLimits { return rule.summary }
		switch model.enforcer.autoDecisions[g.id] {
		case let d? where d.reason == .foreground || d.reason == .recent: return L("in use")
		case let d? where d.reason == .audio: return L("audio")
		case let d? where d.lifted: return L("running free")
		case let d? where d.cap != nil: return L("shared CPU")
		case let d? where d.efficiency: return L("E-cores")
		default: return ""
		}
	}

	private func stateTint(of g: AppGroup) -> Color {
		if model.isFrozen(g) { return .cyan }
		if let rule = rules.rule(for: g), rule.enabled, rule.hasLimits { return .orange }
		return model.enforcer.autoDecisions[g.id]?.efficiency == true ? .green : .teal
	}

	// MARK: Recent activity

	private var recent: some View {
		let events = log.events.prefix(3)
		return VStack(alignment: .leading, spacing: 3) {
			Text(L("Recently")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
			if events.isEmpty {
				Text(L("Nothing yet. AppWrangler lists here what it changes.")).font(.caption2).foregroundStyle(.secondary)
			}
			ForEach(Array(events)) { e in
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text(e.app).font(.caption.weight(.medium)).lineLimit(1).layoutPriority(1)
					Text(e.message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
					Spacer(minLength: 4)
					Text(e.date, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
						.lineLimit(1).fixedSize()
				}
				.help(e.message)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	// MARK: Footer

	private var footer: some View {
		HStack(spacing: 8) {
			let saved = model.stats.summary(days: 1).total.savedCPUSeconds
			Text(model.paused ? L("CPU limits paused") : saved >= 1 ? L("saved %@ today", Fmt.coreTime(saved)) : "")
				.font(.caption).foregroundStyle(.secondary).lineLimit(1)
				.help(L("See Settings → Impact for details"))
			Spacer()
			Button(action: openWindow) {
				Label(L("All apps"), systemImage: "macwindow")
			}
			.help(L("Open the full list of apps in a window that stays open, like Activity Monitor"))
			HelpButton(topic: .gettingStarted)
			Button(action: openSettings) { Image(systemName: "gearshape") }
				.buttonStyle(.borderless)
				.help(L("Settings…"))
				.accessibilityLabel(L("Settings…"))
			Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
				.buttonStyle(.borderless)
				.help(L("Quit"))
				.accessibilityLabel(L("Quit"))
		}
		.controlSize(.small)
		.padding(10)
	}
}

/// A card for something AppWrangler just did. It hides itself after 30 s;
/// until then you can keep it (Auto stays in charge) or set the app up by hand.
struct ActionCard: View {
	let action: PanelAction
	@ObservedObject var model: AppModel
	let now: Date
	let open: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .top, spacing: 8) {
				Image(systemName: icon).foregroundStyle(tint).font(.body)
				VStack(alignment: .leading, spacing: 2) {
					Text(action.title).font(.caption.weight(.semibold))
					Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 0)
			}
			HStack(spacing: 6) {
				Button(L("OK")) { model.dismissAction(action) }
					.help(L("Keep it this way"))
				if action.kind == .shed {
					Button(L("Resume now")) { model.resumeShed() }
						.help(L("Resume everything that was paused, and don't pause it again for 10 minutes"))
				}
				if action.kind == .runaway && !autoManaged {
					// Auto can't handle this one (Auto is off, or it isn't an app): offer what does.
					if !autoEnabled { Button(L("Turn on Auto")) { model.turnOnAuto() } }
					Button(L("E-cores")) { model.applySuggestion(.ecores, info: action.info) }
						.help(L("Move it to the efficiency cores while it's in the background"))
				}
				Button(L("Set manually…")) {
					model.showInWindow(action)
					open()
				}
				.help(L("Open %@'s settings in the main window", action.name))
				if action.kind == .autoFreeze || (action.kind == .runaway && autoManaged) {
					Button(L("Leave %@ alone", action.name)) { model.leaveAlone(action) }
						.help(L("Keep %@ out of Auto mode: never freeze it or move it to efficiency cores. Undo with appwrangler undo.", action.name))
				}
			}
			.controlSize(.small)
			ProgressView(value: action.remaining(at: now))
				.progressViewStyle(.linear)
				.tint(tint.opacity(0.6))
				.controlSize(.mini)
				.accessibilityHidden(true)
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
		.accessibilityElement(children: .contain)
	}

	/// Auto mode looks after this app (so a runaway in the background is on efficiency cores).
	private var autoManaged: Bool { model.autoManages(action.groupID) }
	@AppStorage(Prefs.autoEnabled) private var autoEnabled = true

	private var detail: String {
		guard action.kind == .runaway, autoManaged else { return action.detail }
		return action.detail + " " + L("Auto keeps it on efficiency cores while it's in the background.")
	}

	private var icon: String {
		switch action.kind {
		case .autoFreeze, .lowMemoryRule: return "snowflake"
		case .memoryRule: return "memorychip"
		case .runaway: return "flame.fill"
		case .shed: return "pause.circle"
		}
	}

	private var tint: Color {
		switch action.kind {
		case .autoFreeze, .lowMemoryRule: return .cyan
		case .memoryRule: return .purple
		case .runaway: return .orange
		case .shed: return .indigo
		}
	}
}

/// A small chart of the last 10 minutes, with an optional second line (dashed)
/// and shaded stretches (e.g. while the Mac was short of memory).
struct ChartTile: View {
	let title: String
	let value: String
	var valueTint: Color = .secondary
	let caption: String
	let tint: Color
	let points: [SystemPoint]
	let metric: (SystemPoint) -> Double
	let secondary: ((SystemPoint) -> Double)?
	let shaded: ((SystemPoint) -> Bool)?
	var window: TimeInterval = 600

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack {
				Text(title).font(.caption.weight(.semibold))
				Spacer()
				Text(value).font(.caption.monospacedDigit()).foregroundStyle(valueTint).lineLimit(1)
			}
			Canvas { context, size in
				guard let end = points.last?.time else { return }
				let start = end.addingTimeInterval(-window)
				func x(_ t: Date) -> CGFloat { size.width * CGFloat(t.timeIntervalSince(start) / window) }
				func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 1))) }
				if let shaded {
					for (i, p) in points.enumerated() where shaded(p) {
						let next = i + 1 < points.count ? points[i + 1].time : p.time.addingTimeInterval(2)
						context.fill(Path(CGRect(x: x(p.time), y: 0, width: max(1, x(next) - x(p.time)), height: size.height)),
									 with: .color(.orange.opacity(0.15)))
					}
				}
				var area = Path()
				var line = Path()
				for (i, p) in points.enumerated() {
					let pt = CGPoint(x: x(p.time), y: y(metric(p)))
					if i == 0 {
						line.move(to: pt)
						area.move(to: CGPoint(x: pt.x, y: size.height))
					} else {
						line.addLine(to: pt)
					}
					area.addLine(to: pt)
				}
				if let last = points.last { area.addLine(to: CGPoint(x: x(last.time), y: size.height)) }
				context.fill(area, with: .color(tint.opacity(0.18)))
				context.stroke(line, with: .color(tint), lineWidth: 1.5)
				if let secondary {
					var second = Path()
					for (i, p) in points.enumerated() {
						let pt = CGPoint(x: x(p.time), y: y(secondary(p)))
						i == 0 ? second.move(to: pt) : second.addLine(to: pt)
					}
					context.stroke(second, with: .color(.green), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
				}
			}
			.frame(height: 44)
			.background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
			Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
		}
		.padding(8)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(title + ", " + value)
	}
}
