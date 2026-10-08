//
//  WidgetTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct WidgetSnapshotTests {
	@Test func roundTripsThroughTheFile() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerWidget-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		var s = WidgetSnapshot.sample
		s.updated = Date(timeIntervalSince1970: 1_800_000_000)	// whole seconds survive ISO 8601
		s.write(directory: dir)
		#expect(WidgetSnapshot.read(directory: dir) == s)
		#expect(WidgetSnapshot.read(directory: dir.appendingPathComponent("missing")) == nil)
	}

	@Test func staleWhenTheAppStoppedWriting() {
		var s = WidgetSnapshot.sample
		s.updated = Date(timeIntervalSince1970: 1_000)
		#expect(!s.isStale(now: s.updated + 60))
		#expect(s.isStale(now: s.updated + WidgetSnapshot.staleAfter + 1))
	}

	@Test func readsTheRealHomeFolderNotASandboxContainer() {
		#expect(WidgetSnapshot.defaultDirectory.path.hasSuffix("/Library/Application Support/AppWrangler"))
		#expect(!WidgetSnapshot.defaultDirectory.path.contains("/Containers/"))
	}

	@Test func memoryFraction() {
		var s = WidgetSnapshot.sample
		s.memoryUsedBytes = 4
		s.memoryTotalBytes = 8
		#expect(s.memoryFraction == 0.5)
		s.memoryTotalBytes = 0
		#expect(s.memoryFraction == 0)
	}

	@Test func theWidgetSourceAndBundleAreInPlace() {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		for path in ["Widget/AppWranglerWidget.swift", "Resources/Widget-Info.plist", "Resources/Widget.entitlements"] {
			#expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
		}
		let plist = NSDictionary(contentsOf: root.appendingPathComponent("Resources/Widget-Info.plist"))
		#expect((plist?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
		#expect((plist?["CFBundleIdentifier"] as? String)?.hasPrefix("io.github.intarso.AppWrangler.") == true)
	}
}

@Suite struct AppURLTests {
	private func parse(_ s: String) -> AppURL? { AppURL(URL(string: s)!) }

	@Test func parsesEveryCommand() {
		#expect(parse("appwrangler://window") == .window)
		#expect(parse("appwrangler://") == .window)
		#expect(parse("appwrangler://settings") == .settings)
		#expect(parse("appwrangler://help/cli#set") == .help(page: "cli", anchor: "set"))
		#expect(parse("appwrangler://help") == .help(page: nil, anchor: nil))
		#expect(parse("appwrangler://pause") == .pause)
		#expect(parse("appwrangler://resume") == .resume)
		#expect(parse("appwrangler://toggle-pause") == .togglePause)
		#expect(parse("appwrangler://auto/on") == .auto(true))
		#expect(parse("appwrangler://auto/off") == .auto(false))
		#expect(parse("appwrangler://auto") == .auto(nil))
		#expect(parse("APPWRANGLER://Free-Memory") == .freeMemory)
	}

	@Test func rejectsUnknownLinks() {
		#expect(parse("appwrangler://format-disk") == nil)
		#expect(parse("appwrangler://auto/maybe") == nil)
		#expect(parse("https://pause") == nil)
	}

	@Test func theWidgetsLinksAreAllUnderstood() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let source = try String(contentsOf: root.appendingPathComponent("Widget/AppWranglerWidget.swift"), encoding: .utf8)
		let links = try NSRegularExpression(pattern: #""(appwrangler://[^"]+)""#)
		let ns = source as NSString
		let found = links.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
		#expect(found.count >= 5)
		for link in found { #expect(AppURL(URL(string: link)!) != nil, "\(link)") }
	}

	@Test func oldWidgetFilesStillDecode() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerWidgetOld-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		var s = WidgetSnapshot.sample
		s.updated = Date(timeIntervalSince1970: 1_800_000_000)
		s.suggestionTitles = nil
		s.write(directory: dir)
		#expect(WidgetSnapshot.read(directory: dir)?.suggestionTitles == nil)
		#expect(WidgetSnapshot.read(directory: dir)?.topSuggestion == s.topSuggestion)
	}
}

@Suite struct FreeMemoryTests {
	@Test func idleFreezesResumeOnFocusButNotWhenMemoryIsFine() {
		let controller = FakeController()
		let e = Enforcer(controller: controller)
		let app = makeGroup(name: "Idle", bundleID: "com.example.idle", pid: 100, helpers: [101], footprintMB: 900)
		let store = tempStore()
		e.freeze(app, reason: .idle)
		// Memory is fine: unlike a low-memory freeze, it stays frozen…
		e.apply(makeSnapshot([app], seq: 1), rules: store, state: SystemState(), frontmostPid: 1)
		#expect(e.isFrozen(app.id))
		// …until you switch to it (or it plays audio).
		e.apply(makeSnapshot([app], seq: 2), rules: store, state: SystemState(), frontmostPid: 1, audioPids: [101])
		#expect(!e.isFrozen(app.id))
		e.freeze(app, reason: .idle)
		e.apply(makeSnapshot([app], seq: 3), rules: store, state: SystemState(), frontmostPid: 100)
		#expect(!e.isFrozen(app.id))
		#expect(controller.frozenGroups.isEmpty)
	}

	@Test func manualFreezesDoNotResumeOnFocus() {
		let e = Enforcer(controller: FakeController())
		let app = makeGroup(pid: 100)
		e.freeze(app, reason: .manual)
		e.apply(makeSnapshot([app], seq: 1), rules: tempStore(), state: SystemState(), frontmostPid: 100)
		#expect(e.isFrozen(app.id))
		#expect(!FreezeReason.manual.resumesOnFocus && !FreezeReason.memoryLimit.resumesOnFocus)
	}
}
