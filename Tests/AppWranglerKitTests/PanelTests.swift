//
//  PanelTests.swift
//  AppWranglerKitTests
//  SPDX-License-Identifier: GPL-2.0-only
//

import Foundation
import Testing
@testable import AppWranglerKit

/// The menu bar panel's chart history and the cards for what AppWrangler just did.
@Suite struct PanelTests {
	let t0 = Date(timeIntervalSince1970: 1_000_000)

	private func point(_ seconds: TimeInterval, cpu: Double = 0.2) -> SystemPoint {
		SystemPoint(time: t0.addingTimeInterval(seconds), cpu: cpu, efficiency: 0.05, memoryUsed: 4_000_000_000, pressure: 1)
	}

	private func action(_ app: String, kind: PanelAction.Kind = .autoFreeze, at seconds: TimeInterval = 0) -> PanelAction {
		PanelAction(date: t0.addingTimeInterval(seconds), kind: kind, groupID: "app:" + app, name: app, bundleID: nil, path: "/Applications/\(app).app",
					title: app, detail: "detail")
	}

	// MARK: Chart history

	@Test func historyKeepsTenMinutes() {
		let history = SystemHistory()
		for s in stride(from: 0.0, through: 900, by: 2) { history.record(point(s)) }
		let first = history.points.first!.time, last = history.points.last!.time
		#expect(last.timeIntervalSince(first) <= 600)
		#expect(last.timeIntervalSince(first) > 590)
	}

	@Test func historyKeepsAtMostOneSamplePerSecond() {
		let history = SystemHistory()
		history.record(point(0, cpu: 0.1))
		history.record(point(0.4, cpu: 0.9))	// too soon: replaces the previous one
		history.record(point(2, cpu: 0.3))
		#expect(history.points.count == 2)
		#expect(history.points.first?.cpu == 0.9)
	}

	// MARK: Cards

	@Test func aCardHidesThirtySecondsAfterItIsShown() {
		var actions = PanelActions()
		actions.add(action("Photos"), shown: true)
		#expect(actions.visible(at: t0.addingTimeInterval(29)).count == 1)
		#expect(actions.visible(at: t0.addingTimeInterval(31)).isEmpty)
	}

	@Test func aCardNobodySawWaitsForThePanelToOpen() {
		var actions = PanelActions()
		actions.add(action("Photos"), shown: false)
		// Ten minutes later it's still there: the panel was closed the whole time.
		let later = t0.addingTimeInterval(600)
		#expect(actions.visible(at: later).count == 1)
		#expect(actions.visible(at: later).first?.remaining(at: later) == 1)
		// The panel opens: now the 30 s start.
		actions.markShown(at: later)
		#expect(actions.visible(at: later.addingTimeInterval(20)).count == 1)
		#expect(actions.visible(at: later.addingTimeInterval(31)).isEmpty)
	}

	@Test func unseenCardsExpireAfterFifteenMinutes() {
		var actions = PanelActions()
		actions.add(action("Photos"), shown: false)
		#expect(actions.visible(at: t0.addingTimeInterval(14 * 60)).count == 1)
		#expect(actions.visible(at: t0.addingTimeInterval(16 * 60)).isEmpty)
		actions.prune(at: t0.addingTimeInterval(16 * 60))
		#expect(actions.items.isEmpty)
	}

	@Test func aNewerCardReplacesTheOlderOneForTheSameApp() {
		var actions = PanelActions()
		actions.add(action("Photos", kind: .autoFreeze, at: 0), shown: true)
		actions.add(action("Preview", at: 5), shown: true)
		actions.add(action("Photos", kind: .runaway, at: 10), shown: true)
		#expect(actions.items.map(\.name) == ["Photos", "Preview"])
		#expect(actions.items.first?.kind == .runaway)
	}

	@Test func theNewestCardsComeFirstAndOnlyThreeShow() {
		var actions = PanelActions()
		for (i, app) in ["A", "B", "C", "D"].enumerated() { actions.add(action(app, at: Double(i)), shown: true) }
		#expect(actions.visible(at: t0.addingTimeInterval(5)).map(\.name) == ["D", "C", "B"])
	}

	@Test func dismissingRemovesTheCard() {
		var actions = PanelActions()
		let card = action("Photos")
		actions.add(card, shown: true)
		actions.dismiss(card.id)
		#expect(actions.items.isEmpty)
	}

	@Test func theCountdownRunsFromOneToZero() {
		var actions = PanelActions()
		actions.add(action("Photos"), shown: true)
		let card = actions.items[0]
		#expect(card.remaining(at: t0) == 1)
		#expect(abs(card.remaining(at: t0.addingTimeInterval(15)) - 0.5) < 0.001)
		#expect(card.remaining(at: t0.addingTimeInterval(60)) == 0)
	}

	@Test func theInfoMatchesWhatSuggestionsExpect() {
		let info = action("Photos").info
		#expect(info["groupID"] == "app:Photos" && info["name"] == "Photos" && info["path"] == "/Applications/Photos.app")
		#expect(info["bundleID"] == "")
	}
}
