//
//  SettingsView.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		TabView {
			RulesSettings(model: model, rules: model.rules)
				.tabItem { Label(L("App Rules"), systemImage: "list.bullet.rectangle") }
			ImpactView(stats: model.stats)
				.tabItem { Label(L("Impact"), systemImage: "chart.bar.xaxis") }
			GeneralSettings(model: model)
				.tabItem { Label(L("General"), systemImage: "gearshape") }
			ActivityView(log: model.log)
				.tabItem { Label(L("Activity"), systemImage: "clock.arrow.circlepath") }
			AboutView()
				.tabItem { Label(L("About"), systemImage: "info.circle") }
		}
		.frame(minWidth: 760, minHeight: 540)
	}
}

// MARK: - Rules

struct RulesSettings: View {
	@ObservedObject var model: AppModel
	@ObservedObject var rules: RuleStore
	@Local private var selection: UUID?
	@Local private var message: String?

	var body: some View {
		HSplitView {
			VStack(spacing: 0) {
				List(selection: $selection) {
					ForEach(rules.rules) { rule in
						HStack {
							Toggle("", isOn: binding(for: rule.id).enabled).labelsHidden()
								.accessibilityLabel(L("Enable rule for %@", rule.displayName))
							VStack(alignment: .leading, spacing: 1) {
								Text(rule.displayName).lineLimit(1)
								Text(rule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
							}
						}
						.tag(rule.id)
					}
				}
				Divider()
				HStack(spacing: 0) {
					Menu {
						Section(L("Running apps")) {
							ForEach(runningApps, id: \.processIdentifier) { app in
								Button(app.localizedName ?? "?") { add(app) }
							}
						}
						Divider()
						Button(L("Choose Application…")) { chooseApplication() }
						Button(L("Add by Process Name")) { addByName() }
						Button(L("Add Name Pattern (e.g. *Helper*)")) { addPattern() }
					} label: {
						Image(systemName: "plus")
					}
					.menuStyle(.borderlessButton)
					.fixedSize()
					.padding(.horizontal, 8)
					.accessibilityLabel(L("Add rule"))
					Button {
						if let selection { rules.remove(id: selection) }
						selection = rules.rules.first?.id
					} label: { Image(systemName: "minus") }
						.buttonStyle(.borderless)
						.disabled(selection == nil)
						.padding(.horizontal, 8)
						.accessibilityLabel(L("Remove rule"))
					Spacer()
					Menu {
						Button(L("Import Rules…")) { importRules() }
						Button(L("Export Rules…")) { exportRules() }
					} label: {
						Image(systemName: "square.and.arrow.up.on.square")
					}
					.menuStyle(.borderlessButton)
					.fixedSize()
					.padding(.horizontal, 8)
					.accessibilityLabel(L("Import or export rules"))
				}
				.frame(height: 26)
				if let message {
					Text(message).font(.caption).foregroundStyle(.secondary).padding(4)
				}
			}
			.frame(minWidth: 250, idealWidth: 280, maxWidth: 360)

			Group {
				if let id = selection, rules.rules.contains(where: { $0.id == id }) {
					ScrollView {
						RuleDetail(rule: binding(for: id))
							.padding(20)
					}
				} else {
					VStack(spacing: 8) {
						Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(.tertiary)
						Text(rules.rules.isEmpty ? L("No rules yet") : L("Select a rule")).font(.title3)
						Text(L("Add an app with + to give it CPU, efficiency-core and memory limits.\nRules apply immediately and whenever the app runs."))
							.multilineTextAlignment(.center).foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
		}
		.onAppear { if selection == nil { selection = rules.rules.first?.id } }
	}

	private var runningApps: [NSRunningApplication] {
		NSWorkspace.shared.runningApplications
			.filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() }
			.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
	}

	private func binding(for id: UUID) -> Binding<AppRule> {
		Binding(
			get: { rules.rules.first { $0.id == id } ?? AppRule(matchKind: .name, matchValue: "", displayName: "") },
			set: { rules.upsert($0) })
	}

	private func insert(_ rule: AppRule) {
		if let existing = rules.rules.first(where: { $0.matchKind == rule.matchKind && $0.matchValue == rule.matchValue }) {
			selection = existing.id
			return
		}
		rules.upsert(rule)
		selection = rule.id
	}

	private func add(_ app: NSRunningApplication) {
		if let bundleID = app.bundleIdentifier {
			insert(AppRule(matchKind: .bundleID, matchValue: bundleID, displayName: app.localizedName ?? bundleID))
		} else if let path = app.bundleURL?.path ?? app.executableURL?.path {
			insert(AppRule(matchKind: .path, matchValue: path, displayName: app.localizedName ?? path))
		}
	}

	private func chooseApplication() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.applicationBundle]
		panel.directoryURL = URL(fileURLWithPath: "/Applications")
		panel.allowsMultipleSelection = true
		NSApp.activate(ignoringOtherApps: true)
		guard panel.runModal() == .OK else { return }
		for url in panel.urls {
			let bundle = Bundle(url: url)
			let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
				?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
				?? url.deletingPathExtension().lastPathComponent
			if let bundleID = bundle?.bundleIdentifier {
				insert(AppRule(matchKind: .bundleID, matchValue: bundleID, displayName: name))
			} else {
				insert(AppRule(matchKind: .path, matchValue: url.path, displayName: name))
			}
		}
	}

	private func addByName() {
		insert(AppRule(matchKind: .name, matchValue: "process-name", displayName: L("New process rule")))
	}

	private func addPattern() {
		insert(AppRule(matchKind: .pattern, matchValue: "*Helper*", displayName: L("All helpers")))
	}

	private func exportRules() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.nameFieldStringValue = "AppWrangler Rules.json"
		NSApp.activate(ignoringOtherApps: true)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try rules.exportData().write(to: url, options: .atomic)
			message = L("Exported %d rules", rules.rules.count)
		} catch {
			message = error.localizedDescription
		}
	}

	private func importRules() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		NSApp.activate(ignoringOtherApps: true)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			let n = try rules.importData(Data(contentsOf: url))
			message = L("Imported %d rules", n)
		} catch {
			message = L("Couldn't import: %@", error.localizedDescription)
		}
	}
}

