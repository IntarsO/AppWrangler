//
//  Catalog.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Plain-language "what is this?" for every row: known apps and macOS
//  processes, helper naming patterns, and a fallback built from the app's own
//  Info.plist (category + vendor). Also says how safe it is to limit.
//
//  The big tables are English only; the generic fallbacks are localized.
//

import Foundation

enum LimitSafety {
	/// Fine to throttle or freeze.
	case safe
	/// Works, but may cause stutter or side effects elsewhere.
	case caution
	/// AppWrangler refuses to touch it.
	case protected

	var label: String {
		switch self {
		case .safe: return L("Safe to limit")
		case .caution: return L("Limit with care — other apps may depend on it")
		case .protected: return L("Critical to macOS — AppWrangler won't limit it")
		}
	}
}

struct AppDescription: Equatable {
	let summary: String
	let detail: String?
	let safety: LimitSafety
	let vendor: String?
}

enum ProcessCatalog {
	private static var cache: [String: AppDescription] = [:]
	private static let lock = NSLock()

	static func describe(_ group: AppGroup) -> AppDescription {
		lock.lock()
		if let cached = cache[group.id] { lock.unlock(); return cached }
		lock.unlock()
		let d = build(name: group.name, bundleID: group.bundleID, path: group.path, kind: group.kind,
					  protected: Protected.contains(group))
		lock.lock()
		if cache.count > 2000 { cache.removeAll() }
		cache[group.id] = d
		lock.unlock()
		return d
	}

