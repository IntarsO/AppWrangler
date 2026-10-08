//
//  CLI.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  `appwrangler` command line, built into the app binary:
//      AppWrangler.app/Contents/MacOS/AppWrangler limit Safari 50
//  Rule edits go to rules.json, which the running app watches and applies
//  immediately; freeze/pause go to the running app as distributed notifications.
//

import AppKit
import ProcKit

enum RunningApps {
	/// Apps registered with the window server, keyed by pid.
	static func collect() -> [pid_t: RunningApp] {
		let me = getpid()
		let running = NSWorkspace.shared.runningApplications.filter {
			$0.activationPolicy != .prohibited && $0.processIdentifier != me && !$0.isTerminated
		}
		let bundlePaths = Set(running.compactMap { $0.bundleURL?.path })
		var map: [pid_t: RunningApp] = [:]
		for app in running {
			let path = app.bundleURL?.path
			// An app nested in another app's bundle is that app's helper.
			if let path, bundlePaths.contains(where: { $0 != path && path.hasPrefix($0 + "/") }) { continue }
			// Some apps (e.g. WhatsApp) put invisible bidi marks in their names.
			let name = (app.localizedName
				?? path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
				?? "pid \(app.processIdentifier)")
				.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").union(.whitespaces))
			let kind: AppKind
			if app.activationPolicy == .regular {
				kind = .app
			} else if path?.hasPrefix("/System/") == true || app.bundleIdentifier?.hasPrefix("com.apple.") == true {
				kind = .system
			} else {
				kind = .background
			}
			map[app.processIdentifier] = RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
													name: name, bundlePath: path, kind: kind)
		}
		return map
	}
}

enum CLI {
	static let commands: Set<String> = [
		"help", "list", "rules", "status", "limit", "unlimit", "ecores", "memlimit", "lowmem",
		"enable", "disable", "ignore", "freeze", "unfreeze", "pause", "resume", "export", "import",
	]

	static func isInvocation(_ args: [String]) -> Bool {
		guard args.count > 1 else { return false }
		return commands.contains(args[1]) || ["-h", "--help"].contains(args[1])
	}

	/// Entry point from main.swift.
	static func main(_ args: [String]) -> Int32 {
		let store = RuleStore(defaults: Migration.legacyDefaults)
		let code = run(Array(args.dropFirst()), store: store, apps: Array(RunningApps.collect().values),
					   print: { Swift.print($0) }, postToApp: postToApp)
		store.saveNow()
		return code
	}

	static func postToApp(_ command: String, _ target: String?) -> Bool {
		guard AppState.read() != nil else { return false }
		var info: [String: String] = ["command": command]
		if let target { info["target"] = target }
		DistributedNotificationCenter.default().postNotificationName(IPC.command, object: nil, userInfo: info, deliverImmediately: true)
		return true
	}

