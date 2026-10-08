//
//  AppWranglerWidget.swift
//  AppWrangler desktop / Notification Center widget
//  SPDX-License-Identifier: GPL-2.0-only
//
//  A WidgetKit extension built by build.sh with plain swiftc (no Xcode). It
//  reads the `widget.json` the running app writes once a minute (see
//  WidgetSnapshot.swift, which is compiled into both) and never measures or
//  changes anything itself. Clicking it opens AppWrangler's window.
//

import SwiftUI
import WidgetKit

private func W(_ key: String) -> String { NSLocalizedString(key, comment: "") }
private func W(_ key: String, _ args: CVarArg...) -> String {
	String(format: NSLocalizedString(key, comment: ""), locale: .current, arguments: args)
}

struct Entry: TimelineEntry {
	let date: Date
	let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
	func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .sample) }

	func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
		completion(Entry(date: Date(), snapshot: context.isPreview ? (WidgetSnapshot.read() ?? .sample) : WidgetSnapshot.read()))
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
		// The app also asks WidgetKit to reload when something notable changes.
		let entry = Entry(date: Date(), snapshot: WidgetSnapshot.read())
		completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
	}
}

// MARK: Pieces

private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

private func bytes(_ b: UInt64) -> String {
	ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

private func pressureColor(_ level: Int) -> Color { level >= 4 ? .red : level >= 2 ? .orange : .green }

private func coreTime(_ s: Double) -> String {
	s >= 3600 ? String(format: "%.1f core-h", s / 3600) : s >= 60 ? String(format: "%.0f core-min", s / 60) : String(format: "%.0f core-s", s)
}

/// In macOS's monochrome widget style (an app in front, or "Widget style:
/// Monochrome"), colours are dropped. Parts marked accentable then take the
/// accent tint, so the rings and status still stand out from the text.
struct Accent: ViewModifier {
	func body(content: Content) -> some View {
		if #available(macOS 14.0, *) { content.widgetAccentable() } else { content }
	}
}

struct Ring: View {
	@Environment(\.colorScheme) private var colorScheme
	let value: Double
	let color: Color
	let label: String
	let caption: String
	var detail: String? = nil

	var body: some View {
		VStack(spacing: 3) {
			ZStack {
				Circle().stroke(Color.primary.opacity(0.14), lineWidth: 6)
				Circle().trim(from: 0, to: min(max(value, 0), 1))
					.stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.modifier(Accent())
				Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
			}
			.frame(width: 48, height: 48)
			Text(caption).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
			if let detail {
				Text(detail).font(.system(size: 8.5)).foregroundStyle(.orange).lineLimit(1)
			}
		}
	}
}

struct StatusLine: View {
	let s: WidgetSnapshot

	var body: some View {
		label.modifier(Accent())
	}

	@ViewBuilder private var label: some View {
		if s.paused {
			Label(W("Limits paused"), systemImage: "pause.circle.fill").foregroundStyle(.orange)
		} else if !s.frozen.isEmpty {
			Label(W("%d frozen", s.frozen.count), systemImage: "snowflake").foregroundStyle(.cyan)
		} else if s.autoOn {
			Label(W("Auto · %d on E-cores", s.autoOnEfficiency), systemImage: "wand.and.stars").foregroundStyle(.teal)
		} else {
			Label(W("Auto off"), systemImage: "wand.and.stars").foregroundStyle(.secondary)
		}
	}
}

struct Header: View {
	var body: some View {
		HStack(spacing: 4) {
			Image(systemName: "lasso").font(.system(size: 10, weight: .bold))
			Text("AppWrangler").font(.system(size: 11, weight: .semibold))
			Spacer(minLength: 0)
		}
		.foregroundStyle(.secondary)
	}
}

struct Gauges: View {
	let s: WidgetSnapshot

	var body: some View {
		HStack(spacing: 14) {
			Ring(value: s.cpu, color: .blue, label: percent(s.cpu), caption: W("CPU"))
			Ring(value: s.memoryFraction, color: pressureColor(s.memoryPressure), label: percent(s.memoryFraction),
				 caption: W("Memory"), detail: s.swapUsedBytes > 1_073_741_824 ? W("%@ swap", bytes(s.swapUsedBytes)) : nil)
		}
	}
}

struct NotRunning: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Header()
			Spacer(minLength: 0)
			Image(systemName: "moon.zzz").font(.title2).foregroundStyle(.secondary)
			Text(W("AppWrangler isn't running")).font(.system(size: 12, weight: .semibold))
			Text(W("Click to open it.")).font(.system(size: 10)).foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
	}
}

struct SmallView: View {
	let s: WidgetSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Header()
			Gauges(s: s).frame(maxWidth: .infinity)
			Spacer(minLength: 0)
			StatusLine(s: s).font(.system(size: 10, weight: .medium)).lineLimit(1)
			if s.savedCPUSecondsToday >= 60 {
				Text(W("Saved %@ today", coreTime(s.savedCPUSecondsToday)))
					.font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
			}
		}
	}
}

/// Buttons are links to `appwrangler://…`: interactive widget buttons need
/// Xcode's App Intents metadata step, links don't — the running app acts on them.
struct Controls: View {
	let s: WidgetSnapshot
	var compact = false

