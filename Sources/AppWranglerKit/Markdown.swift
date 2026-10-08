//
//  Markdown.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  A small Markdown → HTML renderer for the in-app Help, covering what the
//  docs use: headings (with GitHub-style anchors, so links like
//  `user-manual.md#auto-mode` work both on GitHub and in the app), paragraphs,
//  nested lists, tables, code blocks, block quotes, rules, links, images,
//  **bold**, *italic* and `code`.
//

import Foundation

enum Markdown {
	/// GitHub's heading anchor: lowercase, drop punctuation, spaces → hyphens.
	static func anchor(_ heading: String) -> String {
		let text = plain(heading).lowercased()
		var out = ""
		for scalar in text.unicodeScalars {
			if scalar == " " { out.append("-") }
			else if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
				out.unicodeScalars.append(scalar)
			}
		}
		return out
	}

	/// Heading/inline text without Markdown markup (for anchors and search).
	static func plain(_ text: String) -> String {
		var s = text
		s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: "`", with: "")
		s = s.replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
		s = s.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])"#, with: "", options: .regularExpression)
		return s.trimmingCharacters(in: .whitespaces)
	}

	struct Section {
		let title: String
		let anchor: String
		let level: Int
		/// Plain text of the section (for search).
		var text: String
	}

	/// Split a document into its headed sections.
	static func sections(_ markdown: String) -> [Section] {
		var out: [Section] = []
		var seen: [String: Int] = [:]
		var inFence = false
		for line in markdown.components(separatedBy: "\n") {
			if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
			if !inFence, let (level, title) = heading(line) {
				out.append(Section(title: plain(title), anchor: unique(anchor(title), &seen), level: level, text: ""))
			} else if !out.isEmpty {
				out[out.count - 1].text += plain(line) + "\n"
			}
		}
		return out
	}

	// MARK: Blocks

	static func html(_ markdown: String) -> String {
		var seen: [String: Int] = [:]
		return blocks(markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), &seen)
	}

	private static func heading(_ line: String) -> (Int, String)? {
		guard line.hasPrefix("#") else { return nil }
		let hashes = line.prefix { $0 == "#" }.count
		guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
		var title = String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
		while title.hasSuffix("#") { title = String(title.dropLast()).trimmingCharacters(in: .whitespaces) }
		return (hashes, title)
	}

	private static func unique(_ a: String, _ seen: inout [String: Int]) -> String {
		if let n = seen[a] {
			seen[a] = n + 1
			return "\(a)-\(n + 1)"
		}
		seen[a] = 0
		return a
	}

	private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)

	private static func listMatch(_ line: String) -> (indent: Int, ordered: Bool, number: Int, text: String)? {
		let ns = line as NSString
		guard let m = listItem.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
		let marker = ns.substring(with: m.range(at: 2))
		let indent = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\t", with: "    ").count
		let ordered = marker.first?.isNumber == true
		return (indent, ordered, ordered ? Int(marker.dropLast()) ?? 1 : 0, ns.substring(with: m.range(at: 3)))
	}

	private static func isRule(_ t: String) -> Bool {
		let compact = t.replacingOccurrences(of: " ", with: "")
		return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
	}

	private static func isTableSeparator(_ t: String) -> Bool {
		let trimmed = t.trimmingCharacters(in: .whitespaces)
		return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
	}

	private static func cells(_ row: String) -> [String] {
		var t = row.trimmingCharacters(in: .whitespaces)
		if t.hasPrefix("|") { t.removeFirst() }
		if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
		var out: [String] = []
		var current = ""
		var previous: Character = " "
		for c in t {
			if c == "|" && previous != "\\" {
				out.append(current.trimmingCharacters(in: .whitespaces))
				current = ""
			} else {
				if c == "|" { current.removeLast() }	// "\|" → "|"
				current.append(c)
			}
			previous = c
		}
		out.append(current.trimmingCharacters(in: .whitespaces))
		return out
	}

	/// Does this line start a new block rather than continue a paragraph or list item?
	private static func startsBlock(_ line: String, next: String) -> Bool {
		let t = line.trimmingCharacters(in: .whitespaces)
		return t.hasPrefix("```") || t.hasPrefix(">") || heading(t) != nil || isRule(t)
			|| (t.hasPrefix("|") && isTableSeparator(next))
	}

	private static func blocks(_ lines: [String], _ seen: inout [String: Int]) -> String {
		var html = ""
		var i = 0
		var paragraph: [String] = []

		func flush() {
			if !paragraph.isEmpty {
				html += "<p>" + inline(paragraph.joined(separator: "\n")).replacingOccurrences(of: "\n", with: " ") + "</p>\n"
				paragraph = []
			}
		}

		while i < lines.count {
			let line = lines[i]
			let t = line.trimmingCharacters(in: .whitespaces)

			if t.isEmpty { flush(); i += 1; continue }

			// Fenced code
			if t.hasPrefix("```") {
				flush()
				let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
				var code: [String] = []
				i += 1
				while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
					code.append(lines[i])
					i += 1
				}
				i += 1
				html += "<pre><code" + (lang.isEmpty ? "" : " class=\"language-\(escape(lang))\"") + ">" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
				continue
			}

			if let (level, title) = heading(t) {
				flush()
				let id = unique(anchor(title), &seen)
				html += "<h\(level) id=\"\(id)\">" + inline(title) + "</h\(level)>\n"
				i += 1
				continue
			}

			if isRule(t) && paragraph.isEmpty {
				html += "<hr>\n"
				i += 1
				continue
			}

			// Table: header row followed by a |---| separator.
			if t.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
				flush()
				let aligns = cells(lines[i + 1]).map { c -> String in
					let l = c.hasPrefix(":"), r = c.hasSuffix(":")
					return l && r ? " style=\"text-align:center\"" : r ? " style=\"text-align:right\"" : ""
				}
				html += "<table>\n<thead><tr>"
				for (n, c) in cells(t).enumerated() { html += "<th\(n < aligns.count ? aligns[n] : "")>" + inline(c) + "</th>" }
				html += "</tr></thead>\n<tbody>\n"
				i += 2
				while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
					html += "<tr>"
					for (n, c) in cells(lines[i]).enumerated() { html += "<td\(n < aligns.count ? aligns[n] : "")>" + inline(c) + "</td>" }
					html += "</tr>\n"
					i += 1
				}
				html += "</tbody>\n</table>\n"
				continue
			}

			// Block quote
			if t.hasPrefix(">") {
				flush()
				var quoted: [String] = []
				while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
					var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
					if q.first == " " { q = q.dropFirst() }
					quoted.append(String(q))
					i += 1
				}
				html += "<blockquote>\n" + blocks(quoted, &seen) + "</blockquote>\n"
				continue
			}

			// List (with nesting by indentation and continuation lines)
			if listMatch(line) != nil {
				flush()
				var stack: [(indent: Int, tag: String)] = []
				var openItem = false
				while i < lines.count {
					let l = lines[i]
					if let item = listMatch(l) {
						while let top = stack.last, top.indent > item.indent {
							html += "</li></\(top.tag)>"
							stack.removeLast()
						}
						// Switching between bullets and numbers at the same level starts a new list.
						if let top = stack.last, top.indent == item.indent, top.tag != (item.ordered ? "ol" : "ul") {
							html += "</li></\(top.tag)>"
							stack.removeLast()
							openItem = false
						}
						if stack.isEmpty || item.indent > stack.last!.indent {
							let tag = item.ordered ? "ol" : "ul"
							html += "<\(tag)" + (item.ordered && item.number != 1 ? " start=\"\(item.number)\"" : "") + ">"
							stack.append((item.indent, tag))
						} else if openItem {
							html += "</li>"
						}
						html += "<li>" + inline(item.text)
						openItem = true
						i += 1
					} else if !l.trimmingCharacters(in: .whitespaces).isEmpty, !stack.isEmpty,
							  l.hasPrefix(" ") || l.hasPrefix("\t") || !startsBlock(l, next: i + 1 < lines.count ? lines[i + 1] : "") {
						// Continuation of the current item (indented, or a "lazy" unindented line).
						html += " " + inline(l.trimmingCharacters(in: .whitespaces))
						i += 1
					} else if l.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count,
							  listMatch(lines[i + 1]).map({ $0.indent > 0 || stack.count == 1 }) == true {
						i += 1		// blank line inside a loose list
					} else {
						break
					}
				}
				while let top = stack.popLast() { html += "</li></\(top.tag)>" }
				html += "\n"
				continue
			}

			paragraph.append(t)
			i += 1
		}
		flush()
		return html
	}

	// MARK: Inline

	static func escape(_ s: String) -> String {
		s.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}

	static func inline(_ text: String) -> String {
		// 1. Code spans first, so nothing inside them is touched.
		var codes: [String] = []
		var s = ""
		var rest = Substring(text)
		while let open = rest.firstIndex(of: "`") {
			let ticks = rest[open...].prefix { $0 == "`" }.count
			let fence = String(repeating: "`", count: ticks)
			let afterOpen = rest.index(open, offsetBy: ticks)
			guard let close = rest[afterOpen...].range(of: fence) else { break }
			s += rest[..<open]
			codes.append("<code>" + escape(rest[afterOpen..<close.lowerBound].trimmingCharacters(in: .whitespaces)) + "</code>")
			s += "\u{1}\(codes.count - 1)\u{2}"
			rest = rest[close.upperBound...]
		}
		s += rest

		// 2. Escape, then the rest of the markup.
		s = escape(s)
		func sub(_ pattern: String, _ template: String) {
			s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
		}
		sub(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">")
		sub(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, "<a href=\"$2\">$1</a>")
		sub(#"&lt;(https?://[^\s&]+)&gt;"#, "<a href=\"$1\">$1</a>")
		sub(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "<strong>$1</strong>")
		sub(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "<em>$1</em>")
		sub(#"(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])"#, "<em>$1</em>")
		sub(#"\\([\\`*_{}\[\]()#+\-.!|>])"#, "$1")

		// 3. Put the code spans back.
		for (n, code) in codes.enumerated() {
			s = s.replacingOccurrences(of: "\u{1}\(n)\u{2}", with: code)
		}
		return s
	}
}
