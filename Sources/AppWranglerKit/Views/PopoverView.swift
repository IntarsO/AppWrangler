//
//  PopoverView.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//

import AppKit
import ProcKit
import SwiftUI

enum IconCache {
	private static var cache: [String: NSImage] = [:]
	private static let processIcon: NSImage = {
		let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
		image.isTemplate = true
		return image
	}()

	static func icon(for group: AppGroup) -> NSImage {
		if let cached = cache[group.id] { return cached }
		let image: NSImage
		if group.isApp {
			image = NSRunningApplication(processIdentifier: group.ownerPid)?.icon
				?? NSWorkspace.shared.icon(forFile: group.path)
		} else if group.path.contains(".app/") {
			// A helper inside some app bundle: show that app's icon.
			let bundle = group.path.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? group.path
			image = NSWorkspace.shared.icon(forFile: bundle)
		} else {
			image = processIcon
		}
		if cache.count > 800 { cache.removeAll() }
		cache[group.id] = image
		return image
	}
}

/// Keeps rows from jumping around under the pointer: the order is only
/// recomputed while you're not hovering the list or editing a row.
final class StableOrder: ObservableObject {
	@Published private(set) var ids: [String] = []

	func update(with sorted: [String], frozen: Bool) {
		if !frozen || ids.isEmpty {
			ids = sorted
			return
		}
		let present = Set(sorted)
		var next = ids.filter { present.contains($0) }
		let known = Set(next)
		next.append(contentsOf: sorted.filter { !known.contains($0) })
		ids = next
	}
}

struct PopoverView: View {
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore
	var openSettings: () -> Void

	@AppStorage(Prefs.sortBy) private var sortRaw = SortKey.cpu.rawValue
	@AppStorage(Prefs.collapsedSections) private var collapsedRaw = ""
	@Local private var search = ""
	@Local private var expanded: String?
	@Local private var hovering = false
	@StateObject private var order = StableOrder()

	private var sortKey: SortKey { SortKey(rawValue: sortRaw) ?? .cpu }

	private var collapsed: Set<Int> {
		Set(collapsedRaw.split(separator: ",").compactMap { Int($0) })
	}

	private func toggleSection(_ kind: AppKind) {
		var set = collapsed
		if set.contains(kind.rawValue) { set.remove(kind.rawValue) } else { set.insert(kind.rawValue) }
		collapsedRaw = set.sorted().map(String.init).joined(separator: ",")
	}

	private func sortedIDs(_ list: [AppGroup]) -> [String] {
		list.sorted { a, b in
			switch sortKey {
			case .cpu: return a.cpu != b.cpu ? a.cpu > b.cpu : a.name < b.name
			case .memory: return a.footprint > b.footprint
			case .power: return a.power != b.power ? a.power > b.power : a.cpu > b.cpu
			case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
			}
		}.map(\.id)
	}

	private var filtered: [AppGroup] {
		guard !search.isEmpty else { return model.snapshot.groups }
		return model.snapshot.groups.filter { g in
			g.name.localizedCaseInsensitiveContains(search)
				|| (g.bundleID?.localizedCaseInsensitiveContains(search) ?? false)
				|| ProcessCatalog.describe(g).summary.localizedCaseInsensitiveContains(search)
		}
	}

