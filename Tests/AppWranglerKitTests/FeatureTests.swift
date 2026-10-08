//
//  FeatureTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Runaway detection, the CLI, the process catalog and localization coverage.
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct RunawayTests {
	private func feed(_ d: RunawayDetector, cpu: Double, seconds: Int, every: Int = 5, frontmost: pid_t = 0,
					  start: Date = Date(timeIntervalSince1970: 1_000_000)) -> [RunawaySuggestion] {
		var raised: [RunawaySuggestion] = []
		for t in stride(from: 0, through: seconds, by: every) {
			let snap = makeSnapshot([makeGroup(cpu: cpu)], seq: UInt64(t + 1))
			raised += d.observe(snap, frontmostPid: frontmost, now: start.addingTimeInterval(TimeInterval(t))) { _ in false }
		}
		return raised
	}

	@Test func sustainedBackgroundBurnRaisesOneSuggestion() {
		let d = RunawayDetector()
		d.threshold = 0.8
		d.duration = 180
		let raised = feed(d, cpu: 1.5, seconds: 400)
		#expect(raised.count == 1)
		#expect(raised.first?.name == "Test App")
		#expect(raised.first.map { $0.averageCPU >= 1.4 } == true)
	}

	@Test func shortBurstIsIgnored() {
		let d = RunawayDetector()
		d.duration = 180
		#expect(feed(d, cpu: 2.0, seconds: 120).isEmpty)
	}

	@Test func frontmostAppIsIgnored() {
		let d = RunawayDetector()
		#expect(feed(d, cpu: 2.0, seconds: 400, frontmost: 50_000).isEmpty)
	}

	@Test func belowThresholdIsIgnored() {
		let d = RunawayDetector()
		d.threshold = 0.8
		#expect(feed(d, cpu: 0.5, seconds: 400).isEmpty)
	}

	@Test func exemptAppsAreIgnored() {
		let d = RunawayDetector()
		let snap = makeSnapshot([makeGroup(cpu: 3)], seq: 1)
		for t in stride(from: 0, through: 400, by: 5) {
			#expect(d.observe(snap, frontmostPid: 0, now: Date(timeIntervalSince1970: TimeInterval(t))) { _ in true }.isEmpty)
		}
	}
}

@Suite struct CLITests {
	let store = tempStore()
	let apps = [RunningApp(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome",
						   bundlePath: "/Applications/Google Chrome.app", kind: .app)]

	private func run(_ args: String..., appRunning: Bool = true) -> (Int32, [String], [(String, String?)]) {
		var out: [String] = []
		var posted: [(String, String?)] = []
		let code = CLI.run(args, store: store, apps: apps, print: { out.append($0) },
						   postToApp: { cmd, target in posted.append((cmd, target)); return appRunning })
		return (code, out, posted)
	}

	@Test func limitResolvesRunningAppToBundleID() {
		let (code, _, _) = run("limit", "google chrome", "40")
		#expect(code == 0)
		#expect(store.rules.count == 1)
		#expect(store.rules[0].matchKind == .bundleID)
		#expect(store.rules[0].matchValue == "com.google.Chrome")
		#expect(store.rules[0].cpuLimitEnabled && store.rules[0].cpuLimit == 40)
	}

	@Test func limitUpdatesExistingRuleInPlace() {
		_ = run("limit", "Google Chrome", "40")
		_ = run("limit", "Google Chrome", "70%", "--background-only")
		#expect(store.rules.count == 1)
		#expect(store.rules[0].cpuLimit == 70)
		#expect(store.rules[0].onlyWhenInactive)
	}

	@Test func unknownTargetsBecomeNameOrPatternRules() {
		_ = run("limit", "node", "50")
		_ = run("ecores", "*Helper*", "on")
		#expect(store.rules.contains { $0.matchKind == .name && $0.matchValue == "node" })
		#expect(store.rules.contains { $0.matchKind == .pattern && $0.backgroundMode })
	}

	@Test func memlimitParsesAction() {
		let (code, _, _) = run("memlimit", "Google Chrome", "4096", "freeze")
		#expect(code == 0)
		#expect(store.rules[0].memoryLimitEnabled && store.rules[0].memoryLimitMB == 4096 && store.rules[0].memoryAction == .freeze)
		#expect(run("memlimit", "Google Chrome", "4096", "explode").0 == 1)
		#expect(run("memlimit", "Google Chrome", "off").0 == 0)
		#expect(!store.rules[0].memoryLimitEnabled)
	}

