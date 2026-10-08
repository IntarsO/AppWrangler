//
//  AppDelegate.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//

import AppKit
import ProcKit
import SwiftUI

/// Called from main.swift: either run a CLI command or start the menu bar app.
public enum AppWranglerMain {
	public static func run() -> Never {
		let args = CommandLine.arguments
		// Defaults first, so the CLI and MCP report the same settings as the app.
		Prefs.register()
		if args.count > 1 && args[1] == "mcp" {
			if args.count > 2, ["install", "uninstall", "status"].contains(args[2]) {
				exit(MCPInstaller.run(Array(args.dropFirst(2)), print: { Swift.print($0) }))
			}
			// `mcp instal`, `mcp --readonly`…: say so rather than wait silently for JSON-RPC.
			if let bad = args.dropFirst(2).first(where: { $0 != "--read-only" }) {
				FileHandle.standardError.write("unknown mcp option \"\(bad)\" — use: mcp [--read-only] | mcp install|uninstall|status\n".data(using: .utf8)!)
				exit(2)
			}
			MCPServer.serve(readOnly: args.contains("--read-only"))
		}
		if !DataDirectory.isOverridden { Migration.importAppPoliceRules() }
		if CLI.isInvocation(args) {
			exit(CLI.main(args))
		}

		// Before anything can be throttled: never leave apps SIGSTOP'd if we die.
		pk_install_safety_handlers()

		guard InstanceLock.acquire() else {
			FileHandle.standardError.write("AppWrangler is already running for \(DataDirectory.url.path).\n".data(using: .utf8)!)
			exit(0)
		}

		let app = NSApplication.shared
		let delegate = AppDelegate()
		app.delegate = delegate
		app.setActivationPolicy(.accessory)
		app.run()
		exit(0)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
	private let model = AppModel.shared
	private var statusItem: NSStatusItem!
	private let popover = NSPopover()
	private var settingsWindow: NSWindow?
	/// The panel's contents in a standalone, resizable window (like Activity Monitor).
	private var mainWindow: NSWindow?
	private var lastLoad: Double = 0

	func applicationDidFinishLaunching(_ notification: Notification) {
		// `-AWHeadless YES`: enforce rules without a menu bar icon (used by the
		// end-to-end tests so a test copy never shows up next to your real one).
		if !UserDefaults.standard.bool(forKey: "AWHeadless") {
			statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		}
		if let button = statusItem?.button {
			button.image = Self.statusImage()
			button.imagePosition = .imageLeading
			button.target = self
			button.action = #selector(statusItemClicked(_:))
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
			button.toolTip = "AppWrangler"
			button.setAccessibilityLabel("AppWrangler")
		}

		installMainMenu()
		popover.behavior = .transient
		popover.animates = true
		popover.delegate = self
		popover.contentViewController = NSHostingController(
			rootView: PopoverView(model: model, rules: model.rules, openSettings: { [weak self] in self?.showSettings() },
								  openWindow: { [weak self] in self?.showMainWindow() }))

		Notifier.shared.setUp()
		Notifier.shared.onAction = { [weak self] action, info in self?.model.applySuggestion(action, info: info) }

		HotKey.shared.onPress = { [weak self] in
			guard let self else { return }
			self.model.paused.toggle()
			self.updateStatusTitle(nil)
		}

		model.onSystemCPU = { [weak self] load in self?.updateStatusTitle(load) }
		model.start()
		applyPreferences()

		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			self?.applyPreferences()
		}

		// Reopen the window if it was open when AppWrangler last quit, as Activity Monitor does.
		if UserDefaults.standard.bool(forKey: Prefs.mainWindowOpen) && statusItem != nil {
			showMainWindow(activate: false)
		}

		#if DEBUG
		// `AppWrangler --args -AWOpenOnLaunch popover|settings -AWDebugSnapshotDir /tmp/x`
		switch UserDefaults.standard.string(forKey: "AWOpenOnLaunch") {
		case "popover": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover(activate: false) }
		case "settings": showSettings()
		case "window": showMainWindow(activate: false)
		default: break
		}
		if let dir = UserDefaults.standard.string(forKey: "AWDebugSnapshotDir") {
			DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.writeDebugSnapshots(to: dir) }
		}
		#endif
	}

	/// `appwrangler://window` (the widget), `appwrangler://settings`, `appwrangler://help[/topic#section]`.
	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls {
			switch AppURL(url) {
			case .window?, nil: showMainWindow()
			case .settings?: showSettings()
			case .help(let page, let anchor)?: HelpCenter.open(page.flatMap(HelpTopic.init(rawValue:)) ?? .manual, anchor: anchor)
			case .pause?: model.paused = true
			case .resume?: model.paused = false
			case .togglePause?: model.paused.toggle()
			case .auto(let on)?:
				UserDefaults.standard.set(on ?? !UserDefaults.standard.bool(forKey: Prefs.autoEnabled), forKey: Prefs.autoEnabled)
			case .freeMemory?: model.freeMemoryNow()
			}
			updateStatusTitle(nil)
			model.updateWidget()
		}
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		terminating = true
		return .terminateNow
	}

	func applicationWillTerminate(_ notification: Notification) {
		// Resume everything we throttled or froze before exiting.
		model.shutdown()
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if mainWindow != nil { showMainWindow() } else { showSettings() }
		return true
	}

	private func applyPreferences() {
		HotKey.shared.setEnabled(UserDefaults.standard.bool(forKey: Prefs.hotKeyEnabled))
		updateStatusTitle(nil)
	}

	// MARK: Status item

	private static func statusImage() -> NSImage? {
		let image = Bundle.main.image(forResource: "status_icon")
			?? NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AppWrangler")
		image?.isTemplate = true
		image?.size = NSSize(width: 18, height: 18)
		return image
	}

	private func updateStatusTitle(_ load: Double?) {
		if let load { lastLoad = load }
		guard let button = statusItem?.button else { return }
		if UserDefaults.standard.bool(forKey: Prefs.menuBarCPU) {
			let title = String(format: " %.0f%%", lastLoad * 100)
			if button.title != title {
				button.title = title
				button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
			}
		} else if !button.title.isEmpty {
			button.title = ""
		}
		button.appearsDisabled = model.paused
	}

	@objc private func statusItemClicked(_ sender: NSStatusBarButton) {
		if NSApp.currentEvent?.type == .rightMouseUp {
			showContextMenu()
		} else if popover.isShown {
			popover.performClose(nil)
		} else {
			showPopover(activate: true)
		}
	}

	private func showPopover(activate: Bool) {
		guard let button = statusItem?.button else { return }
		if activate { NSApp.activate(ignoringOtherApps: true) }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
		if activate { popover.contentViewController?.view.window?.makeKey() }
		keepPopoverOnScreen()
		DispatchQueue.main.async { self.keepPopoverOnScreen() }
	}

	/// Near the screen edge (e.g. icons beside the notch, or a second display)
	/// the panel could be cut off; slide it back inside the visible area.
	private func keepPopoverOnScreen() {
		guard let window = popover.contentViewController?.view.window,
			  let screen = window.screen ?? statusItem?.button?.window?.screen else { return }
		let visible = screen.visibleFrame.insetBy(dx: 6, dy: 0)
		var frame = window.frame
		if frame.maxX > visible.maxX { frame.origin.x -= frame.maxX - visible.maxX }
		if frame.minX < visible.minX { frame.origin.x = visible.minX }
		if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
	}

	// MARK: Main window

	func showMainWindow(activate: Bool = true) {
		popover.performClose(nil)
		if mainWindow == nil {
			let window = NSWindow(
				contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
				styleMask: [.titled, .closable, .miniaturizable, .resizable],
				backing: .buffered, defer: false)
			window.title = "AppWrangler"
			window.isReleasedWhenClosed = false
			window.contentViewController = NSHostingController(
				rootView: PopoverView(model: model, rules: model.rules, openSettings: { [weak self] in self?.showSettings() }, inWindow: true))
			window.setContentSize(NSSize(width: 560, height: 760))
			window.center()
			window.setFrameAutosaveName("AppWranglerMain")
			window.delegate = self
			mainWindow = window
			model.surfaceDidAppear()
		}
		UserDefaults.standard.set(true, forKey: Prefs.mainWindowOpen)
		// While the window is open AppWrangler behaves like a regular app: Dock icon, ⌘-Tab.
		NSApp.setActivationPolicy(.regular)
		if activate { NSApp.activate(ignoringOtherApps: true) }
		activate ? mainWindow?.makeKeyAndOrderFront(nil) : mainWindow?.orderFront(nil)
	}

	@objc private func openMainWindowMenu() { showMainWindow() }

	private func showContextMenu() {
		let menu = NSMenu()
		let pause = NSMenuItem(title: model.paused ? L("Resume All Limits") : L("Pause All Limits"), action: #selector(togglePause), keyEquivalent: "")
		pause.target = self
		menu.addItem(pause)
		menu.addItem(.separator())
		let window = NSMenuItem(title: L("Open in a Window"), action: #selector(openMainWindowMenu), keyEquivalent: "")
		window.target = self
		menu.addItem(window)
		let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsMenu), keyEquivalent: ",")
		settings.target = self
		menu.addItem(settings)
		let help = NSMenuItem(title: L("Help & Documentation"), action: #selector(openHelp), keyEquivalent: "")
		help.target = self
		menu.addItem(help)
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: L("Quit AppWrangler"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
		statusItem?.menu = menu
		statusItem?.button?.performClick(nil)
		statusItem?.menu = nil	// restore left-click popover behaviour
	}

	@objc private func togglePause() {
		model.paused.toggle()
		updateStatusTitle(nil)
	}

	@objc private func openSettingsMenu() { showSettings() }

	@objc private func openHelp() { HelpCenter.open() }

	/// Menu bar apps show no menu bar, but a main menu still makes the standard
	/// shortcuts work in our windows: ⌘C/⌘V/⌘A in text fields, ⌘W, ⌘? for Help.
	private func installMainMenu() {
		let main = NSMenu()
		func submenu(_ title: String, _ items: [NSMenuItem]) {
			let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
			let menu = NSMenu(title: title)
			items.forEach(menu.addItem)
			holder.submenu = menu
			main.addItem(holder)
		}
		func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
			let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
			i.keyEquivalentModifierMask = mods
			i.target = target
			return i
		}
		submenu("AppWrangler", [
			item(L("Settings…"), #selector(openSettingsMenu), ",", target: self),
			item(L("Quit AppWrangler"), #selector(NSApplication.terminate(_:)), "q"),
		])
		submenu(L("Edit"), [
			item(L("Undo"), Selector(("undo:")), "z"),
			item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
			.separator(),
			item(L("Cut"), #selector(NSText.cut(_:)), "x"),
			item(L("Copy"), #selector(NSText.copy(_:)), "c"),
			item(L("Paste"), #selector(NSText.paste(_:)), "v"),
			item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
		])
		submenu(L("Window"), [
			item(L("Close Window"), #selector(NSWindow.performClose(_:)), "w"),
			item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
		])
		submenu(L("Help"), [item(L("AppWrangler Help"), #selector(openHelp), "?", target: self)])
		NSApp.mainMenu = main
	}

	// MARK: Popover

	func popoverWillShow(_ notification: Notification) { model.surfaceDidAppear() }
	func popoverDidClose(_ notification: Notification) { model.surfaceDidDisappear() }

	// MARK: Settings window

	func showSettings() {
		popover.performClose(nil)
		if settingsWindow == nil {
			let window = NSWindow(
				contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
				styleMask: [.titled, .closable, .miniaturizable, .resizable],
				backing: .buffered, defer: false)
			window.title = L("AppWrangler Settings")
			window.isReleasedWhenClosed = false
			window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
			window.setContentSize(NSSize(width: 820, height: 600))
			window.center()
			window.setFrameAutosaveName("AppWranglerSettings")
			window.delegate = self
			settingsWindow = window
		}
		if settingsWindow?.isVisible == false { model.surfaceDidAppear() }
		#if DEBUG
		if UserDefaults.standard.string(forKey: "AWDebugSnapshotDir") != nil {
			settingsWindow?.orderFront(nil)
			return
		}
		#endif
		NSApp.activate(ignoringOtherApps: true)
		settingsWindow?.makeKeyAndOrderFront(nil)
	}

	func windowWillClose(_ notification: Notification) {
		if (notification.object as? NSWindow) === settingsWindow { model.surfaceDidDisappear() }
		if (notification.object as? NSWindow) === mainWindow {
			model.surfaceDidDisappear()
			mainWindow = nil
			// Closed by you (not by quitting): don't reopen it next time.
			if !terminating { UserDefaults.standard.set(false, forKey: Prefs.mainWindowOpen) }
			NSApp.setActivationPolicy(.accessory)
		}
	}

	private var terminating = false

	#if DEBUG
	/// Debug aid: capture our own windows to PNGs. An app may capture its own
	/// windows without Screen Recording permission.
	private func writeDebugSnapshots(to dir: String) {
		typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
		guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
		let capture = unsafeBitCast(sym, to: CaptureFn.self)
		func write(_ window: NSWindow?, _ name: String) {
			guard let window,
				  let image = capture(.null, 1 << 3 /* including window */, UInt32(window.windowNumber), 1 << 0 /* ignore framing */)?.takeRetainedValue(),
				  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8,
											 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
			else { return }
			// Window materials aren't captured; flatten onto an opaque background.
			let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
			(dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
			rect.fill()
			NSGraphicsContext.current?.cgContext.draw(image, in: rect)
			NSGraphicsContext.restoreGraphicsState()
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
		}
		write(popover.contentViewController?.view.window, "popover.png")
		write(mainWindow, "window.png")
		if UserDefaults.standard.bool(forKey: "AWDebugSnapshotHelp") {
			HelpCenter.open(.manual, anchor: UserDefaults.standard.string(forKey: "AWDebugHelpAnchor"))
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { write(HelpCenter.window, "help.png") }
		}
		guard UserDefaults.standard.bool(forKey: "AWDebugSnapshotSettings") else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
			self.showSettings()
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
				write(self.settingsWindow, "settings.png")
			}
		}
	}
	#endif
}