	private func refreshOrder() {
		#if DEBUG
		if expanded == nil, let name = UserDefaults.standard.string(forKey: "AWDebugExpand") {
			expanded = model.snapshot.groups.first { $0.name == name }?.id
		}
		#endif
		order.update(with: sortedIDs(model.snapshot.groups), frozen: hovering || expanded != nil)
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			if !model.suggestions.isEmpty { suggestionsBanner }
			Divider()
			toolbar
			Divider()
			list
			Divider()
			footer
		}
		.frame(width: 480, height: 660)
		.onChange(of: model.snapshot.seq) { _ in refreshOrder() }
		.onChange(of: sortRaw) { _ in order.update(with: sortedIDs(model.snapshot.groups), frozen: false) }
		.onAppear { order.update(with: sortedIDs(model.snapshot.groups), frozen: false) }
	}

	// MARK: Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("AppWrangler").font(.headline)
				Text(SystemInfo.summary).font(.caption).foregroundStyle(.secondary)
				Spacer()
				Toggle(isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 })) {
					Text(model.paused ? L("Paused") : L("Active")).font(.caption)
				}
				.toggleStyle(.switch)
				.controlSize(.mini)
				.help(L("Pause or resume all CPU limits (%@). Frozen apps stay frozen.", HotKey.display))
			}
			HStack(spacing: 14) {
				Meter(title: L("CPU"), value: model.snapshot.systemCPU,
					  text: L("%@ of %d%%", Fmt.percent(model.snapshot.systemCPU * Double(SystemInfo.ncpu)), SystemInfo.ncpu * 100))
				let used = Double(model.snapshot.memory.used) / Double(max(SystemInfo.memsize, 1))
				Meter(title: L("Memory"), value: used, text: Fmt.bytes(model.snapshot.memory.used) + pressureText,
					  tint: model.snapshot.memory.pressure_level >= 4 ? .red : model.snapshot.memory.pressure_level >= 2 ? .orange : .accentColor)
			}
			if !conditionsText.isEmpty {
				Label(conditionsText, systemImage: "bolt.badge.clock")
					.font(.caption2).foregroundStyle(.secondary)
			}
		}
		.padding(12)
	}

	private var conditionsText: String {
		let s = model.systemState
		var parts: [String] = []
		if s.onBattery { parts.append(L("On battery")) }
		if s.lowPowerMode { parts.append(L("Low Power Mode")) }
		if s.isHot { parts.append(L("Mac is hot")) }
		return parts.joined(separator: " · ")
	}

	private var pressureText: String {
		switch model.snapshot.memory.pressure_level {
		case 4: return " · " + L("critical")
		case 2: return " · " + L("pressure")
		default: return ""
		}
	}

	private var suggestionsBanner: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(model.suggestions) { s in
				HStack(spacing: 8) {
					Image(systemName: "flame.fill").foregroundStyle(.orange)
					VStack(alignment: .leading, spacing: 1) {
						Text(L("%@ is using a lot of CPU", s.name)).font(.caption.weight(.semibold))
						Text(L("Has used %@ CPU for %d minutes in the background.", Fmt.percent(s.averageCPU), s.minutes))
							.font(.caption2).foregroundStyle(.secondary)
					}
					Spacer()
					Button(L("Limit 50%")) { model.applySuggestion(.limit50, info: info(s)) }
					Button(L("E-cores")) { model.applySuggestion(.ecores, info: info(s)) }
					Button { model.dismissSuggestion(s) } label: { Image(systemName: "xmark") }
						.buttonStyle(.borderless)
						.accessibilityLabel(L("Dismiss"))
				}
				.controlSize(.small)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Color.orange.opacity(0.1))
	}

	private func info(_ s: RunawaySuggestion) -> [String: String] {
		["groupID": s.groupID, "name": s.name, "bundleID": s.bundleID ?? "", "path": s.path]
	}

	// MARK: Toolbar

	private var toolbar: some View {
		HStack(spacing: 8) {
			HStack(spacing: 4) {
				Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
				TextField(L("Search apps and processes"), text: $search).textFieldStyle(.plain)
				if !search.isEmpty {
					Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
						.buttonStyle(.plain).foregroundStyle(.secondary)
						.accessibilityLabel(L("Clear search"))
				}
			}
			.padding(5)
			.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

			Picker(L("Sort by"), selection: $sortRaw) {
				ForEach(SortKey.allCases) { Text($0.label).tag($0.rawValue) }
			}
			.labelsHidden()
			.fixedSize()
			.help(L("Sort by"))
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	// MARK: List

	private var list: some View {
		let groups = filtered
		let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
		let ordered = order.ids.compactMap { byID[$0] } + groups.filter { !order.ids.contains($0.id) }
		return ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				ForEach(AppKind.allCases) { kind in
					let items = ordered.filter { $0.kind == kind }
					if !items.isEmpty {
						Section {
							if !collapsed.contains(kind.rawValue) || !search.isEmpty {
								ForEach(items) { row($0) }
							}
						} header: {
							sectionHeader(kind, count: items.count)
						}
					}
				}
				if groups.isEmpty {
					Text(search.isEmpty ? L("Measuring…") : L("Nothing matches “%@”", search))
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity)
						.padding(30)
				}
			}
		}
		.onHover { inside in
			hovering = inside
			if !inside { refreshOrder() }
		}
	}

	private func sectionHeader(_ kind: AppKind, count: Int) -> some View {
		Button { toggleSection(kind) } label: {
			HStack(spacing: 6) {
				Image(systemName: "chevron.right")
					.rotationEffect(.degrees(collapsed.contains(kind.rawValue) && search.isEmpty ? 0 : 90))
					.font(.caption2)
				Text(kind.title).font(.caption.weight(.semibold))
				Text("\(count)").font(.caption2).foregroundStyle(.secondary)
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 5)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.background(.bar)
		.accessibilityLabel(L("%@, %d items", kind.title, count))
	}

	@ViewBuilder
	private func row(_ group: AppGroup) -> some View {
		let isExpanded = expanded == group.id
		GroupRow(group: group, model: model, rules: rules, expanded: isExpanded)
			.contentShape(Rectangle())
			.onTapGesture { toggle(group.id) }
			.contextMenu { RowMenu(group: group, model: model, rules: rules) }
		if isExpanded {
			GroupDetail(group: group, model: model, rules: rules)
				.padding(.horizontal, 14)
				.padding(.bottom, 12)
				.background(Color.primary.opacity(0.03))
		}
		Divider().opacity(0.5)
	}

	private func toggle(_ id: String) {
		withAnimation(.easeOut(duration: 0.15)) {
			expanded = expanded == id ? nil : id
		}
		if expanded == nil { refreshOrder() }
	}

	// MARK: Footer

	private var footer: some View {
		HStack {
			let active = rules.rules.filter(\.isActive).count
			Text(model.paused ? L("CPU limits paused") : L("%d active rules", active))
				.font(.caption).foregroundStyle(.secondary)
			Spacer()
			Button(L("Settings…"), action: openSettings)
			Button(L("Quit")) { NSApp.terminate(nil) }
		}
		.padding(10)
	}
}

