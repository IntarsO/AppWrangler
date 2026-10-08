//
//  ImpactView.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Settings → Impact: what AppWrangler saved, what it did, and what it cost.
//

import SwiftUI

struct ImpactView: View {
	@ObservedObject var stats: StatsStore
	@AppStorage("AWImpactPeriod") private var period = 7	// 0 = last hour
	@Local private var confirmReset = false

	var body: some View {
		let s = period == 0 ? stats.summary(hours: 1) : stats.summary(days: period)
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				HStack {
					Picker(L("Period"), selection: $period) {
						Text(L("Last hour")).tag(0)
						Text(L("Today")).tag(1)
						Text(L("7 days")).tag(7)
						Text(L("30 days")).tag(30)
					}
					.pickerStyle(.segmented)
					.frame(maxWidth: 300)
					Spacer()
					HelpButton(anchor: "impact")
					Button(L("Reset Statistics…")) { confirmReset = true }
						.confirmationDialog(L("Reset all impact statistics?"), isPresented: $confirmReset) {
							Button(L("Reset"), role: .destructive) { stats.reset() }
						}
				}

				if s.uptimeSeconds < 1 && s.total.savedCPUSeconds == 0 {
					Text(L("No data yet. Statistics are collected while AppWrangler is limiting, freezing or watching apps."))
						.foregroundStyle(.secondary)
				}

				section(L("How it helped")) {
					tiles([
						(L("CPU time saved"), Fmt.coreTime(s.total.savedCPUSeconds), "cpu"),
						(L("Energy saved (est.)"), energyText(s.total.totalSavedEnergyJ), "bolt"),
						(L("…of which by efficiency cores"), Fmt.energy(s.total.efficiencySavedJ), "leaf"),
						(L("Apps held back"), Fmt.duration(s.total.heldBackSeconds), "gauge.with.dots.needle.33percent"),
						(L("Apps frozen"), Fmt.duration(s.total.frozenSeconds), "snowflake"),
						(L("On efficiency cores"), Fmt.duration(s.total.efficiencySeconds), "leaf"),
						(L("Memory freed"), Fmt.bytes(UInt64(s.total.memoryFreedBytes)), "memorychip"),
					])
					Text(L("Actions: %d memory-limit, %d low-memory, %d runaway alerts.", s.total.memoryActions, s.total.lowMemoryActions, s.runawayAlerts))
						.font(.caption).foregroundStyle(.secondary)
				}

				if s.memory.measuredSeconds > 0 {
					section(L("Memory")) {
						let m = s.memory
						tiles([
							(L("Short of memory"), Fmt.duration(m.shortSeconds) + " · " + String(format: "%.0f%%", m.shortSeconds / max(m.measuredSeconds, 1) * 100), "exclamationmark.triangle"),
							(L("Peak swap"), Fmt.bytes(UInt64(m.swapPeakBytes)), "externaldrive"),
							(L("Read back from swap"), Fmt.bytes(UInt64(m.swapInBytes)), "arrow.down.doc"),
							(L("Apps frozen for memory"), L("%d · held %@", m.freezes, Fmt.bytes(UInt64(m.frozenBytes))), "snowflake"),
							(L("Time frozen for memory"), Fmt.duration(m.frozenAppSeconds), "clock"),
						])
						if let perHour = m.swapInPerShortHour {
							Text(L("While short of memory the Mac read back %@ from swap per hour. Lower is better: compare days with idle freezing on and off to see how much it helps on this Mac.", Fmt.bytes(UInt64(perHour))))
								.font(.caption).foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}

				if s.days > 1 && period != 0 {
					section(L("CPU time saved per day")) { DailyBars(daily: s.daily) }
				}

				section(L("What AppWrangler cost")) {
					tiles([
						(L("Average CPU"), Fmt.percent(s.averageSelfCPU), "speedometer"),
						(L("CPU time used"), Fmt.coreTime(s.selfCPUSeconds), "clock"),
						(L("Memory (avg / peak)"), Fmt.bytes(UInt64(s.averageFootprint)) + " / " + Fmt.bytes(UInt64(s.peakFootprint)), "memorychip"),
						(L("Limit accuracy"), s.accuracyError.map { L("±%@", String(format: "%.1f%%", $0 * 100)) } ?? "—", "scope"),
					])
					if let ratio = s.efficiencyRatio {
						Label(L("Saved %@× more CPU time than it used.", ratio >= 10 ? String(format: "%.0f", ratio) : String(format: "%.1f", ratio)),
							  systemImage: "checkmark.seal")
							.foregroundStyle(.green)
					}
					Text(L("Measured over %@ of active monitoring. Accuracy is how closely held-back apps stayed at their limit.", Fmt.duration(s.uptimeSeconds)))
						.font(.caption).foregroundStyle(.secondary)
				}

				if !s.apps.isEmpty {
					section(L("Per app")) {
						Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
							GridRow {
								Text(L("App")); Text(L("CPU saved")); Text(L("Energy")); Text(L("Wanted → allowed")); Text(L("Held back")); Text(L("Frozen"))
							}
							.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
							ForEach(s.apps, id: \.key) { row in
								let a = row.impact
								GridRow {
									Text(a.name).lineLimit(1)
									Text(Fmt.coreTime(a.savedCPUSeconds))
									Text(Fmt.energy(a.totalSavedEnergyJ))
									Text(a.limitedSeconds > 0 ? Fmt.percent(a.averageWanted) + " → " + Fmt.percent(a.averageAllowed) : "—")
									Text(a.heldBackSeconds > 0 ? Fmt.duration(a.heldBackSeconds) : "—")
									Text(a.frozenSeconds > 0 ? Fmt.duration(a.frozenSeconds) : "—")
								}
								.font(.callout.monospacedDigit())
							}
						}
					}
				}

				Text(L("Savings are estimates: CPU saved is what limited apps tried to use minus what they were allowed (frozen apps are credited with what they used before freezing). Energy uses each app's measured watts per core."))
					.font(.caption).foregroundStyle(.tertiary)
					.fixedSize(horizontal: false, vertical: true)
				Text(L("Efficiency cores: the same work on performance cores takes about 4.5× the energy (measured on an M1), so energy used on the E-cores is credited with 3.5× that as saved."))
					.font(.caption).foregroundStyle(.tertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(20)
		}
	}

	private func energyText(_ joules: Double) -> String {
		var text = Fmt.energy(joules)
		if let wh = Battery.capacityWh, joules > 0 {
			text += " · " + L("%@ of battery", String(format: "%.1f%%", joules / 3600 / wh * 100))
		}
		return text
	}

	private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.headline)
			content()
		}
	}

	private func tiles(_ items: [(String, String, String)]) -> some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
			ForEach(items, id: \.0) { item in
				VStack(alignment: .leading, spacing: 4) {
					Label(item.0, systemImage: item.2).font(.caption).foregroundStyle(.secondary)
					Text(item.1).font(.title3.monospacedDigit().weight(.semibold))
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
				.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
				.accessibilityElement(children: .combine)
			}
		}
	}
}

struct DailyBars: View {
	let daily: [(day: String, savedCPUSeconds: Double)]

	var body: some View {
		let peak = max(daily.map(\.savedCPUSeconds).max() ?? 0, 1)
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .bottom, spacing: daily.count > 10 ? 2 : 6) {
				ForEach(daily, id: \.day) { d in
					RoundedRectangle(cornerRadius: 2)
						.fill(Color.accentColor.opacity(d.savedCPUSeconds > 0 ? 0.85 : 0.15))
						.frame(height: max(2, 80 * d.savedCPUSeconds / peak))
						.frame(maxWidth: .infinity)
						.help(d.day + ": " + Fmt.coreTime(d.savedCPUSeconds))
						.accessibilityLabel(d.day + ", " + Fmt.coreTime(d.savedCPUSeconds))
				}
			}
			.frame(height: 80, alignment: .bottom)
			HStack {
				Text(daily.first?.day ?? "")
				Spacer()
				Text(daily.last?.day ?? "")
			}
			.font(.caption2).foregroundStyle(.secondary)
		}
	}
}
