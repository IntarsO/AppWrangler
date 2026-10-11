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
		let a = activity()
		return a.output.union(a.input)
	}

	/// PIDs playing audio, and PIDs recording it (a call, dictation). Recording is the
	/// surest sign of a meeting.
	static func activity() -> (output: Set<pid_t>, input: Set<pid_t>) {
		guard #available(macOS 14.2, *) else { return ([], []) }
		var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
												 mScope: kAudioObjectPropertyScopeGlobal,
												 mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return ([], []) }
		var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return ([], []) }

		var output = Set<pid_t>(), input = Set<pid_t>()
		for object in objects {
			let out = flag(object, kAudioProcessPropertyIsRunningOutput)
			let inp = flag(object, kAudioProcessPropertyIsRunningInput)
			guard out || inp else { continue }
			var pid: pid_t = 0
			var pidSize = UInt32(MemoryLayout<pid_t>.size)
			var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
														mScope: kAudioObjectPropertyScopeGlobal,
														mElement: kAudioObjectPropertyElementMain)
			guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { continue }
			if out { output.insert(pid) }
			if inp { input.insert(pid) }
		}
		return (output, input)
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
