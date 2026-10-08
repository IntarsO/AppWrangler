//
//  MCPInstaller.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  `appwrangler mcp install | uninstall | status [--read-only] [client…]`
//  adds AppWrangler's MCP server to Claude Desktop, Claude Code and OpenAI
//  Codex, so nobody has to hand-edit their config files. Each file is backed
//  up (`<file>.appwrangler-backup`) before it's changed, and only the
//  `appwrangler` entry is touched.
//

import AppKit

enum MCPInstaller {
	enum Client: String, CaseIterable {
		case claudeDesktop = "claude-desktop"
		case claudeCode = "claude-code"
		case codex

		var title: String {
			switch self {
			case .claudeDesktop: return "Claude Desktop"
			case .claudeCode: return "Claude Code"
			case .codex: return "OpenAI Codex"
			}
		}

		func configFile(home: URL) -> URL {
			switch self {
			case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
			case .claudeCode: return home.appendingPathComponent(".claude.json")
			case .codex: return home.appendingPathComponent(".codex/config.toml")
			}
		}

		/// Is the client installed (so it's worth configuring)?
		func isPresent(home: URL) -> Bool {
			let fm = FileManager.default
			switch self {
			case .claudeDesktop: return fm.fileExists(atPath: configFile(home: home).deletingLastPathComponent().path)
			case .claudeCode: return fm.fileExists(atPath: configFile(home: home).path)
			case .codex: return fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
			}
		}
	}

	struct Entry: Equatable {
		var command: String
		var args: [String]
		var readOnly: Bool { args.contains("--read-only") }
	}

	static var defaultExecutable: String {
		URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
	}

	/// Claude Desktop rewrites its settings file while it's open, dropping edits made meanwhile.
	static var claudeDesktopIsRunning: Bool {
		!NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
	}

	static func run(_ args: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
					executable: String = defaultExecutable, isRunning: (Client) -> Bool = { $0 == .claudeDesktop && claudeDesktopIsRunning },
					print: (String) -> Void) -> Int32 {
		guard let action = args.first, ["install", "uninstall", "status"].contains(action) else {
			print("usage: appwrangler mcp install|uninstall|status [--read-only] [claude-desktop] [claude-code] [codex]")
			return 1
		}
		let named = args.dropFirst().compactMap(Client.init(rawValue:))
		let unknown = args.dropFirst().filter { Client(rawValue: $0) == nil && $0 != "--read-only" }
		guard unknown.isEmpty else {
			print("error: unknown option or client: \(unknown.joined(separator: " ")) (clients: claude-desktop, claude-code, codex)")
			return 1
		}
		let clients = named.isEmpty ? Client.allCases : named
		let entry = Entry(command: executable, args: ["mcp"] + (args.contains("--read-only") ? ["--read-only"] : []))
		var failed = false

		for client in clients {
			guard client.isPresent(home: home) else {
				print("\(client.title): not installed — skipped")
				continue
			}
			do {
				switch action {
				case "status":
					if let current = try read(client, home: home) {
						var line = "\(client.title): configured (\(current.readOnly ? "read-only" : "full access")) → \(current.command)"
						if !FileManager.default.isExecutableFile(atPath: current.command) { line += "  ⚠️ that file doesn't exist — run `appwrangler mcp install`" }
						print(line)
					} else {
						print("\(client.title): not configured — run `appwrangler mcp install \(client.rawValue)`")
					}
				case "install" where isRunning(client):
					failed = true
					print("\(client.title): quit it first — it rewrites its settings while open and would drop the change. Then run this again.")
				case "uninstall" where isRunning(client):
					failed = true
					print("\(client.title): quit it first, then run this again.")
				case "install":
					if try read(client, home: home) == entry {
						print("\(client.title): already configured")
					} else {
						try write(client, entry, home: home)
						print("\(client.title): added (\(entry.readOnly ? "read-only" : "full access")) — restart \(client.title) to load it")
					}
				default:
					if try read(client, home: home) == nil {
						print("\(client.title): not configured")
					} else {
						try write(client, nil, home: home)
						print("\(client.title): removed")
					}
				}
			} catch {
				failed = true
				print("\(client.title): \(error.localizedDescription)")
			}
		}
		if action == "install" && !executable.hasPrefix("/Applications/") {
			print("Note: the entries point at \(executable). If you move AppWrangler, run `appwrangler mcp install` again.")
		}
		return failed ? 1 : 0
	}