	/// Testable core: no globals, output via `print`.
	static func run(_ args: [String], store: RuleStore, apps: [RunningApp],
					print: (String) -> Void, postToApp: (String, String?) -> Bool) -> Int32 {
		guard let command = args.first else { print(usage); return 1 }
		let rest = Array(args.dropFirst())

		func fail(_ message: String) -> Int32 { print("error: " + message); return 1 }

		/// Find (or create) the rule for a user-supplied app name.
		func ruleFor(_ target: String, create: Bool) -> AppRule? {
			let t = target.lowercased()
			if let existing = store.rules.first(where: { $0.displayName.lowercased() == t || $0.matchValue.lowercased() == t }) {
				return existing
			}
			guard create else { return nil }
			if let app = apps.first(where: { $0.name.lowercased() == t || $0.bundleID?.lowercased() == t }) {
				if let bundleID = app.bundleID { return AppRule(matchKind: .bundleID, matchValue: bundleID, displayName: app.name) }
				if let path = app.bundlePath { return AppRule(matchKind: .path, matchValue: path, displayName: app.name) }
			}
			if target.contains("*") || target.contains("?") { return AppRule(matchKind: .pattern, matchValue: target, displayName: target) }
			if target.hasPrefix("/") { return AppRule(matchKind: .path, matchValue: target, displayName: (target as NSString).lastPathComponent) }
			return AppRule(matchKind: .name, matchValue: target, displayName: target)
		}

		func save(_ rule: AppRule, _ message: String) -> Int32 {
			store.upsert(rule)
			store.saveNow()
			print(message + (AppState.read() == nil ? "  (AppWrangler isn't running — applies when it starts)" : ""))
			return 0
		}

		switch command {
		case "help", "-h", "--help":
			print(usage)
			return 0

		case "rules":
			if store.rules.isEmpty { print("No rules."); return 0 }
			for r in store.rules.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
				print("\(r.enabled ? "●" : "○") \(r.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(r.summary)   [\(r.matchKind.rawValue): \(r.matchValue)]")
			}
			return 0

		case "list":
			let all = rest.contains("--all")
			let json = rest.contains("--json")
			let appMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
			let sampler = Sampler()
			let request = SampleRequest(apps: appMap, includeAll: true, includeOtherUsers: false, withThreads: false, matcher: GroupMatcher())
			_ = sampler.sampleNow(request)
			usleep(1_000_000)
			var groups = sampler.sampleNow(request).groups.filter { all || $0.kind != .process }
			groups.sort { $0.cpu > $1.cpu }
			if json {
				let rows: [[String: Any]] = groups.map { g in
					["name": g.name, "kind": "\(g.kind)", "bundleID": g.bundleID ?? "", "path": g.path,
					 "cpuPercent": (g.cpu * 1000).rounded() / 10, "memoryMB": Double(g.footprint) / 1_048_576,
					 "processes": g.processes.count, "rule": store.rule(for: g)?.summary ?? ""]
				}
				let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
				print(String(decoding: data, as: UTF8.self))
				return 0
			}
			print("   CPU     MEMORY  NAME                              WHAT IT IS")
			for g in groups {
				let name = g.name + (g.processes.count > 1 ? " +\(g.processes.count - 1)" : "")
				let what = store.rule(for: g).map { "[" + $0.summary + "]" } ?? ProcessCatalog.describe(g).summary
				let mem = Fmt.bytes(g.footprint)
				print(String(format: "%6.1f%%", g.cpu * 100) + "  " + String(repeating: " ", count: max(0, 9 - mem.count)) + mem
					  + "  " + name.padding(toLength: 32, withPad: " ", startingAt: 0) + "  " + what)
			}
			return 0

		case "status":
			if let state = AppState.read() {
				print("AppWrangler is running (pid \(state.pid))\(state.paused ? ", limits PAUSED" : "").")
				if !state.frozen.isEmpty { print("Frozen: " + state.frozen.joined(separator: ", ")) }
			} else {
				print("AppWrangler isn't running.")
			}
			print("\(store.rules.filter(\.isActive).count) active rules — data in \(store.fileURL.deletingLastPathComponent().path)")
			return 0

		case "limit":
			guard rest.count >= 2, let percent = Double(rest[1].replacingOccurrences(of: "%", with: "")), percent >= 1 else {
				return fail("usage: limit <app> <percent> [--background-only]")
			}
			guard var rule = ruleFor(rest[0], create: true) else { return 1 }
			rule.enabled = true
			rule.cpuLimitEnabled = true
			rule.cpuLimit = min(percent, Double(max(SystemInfo.ncpu, 1) * 100))
			rule.onlyWhenInactive = rest.contains("--background-only")
			return save(rule, "\(rule.displayName): CPU limited to \(Int(rule.cpuLimit))%")

		case "ecores":
			guard rest.count >= 2, ["on", "off"].contains(rest[1]) else { return fail("usage: ecores <app> on|off") }
			guard var rule = ruleFor(rest[0], create: rest[1] == "on") else { return fail("no rule for \(rest[0])") }
			rule.backgroundMode = rest[1] == "on"
			return save(rule, "\(rule.displayName): efficiency cores \(rest[1])")

		case "memlimit":
			guard rest.count >= 2 else { return fail("usage: memlimit <app> <MB>|off [notify|freeze|quit|forcequit]") }
			if rest[1] == "off" {
				guard var rule = ruleFor(rest[0], create: false) else { return fail("no rule for \(rest[0])") }
				rule.memoryLimitEnabled = false
				return save(rule, "\(rule.displayName): memory limit off")
			}
			guard let mb = Double(rest[1]), mb >= 16 else { return fail("memory limit must be a number of MB (≥ 16)") }
			let actions: [String: MemoryAction] = ["notify": .notify, "freeze": .freeze, "quit": .quit, "forcequit": .forceQuit]
			let action = rest.count > 2 ? actions[rest[2].lowercased()] : .notify
			guard let action else { return fail("action must be notify, freeze, quit or forcequit") }
			guard var rule = ruleFor(rest[0], create: true) else { return 1 }
			rule.enabled = true
			rule.memoryLimitEnabled = true
			rule.memoryLimitMB = mb
			rule.memoryAction = action
			return save(rule, "\(rule.displayName): memory limit \(Fmt.megabytes(mb)), then \(action.rawValue)")

		case "lowmem":
			guard rest.count >= 2, let action = PressureAction(rawValue: rest[1]) else { return fail("usage: lowmem <app> none|freeze|quit") }
			guard var rule = ruleFor(rest[0], create: action != .none) else { return fail("no rule for \(rest[0])") }
			rule.pressureAction = action
			return save(rule, "\(rule.displayName): when the Mac is low on memory → \(action.rawValue)")

		case "enable", "disable", "ignore":
			guard rest.count >= 1, var rule = ruleFor(rest[0], create: command == "ignore") else { return fail("no rule for \(rest.first ?? "?")") }
			if command == "ignore" { rule.ignored = true } else { rule.enabled = command == "enable" }
			return save(rule, "\(rule.displayName): \(command)d")

		case "unlimit":
			guard rest.count >= 1, let rule = ruleFor(rest[0], create: false) else { return fail("no rule for \(rest.first ?? "?")") }
			store.remove(id: rule.id)
			store.saveNow()
			print("\(rule.displayName): rule removed")
			return 0

		case "freeze", "unfreeze":
			guard rest.count >= 1 else { return fail("usage: \(command) <app>") }
			guard postToApp(command, rest[0]) else { return fail("AppWrangler isn't running") }
			print("\(command) \(rest[0]): sent")
			return 0

		case "pause", "resume":
			guard postToApp(command, nil) else { return fail("AppWrangler isn't running") }
			print(command == "pause" ? "Limits paused (frozen apps stay frozen)." : "Limits resumed.")
			return 0

		case "export":
			guard let data = try? store.exportData() else { return fail("couldn't encode rules") }
			if let path = rest.first {
				do { try data.write(to: URL(fileURLWithPath: path)) } catch { return fail(error.localizedDescription) }
				print("Exported \(store.rules.count) rules to \(path)")
			} else {
				print(String(decoding: data, as: UTF8.self))
			}
			return 0

		case "import":
			guard let path = rest.first else { return fail("usage: import <file.json>") }
			do {
				let n = try store.importData(Data(contentsOf: URL(fileURLWithPath: path)))
				store.saveNow()
				print("Imported \(n) rules")
				return 0
			} catch {
				return fail("couldn't import: \(error.localizedDescription)")
			}

		default:
			print(usage)
			return 1
		}
	}

	static let usage = """
	AppWrangler — per-app CPU, efficiency-core and memory limits

	usage: appwrangler <command> [arguments]

	  list [--all] [--json]          running apps with CPU, memory and what they are
	  rules                          show saved rules
	  status                         is AppWrangler running, paused, what's frozen
	  limit <app> <percent>          cap CPU (100 = one core). --background-only to
	                                 limit only while the app isn't frontmost
	  ecores <app> on|off            run the app on efficiency cores only
	  memlimit <app> <MB>|off [notify|freeze|quit|forcequit]
	  lowmem <app> none|freeze|quit  what to do when the Mac runs low on memory
	  enable|disable <app>           turn a rule on or off
	  ignore <app>                   never suggest limits for this app
	  unlimit <app>                  delete the rule
	  freeze|unfreeze <app>          suspend / resume an app now (AppWrangler must be running)
	  pause|resume                   pause or resume all CPU limits
	  export [file] / import <file>  share rules as JSON

	<app> is an app name ("Google Chrome"), bundle id (com.google.Chrome),
	process name (node), path (/usr/local/bin/x) or pattern ("*Helper*").
	Changes apply immediately to the running app — no restart needed.
	"""
}