struct RowMenu: View {
	let group: AppGroup
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore

	var body: some View {
		if Protected.contains(group) {
			Text(L("Critical to macOS — AppWrangler won't limit it"))
		} else {
			Menu(L("Limit CPU")) {
				ForEach([10.0, 25, 50, 100, 200], id: \.self) { v in
					Button("\(Int(v))%") { model.quickLimit(group, cpu: v) }
				}
				if rules.rule(for: group)?.cpuLimitEnabled == true {
					Divider()
					Button(L("No CPU limit")) { model.quickLimit(group, cpu: nil) }
				}
			}
			Button(rules.rule(for: group)?.backgroundMode == true ? L("Stop using efficiency cores only") : L("Efficiency cores only")) {
				model.toggleEfficiency(group)
			}
			Divider()
			if model.isFrozen(group) {
				Button(L("Unfreeze")) { model.unfreeze(group) }
			} else {
				Button(L("Freeze")) { model.freeze(group) }
			}
			Button(L("Quit")) { model.quit(group) }
			Button(L("Force Quit")) { model.forceQuit(group) }
			if let rule = rules.rule(for: group) {
				Divider()
				Button(L("Remove Rule")) { rules.remove(id: rule.id) }
			}
		}
		Divider()
		if !group.path.isEmpty {
			Button(L("Show in Finder")) { NSWorkspace.shared.selectFile(group.path, inFileViewerRootedAtPath: "") }
		}
		Button(L("Copy Name")) {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(group.bundleID ?? group.name, forType: .string)
		}
	}
}

struct Meter: View {
	let title: String
	let value: Double
	let text: String
	var tint: Color = .accentColor

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack {
				Text(title).font(.caption.weight(.semibold))
				Spacer()
				Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
			}
			ProgressView(value: min(max(value, 0), 1)).tint(tint)
		}
		.accessibilityElement(children: .combine)
	}
}

struct GroupRow: View {
	let group: AppGroup
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore
	let expanded: Bool

	var body: some View {
		let rule = rules.rule(for: group)
		let frozen = model.isFrozen(group)
		let status = model.limiterStatus[group.id]
		let description = ProcessCatalog.describe(group)
		HStack(spacing: 8) {
			Image(systemName: "chevron.right")
				.font(.caption2)
				.rotationEffect(.degrees(expanded ? 90 : 0))
				.foregroundStyle(.tertiary)
				.accessibilityHidden(true)
			Image(nsImage: IconCache.icon(for: group))
				.resizable()
				.frame(width: 22, height: 22)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(group.name).lineLimit(1)
					if group.processes.count > 1 {
						Text("+\(group.processes.count - 1)")
							.font(.caption2).foregroundStyle(.secondary)
							.help(L("%d helper processes", group.processes.count - 1))
					}
				}
				if let rule, rule.enabled, rule.hasLimits {
					Text(rule.summary).font(.caption2).foregroundStyle(.orange).lineLimit(1)
				} else {
					Text(description.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
				}
			}
			Spacer(minLength: 4)
			badges(rule: rule, frozen: frozen, status: status)
			VStack(alignment: .trailing, spacing: 1) {
				Text(group.measured ? Fmt.percent(group.cpu) : "—")
					.font(.callout.monospacedDigit())
					.foregroundStyle(group.cpu > 1 ? .orange : .primary)
				Text(group.measured ? Fmt.bytes(group.footprint) : "")
					.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
			}
			.frame(width: 70, alignment: .trailing)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.help(description.summary + (description.detail.map { "\n" + $0 } ?? ""))
		.accessibilityElement(children: .combine)
		.accessibilityLabel(accessibilityText(rule: rule, frozen: frozen, description: description))
		.accessibilityHint(L("Shows details and limits"))
	}