struct RuleDetail: View {
	@Binding var rule: AppRule

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Form {
				TextField(L("Name"), text: $rule.displayName)
				Picker(L("Match by"), selection: $rule.matchKind) {
					ForEach(MatchKind.allCases) { Text($0.label).tag($0) }
				}
				TextField(rule.matchKind.label, text: $rule.matchValue)
				if rule.matchKind == .pattern {
					Text(L("* matches anything, ? one character. Matched against app and process names and bundle IDs, ignoring case."))
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			GroupBox {
				RuleEditor(rule: $rule, showsEnableToggle: true)
					.padding(6)
			}
		}
	}
}

// MARK: - General

struct GeneralSettings: View {
	@ObservedObject var model: AppModel
	@AppStorage(Prefs.uiInterval) private var uiInterval = 1.0
	@AppStorage(Prefs.enforceInterval) private var enforceInterval = 2.0
	@AppStorage(Prefs.limiterPeriodMs) private var limiterPeriod = 50
	@AppStorage(Prefs.showOtherUsers) private var showOtherUsers = false
	@AppStorage(Prefs.notifications) private var notifications = true
	@AppStorage(Prefs.menuBarCPU) private var menuBarCPU = false
	@AppStorage(Prefs.runawayEnabled) private var runawayEnabled = true
	@AppStorage(Prefs.runawayPercent) private var runawayPercent = 80.0
	@AppStorage(Prefs.runawayMinutes) private var runawayMinutes = 3.0
	@AppStorage(Prefs.pressureLevel) private var pressureLevel = 4
	@AppStorage(Prefs.hotKeyEnabled) private var hotKeyEnabled = true
	@AppStorage(Prefs.autoEnabled) private var autoEnabled = true
	@AppStorage(Prefs.autoUseEfficiency) private var autoUseEfficiency = true
	@AppStorage(Prefs.autoEfficiencyAfter) private var autoEfficiencyAfter = 30.0
	@AppStorage(Prefs.autoShareCPU) private var autoShareCPU = true
	@AppStorage(Prefs.autoBusyPercent) private var autoBusyPercent = 75.0
	@AppStorage(Prefs.autoFreezeIdle) private var autoFreezeIdle = false
	@AppStorage(Prefs.autoFreezeIdleMinutes) private var autoFreezeIdleMinutes = 10
	@Local private var launchAtLogin = LoginItem.isEnabled
	@Local private var loginError: String?