	// MARK: Reading and writing

	struct ConfigError: LocalizedError {
		let errorDescription: String?
	}

	static func read(_ client: Client, home: URL) throws -> Entry? {
		let file = client.configFile(home: home)
		guard FileManager.default.fileExists(atPath: file.path) else { return nil }
		switch client {
		case .claudeDesktop, .claudeCode:
			let json = try loadJSON(file)
			guard let server = (json["mcpServers"] as? [String: Any])?["appwrangler"] as? [String: Any],
				  let command = server["command"] as? String else { return nil }
			return Entry(command: command, args: server["args"] as? [String] ?? [])
		case .codex:
			let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
			guard let range = tomlSection(lines) else { return nil }
			var command: String?
			var args: [String] = []
			for line in lines[range] {
				let t = line.trimmingCharacters(in: .whitespaces)
				if t.hasPrefix("command") { command = tomlStrings(t).first }
				if t.hasPrefix("args") { args = tomlStrings(t) }
			}
			return command.map { Entry(command: $0, args: args) }
		}
	}

	/// Set (or with nil, remove) the `appwrangler` entry.
	static func write(_ client: Client, _ entry: Entry?, home: URL) throws {
		let file = client.configFile(home: home)
		let fm = FileManager.default
		try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		if fm.fileExists(atPath: file.path) {
			let backup = file.appendingPathExtension("appwrangler-backup")
			try? fm.removeItem(at: backup)
			try fm.copyItem(at: file, to: backup)
		}
		switch client {
		case .claudeDesktop, .claudeCode:
			var json = fm.fileExists(atPath: file.path) ? try loadJSON(file) : [:]
			var servers = json["mcpServers"] as? [String: Any] ?? [:]
			if let entry {
				var server: [String: Any] = ["command": entry.command, "args": entry.args]
				if client == .claudeCode { server["type"] = "stdio"; server["env"] = [String: String]() }
				servers["appwrangler"] = server
			} else {
				servers["appwrangler"] = nil
			}
			json["mcpServers"] = servers
			let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
			try data.write(to: file, options: .atomic)
		case .codex:
			var lines = fm.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") : []
			if let range = tomlSection(lines) {
				lines.removeSubrange(range)
				// Drop the blank line left behind.
				if range.lowerBound < lines.count, range.lowerBound > 0, lines[range.lowerBound].isEmpty, lines[range.lowerBound - 1].isEmpty {
					lines.remove(at: range.lowerBound)
				}
			}
			if let entry {
				while lines.last?.isEmpty == true { lines.removeLast() }
				if !lines.isEmpty { lines.append("") }
				lines += ["[mcp_servers.appwrangler]",
						  "command = \(tomlString(entry.command))",
						  "args = [" + entry.args.map(tomlString).joined(separator: ", ") + "]", ""]
			}
			try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
		}
	}

	private static func loadJSON(_ file: URL) throws -> [String: Any] {
		let data = try Data(contentsOf: file)
		if data.isEmpty { return [:] }
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw ConfigError(errorDescription: "\(file.path) isn't a JSON object — left unchanged")
		}
		return json
	}

	/// Lines of the `[mcp_servers.appwrangler]` table, up to the next table.
	static func tomlSection(_ lines: [String]) -> Range<Int>? {
		guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.appwrangler]" }) else { return nil }
		var end = start + 1
		while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
		// Keep the blank lines that separate it from the next table.
		while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
		return start..<end
	}

	static func tomlString(_ s: String) -> String {
		"\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
	}

	/// The quoted strings in a `key = "x"` or `key = ["a", "b"]` line.
	static func tomlStrings(_ line: String) -> [String] {
		var out: [String] = []
		var current = ""
		var inString = false
		var escaped = false
		for c in line.drop(while: { $0 != "=" }) {
			if inString {
				if escaped { current.append(c); escaped = false }
				else if c == "\\" { escaped = true }
				else if c == "\"" { out.append(current); current = ""; inString = false }
				else { current.append(c) }
			} else if c == "\"" {
				inString = true
			}
		}
		return out
	}
}
