//
//  WikiTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing

/// scripts/sync-wiki.py builds the GitHub wiki from docs/: every page must build,
/// and every link in the result must lead somewhere.
@Suite struct WikiTests {
	@Test func wikiBuildsWithoutBrokenLinks() throws {
		let root = LocalizationTests.root
		let out = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerWiki-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: out) }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["python3", root.appendingPathComponent("scripts/sync-wiki.py").path, "--out", out.path]
		let pipe = Pipe()
		process.standardError = pipe
		try process.run()
		let errors = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		process.waitUntilExit()
		#expect(process.terminationStatus == 0, "\(errors)")

		let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
		for page in ["Home", "Getting-Started", "User-Manual", "FAQ", "Command-line", "MCP", "How-it-works", "Changelog", "Contributing"] {
			#expect(files.contains("\(page).md"), "missing page \(page)")
		}
		#expect(files.contains("_Sidebar.md") && files.contains("_Footer.md") && files.contains("images"))

		// Links between pages are wiki page names, not file paths.
		let manual = try String(contentsOf: out.appendingPathComponent("User-Manual.md"), encoding: .utf8)
		#expect(!manual.contains("](mcp.md") && !manual.contains("](cli.md"))
		#expect(manual.contains("](MCP") && manual.contains("](Command-line"))
	}
}
