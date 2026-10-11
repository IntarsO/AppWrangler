//
//  Meeting.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  You're in a call: an app has been recording from the microphone for a few seconds
//  (Zoom, Teams, FaceTime, Google Meet in a browser). AppWrangler then makes room for
//  that app by itself (see MakeRoom.swift) and stops a minute after the call ends.
//  The camera being on keeps a call going (muted but on video); it can't start one,
//  because macOS doesn't say which app is using the camera. Nothing is sent anywhere,
//  and no permission is needed to read these signals.
//

import CoreMediaIO
import Foundation

enum CameraActivity {
	/// Whether any camera is in use by any app.
	static func isAnyCameraRunning() -> Bool {
		var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
												mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
												mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
		var size: UInt32 = 0
		let system = CMIOObjectID(kCMIOObjectSystemObject)
		guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
		var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
		var used: UInt32 = 0
		guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
		var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
												mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
												mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
		return devices.contains { device in
			var value: UInt32 = 0
			var got: UInt32 = 0
			return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == 0 && value != 0
		}
	}
}

/// Decides which app you're in a call with, from who's recording audio.
final class MeetingDetector {
	/// The microphone must be in use this long before it counts as a call (a dictation
	/// hotkey or a notification sound doesn't).
	var startAfter: TimeInterval = 5
	/// A call ends when nothing has been recorded for this long (and the camera is off).
	var endAfter: TimeInterval = 60

	private(set) var callGroupID: String?
	private(set) var callSince: Date?
	private var recordingSince: [String: Date] = [:]
	private var lastRecording: Date?
	private var snoozedUntil: [String: Date] = [:]

	/// - Parameters:
	///   - recording: group ids of apps currently recording audio.
	///   - cameraOn: any camera in use.
	/// - Returns: the group you're in a call with, if any.
	@discardableResult
	func update(recording: Set<String>, cameraOn: Bool, now: Date = Date()) -> String? {
		snoozedUntil = snoozedUntil.filter { $0.value > now }
		for id in recording where recordingSince[id] == nil { recordingSince[id] = now }
		recordingSince = recordingSince.filter { recording.contains($0.key) }
		if !recording.isEmpty { lastRecording = now }

		if let current = callGroupID {
			let stillRecording = recording.contains(current)
			let quietFor = lastRecording.map { now.timeIntervalSince($0) } ?? .infinity
			if stillRecording || cameraOn || quietFor < endAfter { return current }
			callGroupID = nil
			callSince = nil
		}
		// A new call: the app that has been recording longest, past the start delay, and not snoozed.
		let candidates = recordingSince.filter { now.timeIntervalSince($0.value) >= startAfter && snoozedUntil[$0.key] == nil }
		guard let chosen = candidates.min(by: { $0.value < $1.value }) else { return nil }
		callGroupID = chosen.key
		callSince = chosen.value
		return chosen.key
	}

	/// You stopped making room during this call: don't start again for this app for `seconds`.
	func snooze(_ groupID: String, for seconds: TimeInterval = 1800, now: Date = Date()) {
		snoozedUntil[groupID] = now.addingTimeInterval(seconds)
		if callGroupID == groupID {
			callGroupID = nil
			callSince = nil
		}
	}

	func reset() {
		callGroupID = nil
		callSince = nil
		recordingSince = [:]
		lastRecording = nil
	}
}