	@Test func unlimitRemovesRule() {
		_ = run("limit", "Google Chrome", "40")
		#expect(run("unlimit", "Google Chrome").0 == 0)
		#expect(store.rules.isEmpty)
		#expect(run("unlimit", "Google Chrome").0 == 1)
	}

	@Test func freezeAndPauseGoToTheRunningApp() {
		let (code, _, posted) = run("freeze", "Google Chrome")
		#expect(code == 0)
		#expect(posted.first?.0 == "freeze" && posted.first?.1 == "Google Chrome")
		#expect(run("pause", appRunning: false).0 == 1, "fails clearly when the app isn't running")
	}

	@Test func badUsageFails() {
		#expect(run("limit", "Google Chrome").0 == 1)
		#expect(run("limit", "Google Chrome", "zero").0 == 1)
		#expect(run("bogus").0 == 1)
		#expect(CLI.isInvocation(["AppWrangler", "limit"]))
		#expect(!CLI.isInvocation(["AppWrangler"]))
		#expect(!CLI.isInvocation(["AppWrangler", "-NSDocumentRevisionsDebugMode", "YES"]))
	}

	@Test func exportImportRoundTrip() throws {
		_ = run("limit", "Google Chrome", "40")
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString).json")
		#expect(run("export", file.path).0 == 0)
		let other = tempStore()
		#expect(try other.importData(Data(contentsOf: file)) == 1)
		#expect(other.rules.first?.cpuLimit == 40)
	}
}

@Suite struct CatalogTests {
	private func describe(_ name: String, bundleID: String? = nil, path: String = "", kind: AppKind = .process) -> AppDescription {
		ProcessCatalog.build(name: name, bundleID: bundleID, path: path, kind: kind,
							 protected: Protected.contains(name: name, bundleID: bundleID, pid: 1000))
	}

	@Test func knownSystemProcesses() {
		#expect(describe("kernel_task").safety == .protected)
		#expect(describe("mds_stores").summary.contains("Spotlight"))
		#expect(describe("photoanalysisd").safety == .safe)
	}

	@Test func helperPatterns() {
		#expect(describe("Google Chrome Helper (Renderer)").summary.contains("web pages"))
		#expect(describe("Slack Helper (GPU)").summary.contains("GPU"))
	}

	@Test func knownAppsAndVendors() {
		let d = describe("Google Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app", kind: .app)
		#expect(d.summary == "Web browser")
		#expect(d.vendor == "Google")
		#expect(describe("Safari", bundleID: "com.apple.Safari", kind: .app).safety == .caution)
	}

	@Test func pathFallbacks() {
		#expect(describe("rg", path: "/opt/homebrew/bin/rg").summary.contains("Homebrew"))
		#expect(describe("someservice", path: "/usr/libexec/someservice").vendor == "Apple")
		#expect(describe("thing", path: "/Applications/Foo.app/Contents/Library/thing").summary.contains("Foo"))
	}

	@Test func everyKindHasATitle() {
		for kind in AppKind.allCases { #expect(!kind.title.isEmpty) }
	}
}

/// Every L("…") key used in the app must be translated, with matching placeholders.
@Suite struct LocalizationTests {
	static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

	static func keysInSources() throws -> Set<String> {
		let sources = root.appendingPathComponent("Sources/AppWranglerKit")
		let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
		var keys = Set<String>()
		for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
			let text = try String(contentsOf: url, encoding: .utf8)
			for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
				let raw = String(text[Range(m.range(at: 1), in: text)!])
				keys.insert(raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\""))
			}
		}
		return keys
	}

	static func strings(_ lang: String) throws -> [String: String] {
		let url = root.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
		let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
		return plist as? [String: String] ?? [:]
	}

	static func placeholders(_ s: String) -> [String] {
		let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@dlfs]+|%%"#)
		return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
	}

	@Test func russianCoversEveryKey() throws {
		let keys = try Self.keysInSources()
		let ru = try Self.strings("ru")
		#expect(keys.count > 150)
		let missing = keys.subtracting(ru.keys).sorted()
		#expect(missing.isEmpty, "Missing Russian translations:\n\(missing.joined(separator: "\n"))")
	}

	@Test func placeholdersMatch() throws {
		for (key, value) in try Self.strings("ru") {
			#expect(Self.placeholders(key) == Self.placeholders(value), "Placeholder mismatch for \"\(key)\"")
		}
	}
}