	var body: some View {
		HStack(spacing: 5) {
			chip(s.paused ? W("Resume") : W("Pause"), s.paused ? "play.fill" : "pause.fill",
				 s.paused ? "appwrangler://resume" : "appwrangler://pause", active: s.paused)
			chip(W("Auto"), "wand.and.stars", s.autoOn ? "appwrangler://auto/off" : "appwrangler://auto/on", active: s.autoOn)
			chip(compact ? W("Free RAM") : W("Free memory"), "snowflake", "appwrangler://free-memory", active: false)
		}
	}

	@ViewBuilder private func chip(_ title: String, _ symbol: String, _ url: String, active: Bool) -> some View {
		let face = HStack(spacing: 3) {
			Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)).modifier(Accent())
			Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
		}
		.padding(.horizontal, compact ? 5 : 7)
		.padding(.vertical, 4)
		.background(Capsule().fill(active ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.09)))
		.foregroundStyle(.primary)
		#if WIDGET_PREVIEW
		face	// ImageRenderer can't draw links
		#else
		Link(destination: URL(string: url)!) { face }
		#endif
	}
}

struct AppRows: View {
	let apps: [WidgetSnapshot.App]

	var body: some View {
		ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
			HStack(spacing: 4) {
				Image(systemName: icon(app.state)).font(.system(size: 9)).foregroundStyle(color(app.state)).modifier(Accent()).frame(width: 12)
				Text(app.name).font(.system(size: 11)).lineLimit(1)
				Spacer(minLength: 2)
				Text(percent(app.cpu)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
				Text(bytes(app.memoryBytes)).font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
					.frame(width: 50, alignment: .trailing)
			}
		}
	}

	private func icon(_ state: String) -> String {
		switch state {
		case "auto-ecores": return "leaf.fill"
		case "frozen": return "snowflake"
		case "rule": return "gauge.with.dots.needle.33percent"
		default: return "bolt.fill"
		}
	}

	private func color(_ state: String) -> Color {
		switch state {
		case "auto-ecores": return .green
		case "frozen": return .cyan
		case "rule": return .orange
		default: return .blue
		}
	}
}

struct LargeView: View {
	let s: WidgetSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Header()
			HStack(alignment: .center, spacing: 14) {
				Gauges(s: s)
				VStack(alignment: .leading, spacing: 5) {
					StatusLine(s: s).font(.system(size: 11, weight: .medium)).lineLimit(1)
					Text(W("Memory %@ of %@", bytes(s.memoryUsedBytes), bytes(s.memoryTotalBytes)))
						.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
					if s.savedCPUSecondsToday >= 60 {
						Text(W("Saved %@ today", coreTime(s.savedCPUSecondsToday))).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
					}
				}
				Spacer(minLength: 0)
			}
			Divider()
			Text(W("Busiest apps")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
			AppRows(apps: Array(s.topApps.prefix(5)))
			if let titles = s.suggestionTitles ?? s.topSuggestion.map({ [$0] }), !titles.isEmpty {
				Divider()
				ForEach(Array(titles.prefix(3).enumerated()), id: \.offset) { _, title in
					HStack(alignment: .top, spacing: 4) {
						Image(systemName: "lightbulb.fill").font(.system(size: 9)).foregroundStyle(.yellow).modifier(Accent())
						Text(title).font(.system(size: 10)).lineLimit(2)
					}
				}
			}
			Spacer(minLength: 0)
			Controls(s: s)
		}
	}
}

struct MediumView: View {
	let s: WidgetSnapshot

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			SmallView(s: s).frame(width: 128)
			VStack(alignment: .leading, spacing: 5) {
				Text(W("Busiest apps")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
				AppRows(apps: Array(s.topApps.prefix(3)))
				Spacer(minLength: 0)
				if let tip = s.topSuggestion {
					HStack(alignment: .top, spacing: 4) {
						Image(systemName: "lightbulb.fill").font(.system(size: 9)).foregroundStyle(.yellow).modifier(Accent())
						Text(s.suggestionCount > 1 ? tip + " " + W("(+%d more)", s.suggestionCount - 1) : tip)
							.font(.system(size: 9.5)).lineLimit(1)
					}
				}
				Controls(s: s, compact: true)
			}
		}
	}
}

struct WidgetView: View {
	@Environment(\.widgetFamily) private var family
	let entry: Entry

	var body: some View {
		Group {
			if let s = entry.snapshot, !s.isStale(now: entry.date) {
				switch family {
				case .systemMedium: MediumView(s: s)
				case .systemLarge: LargeView(s: s)
				default: SmallView(s: s)
				}
			} else {
				NotRunning()
			}
		}
		.widgetURL(URL(string: "appwrangler://window"))
		.modifier(Background())
	}
}

struct Background: ViewModifier {
	func body(content: Content) -> some View {
		if #available(macOS 14.0, *) {
			content.containerBackground(.fill.tertiary, for: .widget)
		} else {
			content.padding()
		}
	}
}

struct AppWranglerStatusWidget: Widget {
	var body: some WidgetConfiguration {
		StaticConfiguration(kind: "io.github.intarso.AppWrangler.status", provider: Provider()) { entry in
			WidgetView(entry: entry)
		}
		.configurationDisplayName("AppWrangler")
		.description(W("CPU, memory, Auto mode and the busiest apps at a glance, with buttons to pause limits, switch Auto mode and free memory."))
		.supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
	}
}

#if !WIDGET_PREVIEW	// scripts/render-widget.sh renders the views without WidgetKit's host
@main
struct AppWranglerWidgets: WidgetBundle {
	var body: some Widget { AppWranglerStatusWidget() }
}
#endif
