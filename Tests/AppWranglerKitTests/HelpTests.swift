//
//  HelpTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct MarkdownTests {
	@Test func headingsGetGitHubAnchors() {
		#expect(Markdown.anchor("When to apply (conditions)") == "when-to-apply-conditions")
		#expect(Markdown.anchor("Freeze, quit and force quit") == "freeze-quit-and-force-quit")
		#expect(Markdown.anchor("Suggestions: what to change") == "suggestions-what-to-change")
		#expect(Markdown.anchor("`list [--all] [--json]`") == "list---all---json")
		#expect(Markdown.html("## Impact\n## Impact").contains("id=\"impact-1\""), "duplicates are numbered like on GitHub")
	}

	@Test func blocks() {
		let html = Markdown.html("""
		# Title

		Some **bold**, *italic* and `a < b` text with a [link](cli.md#set).
		continues here.

		- one
		  - nested `x`
		- two
		continued

		1. first
		2. second

		| A | B |
		|---|:-:|
		| `x\\|y` | **b** |

		> **Tip:** quoted

		```bash
		echo "<hi>" && ls
		```

		---
		""")
		#expect(html.contains("<h1 id=\"title\">Title</h1>"))
		#expect(html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>"))
		#expect(html.contains("<code>a &lt; b</code>"))
		#expect(html.contains("<a href=\"cli.md#set\">link</a>"))
		#expect(html.contains("with a <a href=\"cli.md#set\">link</a>. continues here.</p>"))
		#expect(html.contains("<ul><li>one<ul><li>nested <code>x</code></li></ul></li><li>two continued</li></ul>"))
		#expect(html.contains("<ol><li>first</li><li>second</li></ol>"))
		#expect(html.contains("<th style=\"text-align:center\">B</th>"))
		#expect(html.contains("<td><code>x|y</code></td>"))
		#expect(html.contains("<blockquote>\n<p><strong>Tip:</strong> quoted</p>\n</blockquote>"))
		#expect(html.contains("<pre><code class=\"language-bash\">echo &quot;&lt;hi&gt;&quot; &amp;&amp; ls</code></pre>"))
		#expect(html.contains("<hr>"))
	}

	@Test func markupInsideCodeIsLeftAlone() {
		#expect(Markdown.inline("`**not bold** [x](y)`") == "<code>**not bold** [x](y)</code>")
		#expect(Markdown.inline("memory_limit_mb and low_memory_action") == "memory_limit_mb and low_memory_action")
		#expect(Markdown.inline("<script>") == "&lt;script&gt;")
	}

	@Test func sectionsForSearch() {
		let s = Markdown.sections("# A\nintro\n## B *x*\nbody text\n```\n# not a heading\n```\n")
		#expect(s.map(\.title) == ["A", "B x"])
		#expect(s[1].anchor == "b-x" && s[1].text.contains("body text"))
		#expect(s[1].text.contains("# not a heading"), "code is searchable text, not a heading")
	}
}

@Suite struct HelpContentTests {
	let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
	var docs: URL { root.appendingPathComponent("docs") }

	private func anchors(_ file: String) -> Set<String> {
		let text = (try? String(contentsOf: docs.appendingPathComponent(file), encoding: .utf8)) ?? ""
		return Set(Markdown.sections(text).map(\.anchor))
	}

	@Test func everyTopicIsADoc() {
		for topic in HelpTopic.allCases {
			#expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent(topic.file).path), "\(topic.file)")
		}
		#expect(HelpLibrary.directory != nil)
		#expect(HelpLibrary.markdown(.manual).hasPrefix("# AppWrangler User Manual"))
	}

	@Test func everyLinkBetweenDocsResolves() throws {
		let files = try FileManager.default.contentsOfDirectory(atPath: docs.path).filter { $0.hasSuffix(".md") }
		let link = try NSRegularExpression(pattern: #"\]\(([^)\s]*\.md)?(#[^)\s]+)?\)"#)
		var broken: [String] = []
		for file in files + ["../README.md"] {
			let text = try String(contentsOf: docs.appendingPathComponent(file), encoding: .utf8)
			let ns = text as NSString
			for m in link.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
				let target = m.range(at: 1).location == NSNotFound ? file : ns.substring(with: m.range(at: 1))
				guard !target.hasPrefix("http") else { continue }
				let path = file == "../README.md" ? root.appendingPathComponent(target) : docs.appendingPathComponent(target)
				guard FileManager.default.fileExists(atPath: path.path) else { broken.append("\(file) → \(target)"); continue }
				guard m.range(at: 2).location != NSNotFound, path.deletingLastPathComponent().standardized == docs.standardized else { continue }
				let anchor = String(ns.substring(with: m.range(at: 2)).dropFirst())
				if !anchors(path.lastPathComponent).contains(anchor) { broken.append("\(file) → \(target)#\(anchor)") }
			}
		}
		#expect(broken.isEmpty, "broken links: \(broken)")
	}

	@Test func everyHelpButtonPointsAtARealSection() throws {
		let sources = root.appendingPathComponent("Sources/AppWranglerKit")
		let manual = anchors(HelpTopic.manual.file)
		let pattern = try NSRegularExpression(pattern: #"(?:HelpButton\(anchor: |helpHeader\(L\("[^"]+"\), )"([^"]+)""#)
		var found = 0
		for case let file as String in FileManager.default.enumerator(atPath: sources.path)! where file.hasSuffix(".swift") {
			let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
			let ns = text as NSString
			for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
				found += 1
				let anchor = ns.substring(with: m.range(at: 1))
				#expect(manual.contains(anchor), "\(file): #\(anchor) isn't a section of the manual")
			}
		}
		#expect(found >= 10)
	}

	@Test func searchFindsSectionsAcrossPages() {
		let hits = HelpLibrary.search("memory saver")
		#expect(hits.contains { $0.topic == .manual })
		#expect(HelpLibrary.search("efficiency cores").first?.title.lowercased().contains("efficiency") == true, "heading matches rank first")
		#expect(HelpLibrary.search("configure_app").contains { $0.topic == .assistants })
		#expect(HelpLibrary.search("zzqqxx").isEmpty)
		#expect(HelpLibrary.search("   ").isEmpty)
	}

	@Test func pageIsAFullHTMLDocument() {
		let page = HelpLibrary.page(.faq)
		#expect(page.hasPrefix("<!doctype html>") && page.contains("prefers-color-scheme: dark") && page.contains("<h1 id="))
	}
}
