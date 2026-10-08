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
		if !DataDirectory.isOverridden { Migration.importAppPoliceRules() }
		if args.count > 1 && args[1] == "mcp" {
			MCPServer.serve(readOnly: args.contains("--read-only"))
		}
		if CLI.isInvocation(args) {
			exit(CLI.main(args))
		}

		// Before anything can be throttled: never leave apps SIGSTOP'd if we die.
		pk_install_safety_handlers()
		Prefs.register()

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

		popover.behavior = .transient
		popover.animates = true
		popover.delegate = self
		popover.contentViewController = NSHostingController(
			rootView: PopoverView(model: model, rules: model.rules, openSettings: { [weak self] in self?.showSettings() }))

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

		#if DEBUG
		// `AppWrangler --args -AWOpenOnLaunch popover|settings -AWDebugSnapshotDir /tmp/x`
		switch UserDefaults.standard.string(forKey: "AWOpenOnLaunch") {
		case "popover": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover(activate: false) }
		case "settings": showSettings()
		default: break
		}
		if let dir = UserDefaults.standard.string(forKey: "AWDebugSnapshotDir") {
			DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.writeDebugSnapshots(to: dir) }
		}
		#endif
	}

	func applicationWillTerminate(_ notification: Notification) {
		// Resume everything we throttled or froze before exiting.
		model.shutdown()
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		showSettings()
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
	}

	private func showContextMenu() {
		let menu = NSMenu()
		let pause = NSMenuItem(title: model.paused ? L("Resume All Limits") : L("Pause All Limits"), action: #selector(togglePause), keyEquivalent: "")
		pause.target = self
		menu.addItem(pause)
		menu.addItem(.separator())
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

	@objc private func openHelp() { NSWorkspace.shared.open(Links.documentation) }

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
	}

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
		guard UserDefaults.standard.bool(forKey: "AWDebugSnapshotSettings") else { return }
		showSettings()
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
			write(self.settingsWindow, "settings.png")
		}
	}
	#endif
}