	private func accessibilityText(rule: AppRule?, frozen: Bool, description: AppDescription) -> String {
		var parts = [group.name, description.summary, L("CPU %@", Fmt.percent(group.cpu)), L("memory %@", Fmt.bytes(group.footprint))]
		if frozen { parts.append(L("Frozen")) }
		if let rule, rule.enabled, rule.hasLimits { parts.append(rule.summary) }
		return parts.joined(separator: ", ")
	}

	@ViewBuilder
	private func badges(rule: AppRule?, frozen: Bool, status: pk_lim_status?) -> some View {
		HStack(spacing: 4) {
			if frozen {
				Image(systemName: "snowflake").foregroundStyle(.cyan).help(L("Frozen"))
					.accessibilityLabel(L("Frozen"))
			} else if let status, status.denied != 0 {
				Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(L("Permission denied"))
					.accessibilityLabel(L("Permission denied"))
			} else if status != nil {
				Image(systemName: "gauge.with.dots.needle.33percent")
					.foregroundStyle(model.paused ? Color.secondary : Color.orange)
					.help(model.paused ? L("Limit paused") : L("CPU limited"))
					.accessibilityLabel(model.paused ? L("Limit paused") : L("CPU limited"))
			}
			if model.enforcer.isInBackgroundMode(group) {
				Image(systemName: "leaf.fill").foregroundStyle(.green).help(L("Efficiency cores"))
					.accessibilityLabel(L("Efficiency cores"))
			}
			if rule?.enabled == true && rule?.memoryLimitEnabled == true {
				Image(systemName: "memorychip").foregroundStyle(.purple).help(L("Memory limit"))
					.accessibilityLabel(L("Memory limit"))
			}
		}
		.font(.caption)
	}
}

struct Sparkline: View {
	let values: [Double]
	let color: Color

	var body: some View {
		GeometryReader { geo in
			let maxV = max(values.max() ?? 0, 0.0001)
			Path { p in
				guard values.count > 1 else { return }
				for (i, v) in values.enumerated() {
					let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
					let y = geo.size.height * (1 - CGFloat(v / maxV))
					i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
				}
			}
			.stroke(color, lineWidth: 1.5)
		}
	}
}

struct GroupDetail: View {
	let group: AppGroup
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore
	@Local private var showProcesses = false
	@Local private var confirmForceQuit = false

