//
//  MCPTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

@Suite struct MCPTests {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppWranglerMCP-\(UUID().uuidString)")
	let apps = [RunningApp(pid: 999_999, bundleID: "com.google.Chrome", name: "Google Chrome",
						   bundlePath: "/Applications/Google Chrome.app", kind: .app)]

	private func server(readOnly: Bool = false, posted: ((String, String?) -> Bool)? = nil) -> MCPServer {
		MCPServer(readOnly: readOnly, directory: dir, runningApps: { apps }, postToApp: posted ?? { _, _ in true }, sampleSeconds: 0.2)
	}

	private func call(_ s: MCPServer, _ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
		let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
		let line = String(decoding: try! JSONSerialization.data(withJSONObject: req), as: UTF8.self)
		let reply = s.handle(line)!
		return try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
	}

	private func tool(_ s: MCPServer, _ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
		call(s, 9, "tools/call", ["name": name, "arguments": args])["result"] as! [String: Any]
	}

	@Test func initializeNegotiatesVersion() {
		let r = call(server(), 1, "initialize", ["protocolVersion": "2025-03-26"])["result"] as! [String: Any]
		#expect(r["protocolVersion"] as? String == "2025-03-26")
		#expect((r["serverInfo"] as? [String: Any])?["name"] as? String == "appwrangler")
		let unknown = call(server(), 1, "initialize", ["protocolVersion": "1999-01-01"])["result"] as! [String: Any]
		#expect(unknown["protocolVersion"] as? String == MCPServer.supportedVersions[0])
	}

	@Test func notificationsGetNoReply() {
		#expect(server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
	}

	@Test func badInputGivesJSONRPCErrors() {
		let s = server()
		let parse = try! JSONSerialization.jsonObject(with: Data(s.handle("not json")!.utf8)) as! [String: Any]
		#expect((parse["error"] as? [String: Any])?["code"] as? Int == -32700)
		#expect((call(s, 2, "nope")["error"] as? [String: Any])?["code"] as? Int == -32601)
		#expect((call(s, 3, "tools/call", ["name": "nope"])["error"] as? [String: Any])?["code"] as? Int == -32602)
	}

