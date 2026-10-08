//
//  Services.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Notifications (with "Limit / E-cores / Ignore" actions), launch at login,
//  and the global pause/resume shortcut.
//

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	static let shared = Notifier()

	enum Action: String {
		case limit50 = "LIMIT50"
		case ecores = "ECORES"
		case ignore = "IGNORE"
	}

	/// (action, suggestion userInfo)
	var onAction: ((Action, [String: String]) -> Void)?

	private let runawayCategory = "RUNAWAY"
	private var authorized: Bool?

	private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

	func setUp() {
		guard available else { return }
		let center = UNUserNotificationCenter.current()
		center.delegate = self
		let actions = [
			UNNotificationAction(identifier: Action.limit50.rawValue, title: L("Limit to 50%"), options: []),
			UNNotificationAction(identifier: Action.ecores.rawValue, title: L("Use efficiency cores"), options: []),
			UNNotificationAction(identifier: Action.ignore.rawValue, title: L("Ignore this app"), options: [.destructive]),
		]
		center.setNotificationCategories([
			UNNotificationCategory(identifier: runawayCategory, actions: actions, intentIdentifiers: [], options: []),
		])
	}

	func post(title: String, body: String, suggestion: [String: String]? = nil) {
		guard available, UserDefaults.standard.bool(forKey: Prefs.notifications) else { return }
		let center = UNUserNotificationCenter.current()
		let send = {
			let content = UNMutableNotificationContent()
			content.title = title
			content.body = body
			if let suggestion {
				content.categoryIdentifier = self.runawayCategory
				content.userInfo = suggestion
			}
			center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
		}
		if authorized == true { send(); return }
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			DispatchQueue.main.async {
				self.authorized = granted
				if granted { send() }
			}
		}
	}

	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
								withCompletionHandler completionHandler: @escaping () -> Void) {
		let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
		if let action = Action(rawValue: response.actionIdentifier) {
			DispatchQueue.main.async { self.onAction?(action, info) }
		}
		completionHandler()
	}

	// Show banners even though we're an agent app.
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
								withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		completionHandler([.banner, .sound])
	}
}

enum LoginItem {
	static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

	@discardableResult
	static func set(_ on: Bool) -> String? {
		do {
			if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
			return nil
		} catch {
			return error.localizedDescription
		}
	}
}

/// ⌃⌥⌘P toggles "pause all limits" from anywhere. Carbon hot keys need no
/// Accessibility permission.
final class HotKey {
	static let shared = HotKey()
	static let display = "⌃⌥⌘P"

	var onPress: (() -> Void)?
	private var ref: EventHotKeyRef?
	private var handler: EventHandlerRef?

	func setEnabled(_ enabled: Bool) {
		enabled ? register() : unregister()
	}

	private func register() {
		guard ref == nil else { return }
		if handler == nil {
			var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
			InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
				DispatchQueue.main.async { HotKey.shared.onPress?() }
				return noErr
			}, 1, &spec, nil, &handler)
		}
		let id = EventHotKeyID(signature: OSType(0x4150_4C43), id: 1)	// 'APLC'
		RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
	}

	private func unregister() {
		if let ref { UnregisterEventHotKey(ref) }
		ref = nil
	}
}
