//  SPDX-License-Identifier: GPL-2.0-only
//
//  e2e helper: a real menu-bar-style (.accessory, LSUIElement) app that burns one
//  core and runs a helper process from inside its own bundle, like Chrome/Slack.
//  The helper's argument is how many MB it should hold:  open -g X.app --args <MB>
//
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
	var helper: Process?
	func applicationDidFinishLaunching(_ n: Notification) {
		Thread.detachNewThread { var x = 0.0; while true { x += 1 } }
		let mb = CommandLine.arguments.dropFirst().first(where: { Int($0) != nil }) ?? "0"
		let p = Process()
		p.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Helper")
		p.arguments = ["1", mb]
		try? p.run()
		helper = p
	}
	func applicationWillTerminate(_ n: Notification) { helper?.terminate() }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
