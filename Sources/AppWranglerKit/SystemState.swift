//
//  SystemState.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Power source, Low Power Mode, thermal state and memory pressure — the
//  inputs for conditional rules. Changes are pushed immediately so rules
//  switch on/off the moment you unplug, the Mac heats up, or RAM runs short.
//

import Foundation
import IOKit.ps
import ProcKit

struct SystemState: Equatable {
	var onBattery = false
	var lowPowerMode = false
	/// 0 nominal, 1 fair, 2 serious, 3 critical (ProcessInfo.ThermalState).
	var thermal = 0
	/// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
	var memoryPressure = 1
	var now = Date()

	var isHot: Bool { thermal >= 2 }

	/// Ignores `now`, so a minute ticking over isn't a "change".
	func sameConditions(as other: SystemState) -> Bool {
		onBattery == other.onBattery && lowPowerMode == other.lowPowerMode
			&& thermal == other.thermal && memoryPressure == other.memoryPressure
	}

	static func read() -> SystemState {
		var s = SystemState()
		s.onBattery = PowerSource.onBattery()
		s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
		s.thermal = ProcessInfo.processInfo.thermalState.rawValue
		var mem = pk_memory_stats()
		if pk_memory_stats_get(&mem) == 0 { s.memoryPressure = Int(mem.pressure_level) }
		return s
	}
}

enum PowerSource {
	static func onBattery() -> Bool {
		guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
			  let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
		else { return false }
		return type == kIOPMBatteryPowerKey
	}
}

final class SystemStateMonitor {
	private(set) var current = SystemState.read()
	var onChange: ((SystemState) -> Void)?

	private var powerSource: CFRunLoopSource?
	private var pressureSource: DispatchSourceMemoryPressure?
	private var observers: [NSObjectProtocol] = []

	func start() {
		let context = Unmanaged.passUnretained(self).toOpaque()
		if let src = IOPSNotificationCreateRunLoopSource({ ctx in
			guard let ctx else { return }
			Unmanaged<SystemStateMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
		}, context)?.takeRetainedValue() {
			CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
			powerSource = src
		}

		let nc = NotificationCenter.default
		for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
			observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
		}

		let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
		pressure.setEventHandler { [weak self] in self?.refresh() }
		pressure.resume()
		pressureSource = pressure
	}

	/// Re-read everything; also called from the regular tick so the memory
	/// pressure level never goes stale.
	@discardableResult
	func refresh() -> SystemState {
		let new = SystemState.read()
		let changed = !new.sameConditions(as: current)
		current = new
		if changed { onChange?(new) }
		return new
	}

	deinit {
		if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
		pressureSource?.cancel()
		observers.forEach(NotificationCenter.default.removeObserver)
	}
}
