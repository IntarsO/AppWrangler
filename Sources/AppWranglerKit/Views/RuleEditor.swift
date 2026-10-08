//
//  RuleEditor.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  The per-app settings form, shared by the popover and the Settings window.
//  Every change is saved and enforced immediately.
//

import SwiftUI

struct RuleEditor: View {
	@Binding var rule: AppRule
	var showsEnableToggle = false
	@Local private var showConditions = false

	private var maxCPU: Double { Double(max(SystemInfo.ncpu, 1) * 100) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if showsEnableToggle {
				Toggle(L("Rule enabled"), isOn: $rule.enabled)
					.toggleStyle(.switch)
				Divider()
			}

			HStack {
				Toggle(isOn: $rule.onlyWhenInactive) {
					Label(L("Only while the app is in the background"), systemImage: "rectangle.on.rectangle")
				}
				Spacer()
				HelpButton(anchor: "only-while-the-app-is-in-the-background")
			}
			Text(rule.onlyWhenInactive
				 ? L("CPU limit and efficiency cores apply only while you're not using the app — it runs at full speed when it's in front.")
				 : L("CPU limit and efficiency cores apply even while you're using the app, which can make it feel slow."))
				.font(.caption).foregroundStyle(rule.onlyWhenInactive ? Color.secondary : Color.orange)
				.fixedSize(horizontal: false, vertical: true)
			Divider()
			cpuSection
			Divider()
			efficiencySection
			Divider()
			memorySection
			Divider()
			conditionsSection
			Divider()

			HStack {
				Toggle(L("Include helper processes"), isOn: $rule.includeHelpers)
				Spacer()
				HelpButton(anchor: "helper-processes")
			}
			Text(L("Applies limits to the app's renderers, XPC services and other helpers too."))
				.font(.caption).foregroundStyle(.secondary)
			HStack {
				Toggle(L("Ignore this app in suggestions and automatic actions"), isOn: $rule.ignored)
				Spacer()
				HelpButton(anchor: "ignoring-an-app")
			}
		}
	}

	private var cpuSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Toggle(isOn: $rule.cpuLimitEnabled) {
					Label(L("Limit CPU"), systemImage: "cpu")
				}
				Spacer()
				HelpButton(anchor: "limit-cpu")
			}
			if rule.cpuLimitEnabled {
				HStack(spacing: 8) {
					Slider(value: $rule.cpuLimit, in: 1...maxCPU, step: 1)
						.accessibilityLabel(L("CPU limit"))
						.accessibilityValue(L("%d percent", Int(rule.cpuLimit)))
					TextField("", value: $rule.cpuLimit, format: .number.precision(.fractionLength(0)))
						.frame(width: 48)
						.multilineTextAlignment(.trailing)
						.textFieldStyle(.roundedBorder)
						.accessibilityLabel(L("CPU limit percent"))
					Text("%").foregroundStyle(.secondary)
				}
				.onChange(of: rule.cpuLimit) { v in
					let clamped = min(max(v.rounded(), 1), maxCPU)
					if clamped != v { rule.cpuLimit = clamped }
				}
				HStack(spacing: 6) {
					ForEach([10.0, 25, 50, 100, 200], id: \.self) { preset in
						if preset <= maxCPU {
							Button("\(Int(preset))%") { rule.cpuLimit = preset }
								.buttonStyle(.bordered)
								.controlSize(.small)
						}
					}
				}
				Text(L("100%% = one full core. This Mac has %d cores (%d%% max).", SystemInfo.ncpu, Int(maxCPU)))
					.font(.caption).foregroundStyle(.secondary)
			}
		}
	}

	private var efficiencySection: some View {
		VStack(alignment: .leading, spacing: 6) {
			if !rule.cpuLimitEnabled && !rule.backgroundMode {
				HStack {
					Label(L("No CPU or efficiency-core setting here, so Auto mode manages this app."), systemImage: "wand.and.stars")
						.font(.caption).foregroundStyle(.teal)
					Spacer()
					HelpButton(anchor: "auto-mode")
				}
			}
			HStack {
				Toggle(isOn: $rule.backgroundMode) {
					Label(L("Efficiency cores only"), systemImage: "leaf")
				}
				Spacer()
				HelpButton(anchor: "efficiency-cores-only")
			}
			Text(L("Runs the app on the E-cores with throttled disk and network I/O. Saves battery and heat without freezing the app."))
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var memorySection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Toggle(isOn: $rule.memoryLimitEnabled) {
					Label(L("Memory limit"), systemImage: "memorychip")
				}
				Spacer()
				HelpButton(anchor: "memory-limit")
			}
			if rule.memoryLimitEnabled {
				HStack(spacing: 8) {
					TextField("", value: $rule.memoryLimitMB, format: .number.precision(.fractionLength(0)))
						.frame(width: 70)
						.multilineTextAlignment(.trailing)
						.textFieldStyle(.roundedBorder)
						.accessibilityLabel(L("Memory limit in megabytes"))
					Text("MB").foregroundStyle(.secondary)
					Menu(L("Presets")) {
						ForEach([512.0, 1024, 2048, 4096, 8192, 16384], id: \.self) { mb in
							if mb * 1_048_576 <= Double(SystemInfo.memsize) {
								Button(Fmt.megabytes(mb)) { rule.memoryLimitMB = mb }
							}
						}
					}
					.fixedSize()
				}
				.onChange(of: rule.memoryLimitMB) { v in
					if v < 16 { rule.memoryLimitMB = 16 }
				}
				Picker(L("When exceeded"), selection: $rule.memoryAction) {
					ForEach(MemoryAction.allCases) { Text($0.label).tag($0) }
				}
				.fixedSize()
				Text(L("macOS can't hard-cap another app's RAM, so AppWrangler watches its memory footprint (as in Activity Monitor) and acts when it stays over the limit."))
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Picker(L("When the Mac is low on memory"), selection: $rule.pressureAction) {
					ForEach(PressureAction.allCases) { Text($0.label).tag($0) }
				}
				.fixedSize()
				Spacer()
				HelpButton(anchor: "when-the-mac-is-low-on-memory")
			}
		}
	}

	private var conditionsSection: some View {
		DisclosureGroup(isExpanded: Binding(get: { showConditions || rule.conditions.isConditional }, set: { showConditions = $0 })) {
			VStack(alignment: .leading, spacing: 8) {
				Picker(L("Power"), selection: $rule.conditions.power) {
					ForEach(PowerCondition.allCases) { Text($0.label).tag($0) }
				}
				.fixedSize()
				Toggle(L("Only in Low Power Mode"), isOn: $rule.conditions.lowPowerModeOnly)
				Toggle(L("Only when the Mac is hot"), isOn: $rule.conditions.hotOnly)
				Toggle(L("Only during these hours"), isOn: $rule.conditions.schedule.enabled)
				if rule.conditions.schedule.enabled {
					HStack {
						DatePicker(L("From"), selection: minutes(\.start), displayedComponents: .hourAndMinute)
						DatePicker(L("to"), selection: minutes(\.end), displayedComponents: .hourAndMinute)
					}
					.fixedSize()
					HStack(spacing: 4) {
						ForEach(weekdayOrder, id: \.self) { day in
							let on = rule.conditions.schedule.weekdays.isEmpty || rule.conditions.schedule.weekdays.contains(day)
							Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) { toggleDay(day) }
								.buttonStyle(.bordered)
								.tint(on ? .accentColor : .secondary)
								.controlSize(.small)
								.accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
								.accessibilityValue(on ? L("on") : L("off"))
						}
					}
				}
			}
			.padding(.top, 6)
		} label: {
			Label(rule.conditions.isConditional ? L("When to apply: %@", rule.conditions.summary) : L("When to apply: always"),
				  systemImage: "bolt.badge.clock")
		}
	}

	private var weekdayOrder: [Int] {
		let first = Calendar.current.firstWeekday
		return (0..<7).map { (first - 1 + $0) % 7 + 1 }
	}

	private func toggleDay(_ day: Int) {
		var days = rule.conditions.schedule.weekdays
		if days.isEmpty { days = Set(1...7) }
		if days.contains(day) { days.remove(day) } else { days.insert(day) }
		rule.conditions.schedule.weekdays = days.count == 7 ? [] : days
	}

	private func minutes(_ keyPath: WritableKeyPath<Schedule, Int>) -> Binding<Date> {
		Binding(
			get: {
				let m = rule.conditions.schedule[keyPath: keyPath]
				return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
			},
			set: { date in
				let c = Calendar.current.dateComponents([.hour, .minute], from: date)
				rule.conditions.schedule[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
			})
	}
}
