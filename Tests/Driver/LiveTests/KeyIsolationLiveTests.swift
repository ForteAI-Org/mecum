//
//  KeyIsolationLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import WindowPlacement

/// KeyIsolationLiveTests observes held-key isolation across two owned Chromium windows.
/// A target change must refuse while a key is down; after release the second
/// window must derive its own plain character without inheriting Shift.
@MainActor
struct KeyIsolationLiveTests {

    static let shift = Shortcut.physical(
        PhysicalKey(
            name      : "ShiftLeft",
            virtualKey: 56
        )
    )

    /// letter resolves a physical position from the installed layout. An empty
    /// Unicode payload leaves Chromium to interpret that position and its flags.
    static func letter(on layout: KeyboardLayout) throws -> Shortcut {
        let virtualKey = try #require(
            layout.virtualKey(producing: "c"),
            "the installed layout cannot produce a plain c"
        )
        return Shortcut(.virtualKey(virtualKey))
    }

    @Test(
        "a held modifier refuses a target change and is absent after release on the second window",
        .enabled(
            if: liveSkipReason(needsChrome: true) == nil,
            Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")
        )
    )
    func heldModifiersDoNotCrossTargetChanges() async throws {
        try await LiveStage.run(
            needsFixture: false,
            needsChrome : false
        ) { stage in
            try await Self.measure(on: stage)
        }
    }

    private static func measure(on stage: LiveStage) async throws {
        let page = try #require(
            Bundle.module.url(
                forResource  : "probe-page",
                withExtension: "html"
            )
        )
        let browser = try OwnBrowserTarget.launched(
            pageHTML: String(
                contentsOf: page,
                encoding  : .utf8
            )
        )
        defer { browser.terminate() }
        let added = try browser.openAdditionalWindow()
        let windows = [browser.reference, added].map { reference in
            ChromeTarget(
                window: ChromeWindow(
                    processID   : reference.processID,
                    windowNumber: reference.windowNumber,
                    frame       : reference.frame,
                    title       : ""
                )
            )
        }
        NSRunningApplication(processIdentifier: stage.personBefore.frontmostProcessID)?.activate()
        try #require(
            LivePump.run(
                until: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == stage.personBefore.frontmostProcessID
                },
                timeout: 3
            )
        )
        LivePump.run(for: 0.5)
        try #require(windows[0].processID == windows[1].processID)

        var first = try await adopt(
            windows[0],
            onto  : stage.seat,
            bounds: stage.virtualBounds
        )
        var second = try await adopt(
            windows[1],
            onto  : stage.seat,
            bounds: stage.virtualBounds
        )
        first = try await stage.seat.switchTarget(to: first)
        let person = UserSeatState.capture()
        let physicalBefore = stage.fence.snapshot().observedEventCount
        let turn = try await stage.seat.acquire()
        let layout = try #require(KeyboardLayoutReader.current())
        let firstBefore  = windows[0].state()["field"] ?? 0
        let secondBefore = windows[1].state()["field"] ?? 0

        let down = try await stage.seat.send(
            shift,
            phase      : .down,
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        try #require(
            LivePump.run(
                until  : { windows[0].state()["lastModifiers"] == Double(Modifiers.shift.rawValue) },
                timeout: 2
            )
        )
        try stage.seat.confirm(
            down,
            .observed
        )
        _ = await stage.seat.concludeObservation()

        await #expect(throws: SessionFailure.keysStillHeld(count: 1)) {
            _ = try await stage.seat.switchTarget(to: second)
        }
        try #require(stage.seat.currentTarget?.id == first.id)
        #expect(KeyHold.shared.modifiers(processID: windows[0].processID) == .shift)
        #expect(windows[1].state()["field"] == secondBefore)

        let shifted = try await stage.seat.send(
            try letter(on: layout),
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        try #require(
            LivePump.run(
                until  : { windows[0].state()["field"] == firstBefore + 1 },
                timeout: 2
            )
        )
        #expect(windows[0].state()["lastModifiers"] == Double(Modifiers.shift.rawValue))
        #expect(windows[1].state()["field"] == secondBefore)
        try stage.seat.confirm(
            shifted,
            .observed
        )
        _ = await stage.seat.concludeObservation()

        let up = try await stage.seat.send(
            shift,
            phase      : .up,
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        try #require(
            LivePump.run(
                until  : { windows[0].state()["lastModifiers"] == 0 },
                timeout: 2
            )
        )
        try stage.seat.confirm(
            up,
            .observed
        )
        #expect(KeyHold.shared.modifiers(processID: windows[0].processID).isEmpty)
        _ = await stage.seat.concludeObservation()

        second = try await stage.seat.switchTarget(to: second)
        let plain = try await stage.seat.send(
            try letter(on: layout),
            observation: try await liveObservation(stage.seat),
            turn       : turn
        )
        try #require(
            LivePump.run(
                until  : { windows[1].state()["field"] == secondBefore + 1 },
                timeout: 2
            )
        )
        #expect(windows[1].state()["lastModifiers"] == 0)
        #expect(windows[0].state()["field"] == firstBefore + 1)
        try stage.seat.confirm(
            plain,
            .observed
        )
        _ = await stage.seat.concludeObservation()
        try stage.seat.release(turn)

        let physical = stage.fence.snapshot().observedEventCount - physicalBefore
        let preserved = UserSeatState.capture() == person
        print("CHROMIUM_TWO_WINDOWS held-switch-refused=true first-growth=1 second-growth=1"
            + " second-modifiers=0 physical-events=\(physical) user-seat-preserved=\(preserved)")
        #expect(physical == 0)
        #expect(preserved)
        await stage.giveBack(
            second,
            of  : windows[1],
            home: nil
        )
        await stage.giveBack(
            first,
            of  : windows[0],
            home: nil
        )
    }
}
