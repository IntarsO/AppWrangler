//
//  AudioActivity.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Which processes are playing or recording audio right now. Auto mode treats
//  them as "in use" even in the background: music, calls, dictation (Wispr Flow)…
//  Uses CoreAudio's per-process objects (macOS 14.2+); no permission needed.
//

import CoreAudio

enum AudioActivity {
	/// PIDs currently producing audio output or capturing input.
	static func activePids() -> Set<pid_t> {
		guard #available(macOS 14.2, *) else { return [] }
		var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
												 mScope: kAudioObjectPropertyScopeGlobal,
												 mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
		var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }

		var pids = Set<pid_t>()
		for object in objects {
			guard flag(object, kAudioProcessPropertyIsRunningOutput) || flag(object, kAudioProcessPropertyIsRunningInput) else { continue }
			var pid: pid_t = 0
			var pidSize = UInt32(MemoryLayout<pid_t>.size)
			var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
														mScope: kAudioObjectPropertyScopeGlobal,
														mElement: kAudioObjectPropertyElementMain)
			if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 {
				pids.insert(pid)
			}
		}
		return pids
	}

	@available(macOS 14.2, *)
	private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
		var value: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
												 mElement: kAudioObjectPropertyElementMain)
		return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
	}
}
