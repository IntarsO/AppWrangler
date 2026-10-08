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