	static func build(name: String, bundleID: String?, path: String, kind: AppKind, protected: Bool) -> AppDescription {
		let vendor = vendorName(bundleID: bundleID, path: path)
		let systemPath = path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
			|| path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/")
		let safety: LimitSafety = protected ? .protected : (systemPath || bundleID?.hasPrefix("com.apple.") == true ? .caution : .safe)

		if let bundleID, let known = knownApps[bundleID] {
			return AppDescription(summary: known, detail: nil, safety: safety, vendor: vendor)
		}
		if let known = knownProcesses[name] {
			return AppDescription(summary: known.0, detail: known.1, safety: protected ? .protected : known.2, vendor: vendor)
		}
		if let pattern = helperPattern(name: name, path: path) {
			return AppDescription(summary: pattern, detail: nil, safety: safety, vendor: vendor)
		}
		if kind != .process {
			let category = bundleCategory(path: path)
			var summary: String
			switch kind {
			case .background: summary = L("Menu bar or background app")
			case .system: summary = L("Part of macOS's user interface")
			default: summary = category ?? L("Application")
			}
			if kind != .app, let category { summary += " · " + category }
			return AppDescription(summary: summary, detail: bundleInfo(path: path), safety: safety, vendor: vendor)
		}
		if systemPath {
			return AppDescription(summary: L("Part of macOS (background service)"), detail: nil, safety: safety, vendor: "Apple")
		}
		if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
			return AppDescription(summary: L("Command-line tool (installed with Homebrew or similar)"), detail: nil, safety: safety, vendor: vendor)
		}
		if path.hasPrefix("/bin/") || path.hasPrefix("/usr/bin/") {
			return AppDescription(summary: L("Unix command-line tool that comes with macOS"), detail: nil, safety: safety, vendor: "Apple")
		}
		if path.contains(".app/") {
			let app = (path.components(separatedBy: ".app/").first.map { ($0 as NSString).lastPathComponent }) ?? ""
			return AppDescription(summary: L("Background part of %@", app), detail: nil, safety: safety, vendor: vendor)
		}
		return AppDescription(summary: L("Background process"), detail: path.isEmpty ? nil : path, safety: safety, vendor: vendor)
	}

	// MARK: Patterns

	private static func helperPattern(name: String, path: String) -> String? {
		let lower = name.lowercased()
		if lower.contains("(renderer)") { return L("Draws web pages and tabs for its app") }
		if lower.contains("(gpu)") { return L("Graphics work (GPU) for its app") }
		if lower.contains("(plugin)") { return L("Runs plug-ins or extensions for its app") }
		if lower.hasPrefix("com.apple.webkit.webcontent") { return L("Web page content (one per tab or web view)") }
		if lower.hasPrefix("com.apple.webkit.networking") { return L("Network loading for web views") }
		if lower.hasPrefix("com.apple.webkit.gpu") { return L("Graphics for web views") }
		if lower.hasSuffix(" helper") || lower.hasSuffix("helper") { return L("Helper process for its app") }
		if path.contains(".xpc/") { return L("XPC service — a background part of an app or macOS") }
		if path.contains(".appex/") { return L("App extension (widget, share or Finder extension)") }
		return nil
	}

	// MARK: Bundle info

	private static let categories: [String: String] = [
		"business": "Business", "developer-tools": "Developer tool", "education": "Education",
		"entertainment": "Entertainment", "finance": "Finance", "games": "Game", "graphics-design": "Graphics & design",
		"healthcare-fitness": "Health & fitness", "lifestyle": "Lifestyle", "medical": "Medical", "music": "Music",
		"news": "News", "photography": "Photography", "productivity": "Productivity", "reference": "Reference",
		"social-networking": "Social networking", "sports": "Sports", "travel": "Travel", "utilities": "Utility",
		"video": "Video", "weather": "Weather",
	]

	private static func bundleCategory(path: String) -> String? {
		guard !path.isEmpty, let info = Bundle(path: path)?.infoDictionary,
			  let type = info["LSApplicationCategoryType"] as? String else { return nil }
		let key = type.replacingOccurrences(of: "public.app-category.", with: "")
		if key.hasSuffix("-games") { return L("Game") }
		return categories[key].map { L($0) }
	}

	private static func bundleInfo(path: String) -> String? {
		guard !path.isEmpty, let info = Bundle(path: path)?.infoDictionary else { return nil }
		return (info["NSHumanReadableCopyright"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func vendorName(bundleID: String?, path: String) -> String? {
		if let bundleID {
			let parts = bundleID.split(separator: ".")
			guard parts.count >= 2 else { return nil }
			let org = String(parts[1])
			if let known = vendors[org.lowercased()] { return known }
			return org.prefix(1).uppercased() + org.dropFirst()
		}
		if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") { return "Apple" }
		return nil
	}

	private static let vendors: [String: String] = [
		"apple": "Apple", "google": "Google", "microsoft": "Microsoft", "mozilla": "Mozilla", "adobe": "Adobe",
		"brave": "Brave", "tinyspeck": "Slack", "spotify": "Spotify", "jetbrains": "JetBrains", "docker": "Docker",
		"anthropic": "Anthropic", "openai": "OpenAI", "figma": "Figma", "hnc": "Discord", "whatsapp": "WhatsApp",
		"telegram": "Telegram", "agilebits": "1Password", "1password": "1Password", "getdropbox": "Dropbox",
		"zoom": "Zoom", "us": "Zoom", "electron": "Electron", "valvesoftware": "Valve", "notion": "Notion",
	]

	// MARK: Known apps (by bundle id)

	private static let knownApps: [String: String] = [
		"com.apple.Safari": "Web browser",
		"com.google.Chrome": "Web browser",
		"com.brave.Browser": "Web browser (privacy-focused)",
		"org.mozilla.firefox": "Web browser",
		"com.microsoft.edgemac": "Web browser",
		"company.thebrowser.Browser": "Web browser (Arc)",
		"com.operasoftware.Opera": "Web browser",
		"com.vivaldi.Vivaldi": "Web browser",
		"com.tinyspeck.slackmacgap": "Team chat",
		"com.microsoft.teams2": "Video meetings and team chat",
		"com.microsoft.teams": "Video meetings and team chat",
		"us.zoom.xos": "Video meetings",
		"com.hnc.Discord": "Voice and text chat",
		"net.whatsapp.WhatsApp": "Messaging",
		"desktop.WhatsApp": "Messaging",
		"ru.keepcoder.Telegram": "Messaging",
		"org.telegram.desktop": "Messaging",
		"com.spotify.client": "Music streaming",
		"com.apple.Music": "Music player and Apple Music",
		"com.apple.TV": "TV and movies",
		"com.apple.Photos": "Photo library",
		"com.apple.mail": "Email",
		"com.apple.MobileSMS": "Messages and iMessage",
		"com.apple.finder": "File manager — shows your files and desktop",
		"com.apple.ActivityMonitor": "Shows what's running and how much it uses",
		"com.apple.Terminal": "Command line",
		"com.googlecode.iterm2": "Command line (terminal)",
		"com.microsoft.VSCode": "Code editor",
		"com.todesktop.230313mzl4w4u92": "AI code editor (Cursor)",
		"com.apple.dt.Xcode": "Apple's developer tools",
		"com.jetbrains.intellij": "Code editor (IDE)",
		"com.docker.docker": "Runs Linux containers in a virtual machine — often memory-hungry",
		"com.anthropic.claudefordesktop": "AI assistant (Claude)",
		"com.openai.chat": "AI assistant (ChatGPT)",
		"notion.id": "Notes and documents",
		"md.obsidian": "Notes",
		"com.figma.Desktop": "Design tool",
		"com.adobe.Photoshop": "Photo editing",
		"com.adobe.illustrator": "Vector illustration",
		"com.adobe.acc.AdobeCreativeCloud": "Adobe app manager and sync — runs many background helpers",
		"com.getdropbox.dropbox": "File sync",
		"com.microsoft.OneDrive": "File sync",
		"com.google.drivefs": "File sync (Google Drive)",
		"com.1password.1password": "Password manager",
		"com.valvesoftware.steam": "Game store and launcher",
		"com.apple.Notes": "Notes",
		"com.apple.iCal": "Calendar",
		"com.apple.reminders": "Reminders",
		"com.apple.Preview": "View PDFs and images",
		"com.apple.systempreferences": "Mac settings and preferences",
		"com.apple.AppStore": "App Store",
		"com.apple.FaceTime": "Video and audio calls",
		"com.microsoft.Word": "Word processor",
		"com.microsoft.Excel": "Spreadsheets",
		"com.microsoft.Powerpoint": "Presentations",
		"com.microsoft.Outlook": "Email and calendar",
	]

	// MARK: Known processes (by executable name): (summary, detail, safety)

	private static let knownProcesses: [String: (String, String?, LimitSafety)] = [
		"kernel_task": ("The macOS kernel", "High CPU here often means macOS is cooling the Mac down by keeping the CPU busy.", .protected),
		"launchd": ("Starts and supervises every other process", nil, .protected),
		"WindowServer": ("Draws everything on screen", "High usage usually comes from apps redrawing a lot or many displays.", .protected),
		"loginwindow": ("Your login session", nil, .protected),
		"mds": ("Spotlight search index server", nil, .protected),
		"mds_stores": ("Spotlight indexing your files", "Busy after big file changes or updates; settles down on its own.", .caution),
		"mdworker": ("Spotlight reading files to index them", nil, .caution),
		"mdworker_shared": ("Spotlight reading files to index them", nil, .caution),
		"mdsync": ("Spotlight sync", nil, .caution),
		"corespotlightd": ("Spotlight search for app content", nil, .caution),
		"backupd": ("Time Machine backup", "Limiting it makes backups slower.", .caution),
		"backupd-helper": ("Time Machine backup helper", nil, .caution),
		"cloudd": ("iCloud sync", nil, .caution),
		"bird": ("iCloud Drive file sync", "Busy while iCloud Drive uploads or downloads files.", .caution),
		"fileproviderd": ("Syncs cloud files (iCloud, Dropbox, OneDrive, Google Drive)", nil, .caution),
		"photoanalysisd": ("Photos analysing your library (faces, scenes)", "Safe to slow down; it catches up later.", .safe),
		"mediaanalysisd": ("Analyses photos and videos for search", "Safe to slow down; it catches up later.", .safe),
		"photolibraryd": ("Photos library database", nil, .caution),
		"softwareupdated": ("Checks for and downloads macOS updates", nil, .caution),
		"trustd": ("Checks certificates and code signatures", nil, .caution),
		"syspolicyd": ("Gatekeeper — checks apps before they open", nil, .caution),
		"XprotectService": ("XProtect malware scanning", nil, .caution),
		"XProtect": ("XProtect malware scanning", nil, .caution),
		"coreaudiod": ("All sound in and out", nil, .protected),
		"hidd": ("Keyboard, mouse and trackpad input", nil, .protected),
		"distnoted": ("Delivers notifications between processes", nil, .protected),
		"cfprefsd": ("Reads and writes app settings", nil, .protected),
		"opendirectoryd": ("User accounts and directory services", nil, .protected),
		"securityd": ("Keychain and security", nil, .protected),
		"logd": ("System logging", nil, .protected),
		"UserEventAgent": ("Handles system events for your session", nil, .protected),
		"fseventsd": ("Tracks file changes for apps", nil, .caution),
		"nsurlsessiond": ("Background downloads for apps", nil, .caution),
		"apsd": ("Apple push notifications", nil, .caution),
		"assistantd": ("Siri", nil, .safe),
		"siriactionsd": ("Siri and Shortcuts actions", nil, .safe),
		"suggestd": ("Siri suggestions", nil, .safe),
		"knowledge-agent": ("Learns usage patterns for suggestions", nil, .safe),
		"rapportd": ("Connects your Apple devices (Handoff, Continuity)", nil, .safe),
		"sharingd": ("AirDrop, Handoff and sharing", nil, .safe),
		"bluetoothd": ("Bluetooth", nil, .caution),
		"airportd": ("Wi-Fi", nil, .caution),
		"WiFiAgent": ("Wi-Fi menu and prompts", nil, .caution),
		"corespeechd": ("“Hey Siri” and dictation", nil, .safe),
		"locationd": ("Location services", nil, .caution),
		"findmydeviced": ("Find My", nil, .caution),
		"Spotlight": ("Spotlight search window", nil, .caution),
		"Dock": ("The Dock, Launchpad and Mission Control", nil, .protected),
		"Finder": ("File manager — shows your files and desktop", nil, .caution),
		"SystemUIServer": ("Menu bar items", nil, .protected),
		"ControlCenter": ("Control Center and menu bar icons", nil, .protected),
		"NotificationCenter": ("Notifications and widgets", nil, .protected),
		"WindowManager": ("Stage Manager and window tiling", nil, .caution),
		"secd": ("Keychain sync", nil, .caution),
		"accountsd": ("Internet accounts", nil, .caution),
		"identityservicesd": ("iMessage and FaceTime identity", nil, .caution),
		"imagent": ("iMessage", nil, .caution),
		"IMDPersistenceAgent": ("Messages history database", nil, .caution),
		"callservicesd": ("Phone and FaceTime calls", nil, .caution),
		"AMPLibraryAgent": ("Music and TV library", nil, .safe),
		"remindd": ("Reminders sync", nil, .safe),
		"CalendarAgent": ("Calendar sync", nil, .safe),
		"routined": ("Learns significant locations", nil, .safe),
		"duetexpertd": ("Predicts which apps you'll use", nil, .safe),
		"biomesyncd": ("Syncs on-device usage data", nil, .safe),
		"spindump": ("Collects diagnostics when an app hangs", nil, .safe),
		"ReportCrash": ("Writes crash reports", nil, .safe),
		"diagnosticd": ("Diagnostics", nil, .safe),
		"powerd": ("Power management and sleep", nil, .protected),
		"thermalmonitord": ("Watches temperature", nil, .protected),
		"node": ("Runs a JavaScript program (Node.js)", "Often started by a developer tool or editor.", .safe),
		"python3": ("Runs a Python program", nil, .safe),
		"Python": ("Runs a Python program", nil, .safe),
		"ruby": ("Runs a Ruby program", nil, .safe),
		"java": ("Runs a Java program", nil, .safe),
		"zsh": ("Terminal shell", nil, .safe),
		"bash": ("Terminal shell", nil, .safe),
		"fish": ("Terminal shell", nil, .safe),
		"ssh": ("Secure shell connection", nil, .safe),
		"git": ("Version control", nil, .safe),
		"com.docker.backend": ("Docker engine", "Runs your containers; limiting it slows them down.", .safe),
		"com.docker.virtualization": ("Docker's Linux virtual machine", nil, .safe),
		"qemu-system-aarch64": ("Virtual machine", nil, .safe),
		"VirtualMachine": ("Apple virtualization (a VM)", nil, .safe),
		"ollama": ("Runs AI models locally", "Uses lots of CPU, GPU and memory while generating.", .safe),
		"claude": ("Claude Code (AI coding agent)", nil, .safe),
	]
}