	private var cliPath: String { Bundle.main.executablePath ?? "/Applications/AppWrangler.app/Contents/MacOS/AppWrangler" }

	var body: some View {
		Form {
			Section(L("Startup")) {
				Toggle(L("Launch AppWrangler at login"), isOn: $launchAtLogin)
					.onChange(of: launchAtLogin) { on in
						loginError = LoginItem.set(on)
						launchAtLogin = LoginItem.isEnabled
					}
				if let loginError {
					Text(loginError).font(.caption).foregroundStyle(.red)
				}
			}

			Section(header: helpHeader(L("Auto mode"), "auto-mode")) {
				Toggle(L("Manage apps automatically"), isOn: $autoEnabled)
				Text(L("The app you're using (and anything playing or recording audio) always runs at full speed. Apps without their own CPU or efficiency-core rule are managed for you."))
					.font(.caption).foregroundStyle(.secondary)
				if autoEnabled {
					Toggle(L("Move background apps to efficiency cores"), isOn: $autoUseEfficiency)
					if autoUseEfficiency {
						Picker(L("After the app has been in the background for"), selection: $autoEfficiencyAfter) {
							Text("10 s").tag(10.0)
							Text("30 s").tag(30.0)
							Text("1 min").tag(60.0)
							Text("5 min").tag(300.0)
						}
					}
					Toggle(L("Share the CPU fairly when the Mac is busy"), isOn: $autoShareCPU)
					if autoShareCPU {
						Stepper(L("Mac counts as busy above %d%% CPU", Int(autoBusyPercent)), value: $autoBusyPercent, in: 30...95, step: 5)
						Text(L("Then background apps share what the foreground isn't using, each keeping a minimum, so nothing starves. On battery, the threshold is at most 50%."))
							.font(.caption).foregroundStyle(.secondary)
					}
					Toggle(L("When the Mac is low on memory, freeze apps I haven't used for a while"), isOn: $autoFreezeIdle)
					if autoFreezeIdle {
						Picker(L("Unused for at least"), selection: $autoFreezeIdleMinutes) {
							Text("5 min").tag(5)
							Text("10 min").tag(10)
							Text("30 min").tag(30)
							Text("1 h").tag(60)
						}
					}
					Text(L("A frozen app resumes the moment you switch to it, or when memory frees up. Messaging, calls and audio apps are never frozen, nor are menu bar apps. “Low on memory” is the level set under Low memory below."))
						.font(.caption).foregroundStyle(.secondary)
					Text(L("To exclude an app, give it a rule and turn on “Ignore this app”."))
						.font(.caption).foregroundStyle(.secondary)
				}
			}

			Section(header: helpHeader(L("Monitoring"), "settings-window")) {
				Picker(L("Refresh while window is open"), selection: $uiInterval) {
					Text("0.5 s").tag(0.5)
					Text("1 s").tag(1.0)
					Text("2 s").tag(2.0)
					Text("5 s").tag(5.0)
				}
				Picker(L("Check rules in background every"), selection: $enforceInterval) {
					Text("1 s").tag(1.0)
					Text("2 s").tag(2.0)
					Text("5 s").tag(5.0)
					Text("10 s").tag(10.0)
				}
				Text(L("With the window closed AppWrangler measures apps that have rules and, while Auto mode is on, every app (not plain processes), plus a light scan every 5 s for runaway apps. With nothing to do it stops sampling."))
					.font(.caption).foregroundStyle(.secondary)
				Toggle(L("Include other users' processes (view only)"), isOn: $showOtherUsers)
				Toggle(L("Show CPU usage in the menu bar"), isOn: $menuBarCPU)
			}

			Section(header: helpHeader(L("Runaway apps"), "runaway-alerts")) {
				Toggle(L("Tell me when an app keeps using a lot of CPU in the background"), isOn: $runawayEnabled)
				if runawayEnabled {
					Stepper(L("Above %d%% CPU", Int(runawayPercent)), value: $runawayPercent, in: 20...800, step: 10)
					Stepper(L("For %d minutes", Int(runawayMinutes)), value: $runawayMinutes, in: 1...30)
				}
			}

			Section(header: helpHeader(L("Low memory"), "when-the-mac-is-low-on-memory")) {
				Picker(L("Treat the Mac as low on memory at"), selection: $pressureLevel) {
					Text(L("Warning pressure")).tag(2)
					Text(L("Critical pressure")).tag(4)
				}
				Text(L("Apps whose rule says to freeze or quit when the Mac is low on memory are handled at this level, and frozen ones resume when memory frees up."))
					.font(.caption).foregroundStyle(.secondary)
			}

			Section(header: helpHeader(L("CPU limiter"), "limit-cpu")) {
				HStack {
					Slider(value: Binding(get: { Double(limiterPeriod) }, set: { limiterPeriod = Int($0) }), in: 10...200, step: 10)
						.accessibilityLabel(L("Throttle cycle length"))
					Text("\(limiterPeriod) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
				}
				Text(L("Throttle cycle length. Shorter feels smoother in limited apps; longer uses fewer wakeups."))
					.font(.caption).foregroundStyle(.secondary)
				Toggle(L("Pause all CPU limits"), isOn: $model.paused)
				Toggle(L("Pause/resume shortcut: %@", HotKey.display), isOn: $hotKeyEnabled)
			}

			Section(L("Notifications")) {
				Toggle(L("Notify me about memory limits, low memory and runaway apps"), isOn: $notifications)
			}

			Section(header: helpHeader(L("Command line"), nil, topic: .cli)) {
				Text(L("Control AppWrangler from Terminal. Installed with Homebrew? `appwrangler` is already on your PATH. Otherwise add it once:"))
					.font(.caption)
				Text("ln -sf \"\(cliPath)\" /opt/homebrew/bin/appwrangler")
					.font(.caption.monospaced()).textSelection(.enabled)
				Text("appwrangler status · appwrangler suggest · appwrangler set Slack efficiency_cores=on · appwrangler help")
					.font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
			}
		}
		.formStyle(.grouped)
	}

	private func helpHeader(_ title: String, _ anchor: String?, topic: HelpTopic = .manual) -> some View {
		HStack {
			Text(title)
			Spacer()
			HelpButton(topic: topic, anchor: anchor)
		}
	}
}

// MARK: - Activity

struct ActivityView: View {
	@ObservedObject var log: ActivityLog

	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.dateStyle = .none
		f.timeStyle = .medium
		return f
	}()

