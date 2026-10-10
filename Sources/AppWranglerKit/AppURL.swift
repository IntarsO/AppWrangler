//
//  AppURL.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  `appwrangler://` links, used by the widget's buttons and usable from
//  Shortcuts, scripts or `open`:
//
//      appwrangler://window              open the window
//      appwrangler://settings            open Settings
//      appwrangler://help/<page>#<anchor> open Help (page: user-manual, cli, mcp, faq…)
//      appwrangler://pause | resume | toggle-pause
//      appwrangler://auto/on | off | toggle
//      appwrangler://free-memory         freeze apps you haven't used for a while
//      appwrangler://make-room/Zoom?minutes=60   make room for an app (minutes=0: until stopped)
//      appwrangler://make-room/off       stop making room
//

import Foundation

enum AppURL: Equatable {
	case window
	case settings
	case help(page: String?, anchor: String?)
	case pause, resume, togglePause
	case auto(Bool?)	// nil = toggle
	case freeMemory
	case makeRoom(app: String, minutes: Double)
	case stopRoom

	init?(_ url: URL) {
		guard url.scheme?.lowercased() == "appwrangler" else { return nil }
		let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
		switch (url.host ?? "window").lowercased() {
		case "window", "": self = .window
		case "settings": self = .settings
		case "help": self = .help(page: path.isEmpty ? nil : path, anchor: url.fragment)
		case "pause": self = .pause
		case "resume": self = .resume
		case "toggle-pause": self = .togglePause
		case "auto":
			switch path {
			case "on": self = .auto(true)
			case "off": self = .auto(false)
			case "", "toggle": self = .auto(nil)
			default: return nil
			}
		case "free-memory": self = .freeMemory
		case "make-room":
			let app = (url.path as NSString).lastPathComponent.removingPercentEncoding ?? ""
			if app.isEmpty { return nil }
			if app.lowercased() == "off" { self = .stopRoom; return }
			let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
				.first { $0.name == "minutes" }?.value.flatMap(RoomFor.parseDuration) ?? 60
			self = .makeRoom(app: app, minutes: minutes)
		default: return nil
		}
	}
}
