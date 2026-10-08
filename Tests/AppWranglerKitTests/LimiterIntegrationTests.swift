//
//  LimiterIntegrationTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Real processes, real signals. Uses /usr/bin/yes as a one-core CPU burner.
//  Serialized because the C limiter is process-wide.
//

import Foundation
import ProcKit
import Testing
@testable import AppWranglerKit

@Suite(.serialized) struct LimiterIntegrationTests {
	@Test func cpuTimeIsReportedInNanosecondsOnAppleSilicon() {
		let pid = spawnBurner()
		defer { reap([pid]) }
		usleep(300_000)
		let usage = measureCPU([pid], seconds: 1)
		#expect(usage > 0.7 && usage < 1.1, "one busy core ≈ 1.0, got \(usage)")
	}

	@Test func groupLimitHoldsAcrossProcesses() {
		let pids = (0..<3).map { _ in spawnBurner() }
		defer { reap(pids); pk_lim_remove_group(9001) }
		usleep(300_000)
		pids.withUnsafeBufferPointer { pk_lim_set_group(9001, $0.baseAddress, 3, 0.5, 0) }
		usleep(2_000_000)
		let usage = measureCPU(pids, seconds: 2)
		#expect(usage > 0.4 && usage < 0.6, "3 burners limited to 50% of a core, got \(usage)")
	}

	// Audit bug #1: pausing limits used to thaw frozen apps.
	@Test func frozenGroupStaysFrozenWhilePaused() {
		let pid = spawnBurner()
		defer { reap([pid]); pk_lim_set_paused(0); pk_lim_remove_group(9002) }
		usleep(200_000)
		var p = pid
		pk_lim_set_group(9002, &p, 1, 0, 1)
		pk_lim_set_paused(1)
		usleep(300_000)
		#expect(measureCPU([pid], seconds: 0.8) < 0.02)
		pk_lim_set_paused(0)
		pk_lim_remove_group(9002)
		usleep(200_000)
		#expect(measureCPU([pid], seconds: 0.8) > 0.7, "runs freely after unfreeze")
	}

	@Test func pauseLiftsCpuLimits() {
		let pid = spawnBurner()
		defer { reap([pid]); pk_lim_set_paused(0); pk_lim_remove_group(9003) }
		var p = pid
		pk_lim_set_group(9003, &p, 1, 0.1, 0)
		usleep(1_500_000)
		#expect(measureCPU([pid], seconds: 1) < 0.2)
		pk_lim_set_paused(1)
		usleep(200_000)
		#expect(measureCPU([pid], seconds: 1) > 0.7)
	}

	@Test func addingAHelperToAFrozenGroupFreezesItWithoutThawingOthers() {
		let a = spawnBurner(), b = spawnBurner()
		defer { reap([a, b]); pk_lim_remove_group(9004) }
		var one = [a]
		pk_lim_set_group(9004, &one, 1, 0, 1)
		usleep(300_000)
		var both = [a, b]
		pk_lim_set_group(9004, &both, 2, 0, 1)
		usleep(100_000)
		#expect(measureCPU([a, b], seconds: 0.8) < 0.02)
	}

	/// The crash-safety path: resumes every stopped process without locks, and
	/// from then on the limiter must never stop anything again — otherwise a
	/// stop racing with AppWrangler's exit would leave an app suspended.
	@Test func releaseAllResumesEverythingAndStopsLimiting() {
		let frozen = spawnBurner(), limited = spawnBurner()
		defer {
			reap([frozen, limited])
			pk_lim_remove_group(9005)
			pk_lim_remove_group(9006)
			pk_release_all_reset_for_testing()
		}
		var f = frozen, l = limited
		pk_lim_set_group(9005, &f, 1, 0, 1)
		pk_lim_set_group(9006, &l, 1, 0.1, 0)	// stopped ~90% of every 50 ms cycle
		_ = pk_set_background(limited, 1)
		usleep(500_000)
		#expect(isStopped(frozen))
		#expect(priority(limited) == 4, "on the efficiency cores")
		pk_release_all()
		#expect(!isStopped(frozen))
		#expect(priority(limited) != 4, "taken off the efficiency cores")
		// Several limiter cycles later, both still run freely.
		usleep(300_000)
		#expect(measureCPU([frozen, limited], seconds: 0.5) > 1.5)
	}

	private func priority(_ pid: pid_t) -> Int32 {
		var info = proc_taskinfo()
		proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
		return info.pti_priority
	}

	private func isStopped(_ pid: pid_t) -> Bool {
		var info = proc_bsdshortinfo()
		proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
		return info.pbsi_status == 4	// SSTOP
	}

	@Test func samplerFindsAndMeasuresAProcess() {
		let pid = spawnBurner()
		defer { reap([pid]) }
		let sampler = Sampler()
		var request = SampleRequest(apps: [:], includeAll: false, includeOtherUsers: false, withThreads: true, matcher: GroupMatcher())
		request.matcher.groupIDs = ["proc:\(pid)"]
		_ = sampler.sampleNow(request)
		usleep(1_000_000)
		let snap = sampler.sampleNow(request)
		let group = snap.groups.first { $0.ownerPid == pid }
		#expect(group != nil)
		#expect(group?.name == "yes")
		#expect((group?.cpu ?? 0) > 0.7)
		#expect(snap.groups.count == 1, "hidden-mode sampling measures only what's asked for")
	}
}