	var body: some View {
		VStack(spacing: 0) {
			if log.events.isEmpty {
				Text(L("No activity yet")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				Table(log.events) {
					TableColumn(L("Time")) { Text(Self.formatter.string(from: $0.date)).monospacedDigit() }
						.width(80)
					TableColumn(L("App"), value: \.app).width(160)
					TableColumn(L("Event"), value: \.message)
				}
			}
			Divider()
			HStack {
				Spacer()
				Button(L("Clear")) { log.clear() }.disabled(log.events.isEmpty)
			}
			.padding(8)
		}
	}
}

// MARK: - About

struct AboutView: View {
	var body: some View {
		VStack(spacing: 10) {
			Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
				.accessibilityHidden(true)
			Text("AppWrangler").font(.title.bold())
			Text(L("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
				.foregroundStyle(.secondary)
			Text(SystemInfo.summary).font(.callout)
			Text(L("Per-app CPU, efficiency-core and memory limits for Apple Silicon Macs.\nForked from AppPolice by Maksym Stefanchuk."))
				.multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.top, 6)
			HStack(spacing: 16) {
				Button(L("Open Help")) { HelpCenter.open(.gettingStarted) }
					.buttonStyle(.link)
				Link(L("Source code"), destination: Links.repository)
				Link(L("Report a problem"), destination: Links.issues)
				Link(L("Original AppPolice"), destination: Links.upstream)
			}
			.padding(.top, 8)
			Text(L("Free software under the GNU General Public License v2."))
				.font(.caption).foregroundStyle(.tertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