	@Test func readOnlyModeHidesChangingTools() {
		let names = { (s: MCPServer) in
			((self.call(s, 1, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
		}
		let ro = names(server(readOnly: true))
		#expect(Set(ro) == ["get_status", "list_apps", "explain_app", "get_impact_stats", "list_rules", "suggest_settings", "get_app_settings", "get_preferences"])
		#expect(names(server()).contains("set_cpu_limit"))
	}

	@Test func toolsAreAnnotated() {
		let tools = (call(server(), 1, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
		func hints(_ n: String) -> [String: Any] { tools.first { $0["name"] as? String == n }!["annotations"] as! [String: Any] }
		#expect(hints("list_rules")["readOnlyHint"] as? Bool == true)
		#expect(hints("remove_rule")["destructiveHint"] as? Bool == true)
		#expect(hints("set_cpu_limit")["readOnlyHint"] as? Bool == false)
		for t in tools { #expect((t["inputSchema"] as? [String: Any])?["type"] as? String == "object") }
	}

	@Test func setLimitAndConditionsThenListRules() {
		let s = server()
		let set = tool(s, "set_cpu_limit", ["app": "google chrome", "percent": 60, "background_only": true])
		#expect(set["isError"] as? Bool == false)
		let cond = tool(s, "set_rule_conditions", ["app": "Google Chrome", "power": "battery",
												   "schedule": ["start": "22:00", "end": "06:00"]])
		#expect(cond["isError"] as? Bool == false)
		let rules = (tool(s, "list_rules")["structuredContent"] as! [String: Any])["rules"] as! [[String: Any]]
		#expect(rules.count == 1)
		#expect(rules[0]["matchValue"] as? String == "com.google.Chrome")
		#expect(rules[0]["cpuLimit"] as? Double == 60)
		#expect(rules[0]["onlyWhenInactive"] as? Bool == true)
		let c = rules[0]["conditions"] as! [String: Any]
		#expect(c["power"] as? String == "battery")
		#expect((c["schedule"] as! [String: Any])["start"] as? Int == 22 * 60)
	}

	@Test func badArgumentsAreToolErrorsNotCrashes() {
		let s = server()
		#expect(tool(s, "set_rule_conditions", ["app": "nothing"])["isError"] as? Bool == true)
		_ = tool(s, "set_cpu_limit", ["app": "x", "percent": 10])
		#expect(tool(s, "set_rule_conditions", ["app": "x", "schedule": ["start": "25:99"]])["isError"] as? Bool == true)
		#expect(tool(s, "set_memory_limit", ["app": "x", "megabytes": 512, "action": "explode"])["isError"] as? Bool == true)
	}

	@Test func freezeAndPauseGoToTheRunningApp() {
		var sent: [(String, String?)] = []
		let s = server(posted: { sent.append(($0, $1)); return true })
		_ = tool(s, "freeze_app", ["app": "Google Chrome", "frozen": true])
		_ = tool(s, "pause_limits", ["paused": false])
		#expect(sent.map(\.0) == ["freeze", "resume"])
		let offline = server(posted: { _, _ in false })
		#expect(tool(offline, "freeze_app", ["app": "x", "frozen": true])["isError"] as? Bool == true)
	}

	@Test func readToolsReturnStructuredData() {
		let s = server()
		let status = tool(s, "get_status")["structuredContent"] as! [String: Any]
		#expect((status["mac"] as? [String: Any])?["logicalCores"] as? Int == SystemInfo.ncpu)
		let stats = tool(s, "get_impact_stats", ["period": "today"])["structuredContent"] as! [String: Any]
		#expect(stats["days"] as? Int == 1)
		#expect(tool(s, "list_apps", ["limit": 2])["structuredContent"] != nil)
	}

	@Test func promptsGuideAnAudit() {
		let s = server()
		let list = (call(s, 1, "prompts/list")["result"] as! [String: Any])["prompts"] as! [[String: Any]]
		#expect(list.map { $0["name"] as! String } == ["audit_mac", "tune_app", "explain_impact"])
		let got = call(s, 2, "prompts/get", ["name": "audit_mac", "arguments": ["focus": "battery"]])["result"] as! [String: Any]
		let text = (((got["messages"] as! [[String: Any]])[0]["content"]) as! [String: Any])["text"] as! String
		#expect(text.contains("Focus on battery"))
		#expect(text.contains("Don't apply any change until I confirm"))
	}

	/// The .mcpb manifest and server.json must describe the server as it really is.
	@Test func bundleManifestMatchesTheServer() throws {
		let root = LocalizationTests.root
		func json(_ path: String) throws -> [String: Any] {
			try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as! [String: Any]
		}
		let manifest = try json("Resources/mcpb-manifest.json")
		let listed = (manifest["tools"] as! [[String: Any]]).map { $0["name"] as! String }
		let served = ((call(server(), 1, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
		#expect(listed.sorted() == served.sorted())
		#expect(manifest["version"] as? String == "__VERSION__")

		let registry = try json("server.json")
		#expect(registry["name"] as? String == "io.github.IntarsO/appwrangler")
		#expect((registry["description"] as? String ?? "").count <= 100)
		let package = (registry["packages"] as! [[String: Any]])[0]
		#expect((package["identifier"] as? String ?? "").contains("/releases/download/v__VERSION__/AppWrangler-mcp-__VERSION__.mcpb"))

		// The version embedded in the binary follows build.sh.
		let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
		let version = try #require(build.firstMatch(of: try Regex(#"VERSION="\$\{VERSION:-([0-9.]+)\}""#))?[1].substring)
		let plist = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Resources/AppWrangler-embedded.plist")))
		#expect(plist["CFBundleShortVersionString"] as? String == String(version))
	}
}