	private var ruleBinding: Binding<AppRule> {
		let draft = AppRule.forGroup(group)
		return Binding(
			get: { rules.rule(for: group) ?? draft },
			set: { rules.upsert($0) })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			about
			stats
			chart
			limiterLine
			if Protected.contains(group) {
				Label(L("Critical to macOS — AppWrangler won't limit it"), systemImage: "lock.fill")
					.font(.caption).foregroundStyle(.secondary)
			} else {
				Text(L("Changes apply immediately.")).font(.caption2).foregroundStyle(.secondary)
				RuleEditor(rule: ruleBinding)
				actions
			}
			if group.processes.count > 1 {
				DisclosureGroup(L("Processes (%d)", group.processes.count), isExpanded: $showProcesses) {
					VStack(spacing: 2) {
						ForEach(group.processes) { p in
							HStack {
								Text(p.name).lineLimit(1).truncationMode(.middle)
								Text("\(p.pid)").foregroundStyle(.tertiary)
								Spacer()
								Text(Fmt.percent(p.cpu)).frame(width: 50, alignment: .trailing)
								Text(Fmt.bytes(p.footprint)).frame(width: 70, alignment: .trailing)
							}
							.font(.caption.monospacedDigit())
							.help(p.path)
						}
					}
					.padding(.top, 4)
				}
				.font(.caption)
			}
		}
		.padding(.top, 6)
	}

	private var about: some View {
		let d = ProcessCatalog.describe(group)
		return VStack(alignment: .leading, spacing: 3) {
			HStack(spacing: 6) {
				Text(group.kind.shortTitle).font(.caption2.weight(.semibold))
					.padding(.horizontal, 5).padding(.vertical, 1)
					.background(Capsule().fill(Color.secondary.opacity(0.2)))
				if let vendor = d.vendor { Text(vendor).font(.caption2).foregroundStyle(.secondary) }
			}
			Text(d.summary).font(.callout)
			if let detail = d.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
			Label(d.safety.label, systemImage: d.safety == .safe ? "checkmark.shield" : d.safety == .caution ? "exclamationmark.shield" : "lock.shield")
				.font(.caption2)
				.foregroundStyle(d.safety == .safe ? Color.green : d.safety == .caution ? Color.orange : Color.red)
			if !group.path.isEmpty {
				Text(group.bundleID.map { "\($0) — \(group.path)" } ?? group.path)
					.font(.caption2.monospaced()).foregroundStyle(.tertiary)
					.lineLimit(1).truncationMode(.middle)
					.textSelection(.enabled)
			}
		}
	}

	private var stats: some View {
		Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
			GridRow {
				stat(L("CPU"), Fmt.percent(group.cpu))
				stat(L("Memory"), Fmt.bytes(group.footprint))
				stat(L("Energy"), Fmt.watts(group.power))
			}
			GridRow {
				stat(L("Disk read"), Fmt.rate(group.diskRead))
				stat(L("Disk write"), Fmt.rate(group.diskWrite))
				stat(L("Threads"), "\(group.threads)")
			}
		}
	}

	@ViewBuilder
	private var chart: some View {
		let points = model.history.points(for: group.id)
		if points.count > 3 {
			let minutes = max(1, Int((points.last!.time.timeIntervalSince(points.first!.time) / 60).rounded()))
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(L("CPU · peak %@", Fmt.percent(points.map(\.cpu).max() ?? 0))).font(.caption2).foregroundStyle(.secondary)
					Sparkline(values: points.map(\.cpu), color: .orange).frame(height: 28)
				}
				VStack(alignment: .leading, spacing: 2) {
					Text(L("Memory · peak %@", Fmt.bytes(UInt64(points.map(\.memory).max() ?? 0)))).font(.caption2).foregroundStyle(.secondary)
					Sparkline(values: points.map(\.memory), color: .purple).frame(height: 28)
				}
			}
			.accessibilityElement(children: .combine)
			Text(L("Last %d min", minutes)).font(.caption2).foregroundStyle(.tertiary)
		}
	}

	private func stat(_ title: String, _ value: String) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(title).font(.caption2).foregroundStyle(.secondary)
			Text(value).font(.caption.monospacedDigit())
		}
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private var limiterLine: some View {
		if let status = model.limiterStatus[group.id] {
			if status.denied != 0 {
				Label(L("Can't control this process: it belongs to another user."), systemImage: "exclamationmark.triangle")
					.font(.caption).foregroundStyle(.orange)
			} else if status.frozen != 0 {
				Label(L("Frozen — all %d processes suspended.", Int(status.npids)), systemImage: "snowflake")
					.font(.caption).foregroundStyle(.cyan)
			} else if model.paused {
				Label(L("CPU limit paused."), systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
			} else {
				Label(L("Throttling: using %@, allowed to run %d%% of the time.", Fmt.percent(status.usage_cores), Int(status.work_fraction * 100)),
					  systemImage: "gauge.with.dots.needle.33percent")
					.font(.caption).foregroundStyle(.orange)
			}
		} else if let rule = rules.rule(for: group), rule.isActive, !rule.conditions.applies(model.systemState) {
			Label(L("Rule waiting for its conditions: %@", rule.conditions.summary), systemImage: "clock")
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	private var actions: some View {
		HStack {
			if model.isFrozen(group) {
				Button { model.unfreeze(group) } label: { Label(L("Unfreeze"), systemImage: "play.fill") }
			} else {
				Button { model.freeze(group) } label: { Label(L("Freeze"), systemImage: "snowflake") }
					.help(L("Suspend the app and its helpers until you unfreeze it"))
			}
			Button(L("Quit")) { model.quit(group) }
			Button(L("Force Quit")) { confirmForceQuit = true }
			Spacer()
			if let rule = rules.rule(for: group) {
				Button(role: .destructive) { rules.remove(id: rule.id) } label: { Text(L("Remove Rule")) }
			}
		}
		.controlSize(.small)
		.confirmationDialog(L("Force quit %@?", group.name), isPresented: $confirmForceQuit) {
			Button(L("Force Quit"), role: .destructive) { model.forceQuit(group) }
		} message: {
			Text(L("Unsaved changes will be lost."))
		}
	}
}
