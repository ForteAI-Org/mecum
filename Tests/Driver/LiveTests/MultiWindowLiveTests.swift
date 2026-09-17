//
//  MultiWindowLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
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

/// Two controlled windows on one seat, each its own process because one fixture
/// process opens one window: the target moves between them, the window server
/// is asked which of them is really on stage, and every Command's **effect** is
/// read out of the target that was supposed to receive it.
///
/// What this row is for, said plainly: delivery is not the claim. A Receipt
/// proves events went out, and the whole point of several windows is that they
/// could go to the wrong one. So each action is verified by the counter of the
/// application it was aimed at, and by that counter standing still in the other.
@Suite(.serialized)
@MainActor
struct MultiWindowLiveTests {

    /// Whether the person has Stage Manager on right now. It is read and never
    /// written: which of the two the machine is in decides what "the other
    /// window is still on stage" has to mean, and a test that set it would be
    /// changing a system setting to make its own assertion true.
    static var stageManagerIsEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?
            .object(forKey: "GloballyEnabled") as? Bool ?? false
    }

    /// True when the window server still shows this window at the size the
    /// target says it has. A stashed window reads as a thumbnail, so this is
    /// the same question `AgentSeat.isStaged` answers and the one the row
    /// compares the seat against.
    static func serverShowsFullSize(_ target: FixtureTarget) -> Bool {
        guard let frame = WindowServerProbe.geometry(of: target.window.windowNumber)?.frame
        else { return false }
        return abs(frame.width - target.expectedSize.width) <= 2
            && abs(frame.height - target.expectedSize.height) <= 2
    }

    @Test("two controlled windows: the target moves, the effect lands in the chosen one",
          .enabled(if: liveSkipReason(needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true) ?? "")))
    func targetMovesBetweenTwoWindows() async throws {

        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in

            let stageManager = Self.stageManagerIsEnabled
            let person       = stage.personBefore
            print("MW01 stage manager \(stageManager ? "ON" : "OFF"), "
                + "person in \(person.frontmostName) (\(person.frontmostProcessID)) "
                + "cursor \(person.cursor)")

            let first  = try FixtureTarget.launched()
            defer { first.terminate() }
            let second = try FixtureTarget.launched()
            defer { second.terminate() }

            // Both fixtures came up in front of the person. Their seat is theirs.
            if let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID) {
                previous.activate()
                LivePump.run(for: 0.6)
            }
            try #require(first.latest.processID != second.latest.processID,
                         "The two windows must be two processes: one fixture opens one window")
            #expect(UserSeatState.capture() == person,
                    "Launching the targets already moved the person's seat")

            let seat       = stage.seat
            let handBefore = stage.fence.snapshot().observedEventCount
            let a = try await adopt(first,  onto: seat, bounds: stage.virtualBounds)
            let b = try await adopt(second, onto: seat, bounds: stage.virtualBounds)

            #expect(seat.adoptedWindows.count == 2)
            #expect(seat.currentTarget?.id == b.id, "The window adopted last is the target")
            #expect(seat.targetHistory == [a.id, b.id])
            print("MW01 adopted a=\(a.id) b=\(b.id), target \(String(describing: seat.currentTarget?.id))")

            // The effect lands in the window the request names, in the target
            // the seat currently has, and nowhere else.
            try await Self.clickAndVerify(second, other: first, window: b, seat: seat)

            // MARK: the target moves back to the window adopted first

            _ = try await seat.switchTarget(to: a)
            LivePump.run(for: 0.5)
            first.refresh()
            second.refresh()

            #expect(seat.currentTarget?.id == a.id)
            #expect(seat.targetHistory == [b.id, a.id], "A to B to A leaves B as A's predecessor")
            #expect(seat.isStaged(a))
            #expect(first.isStaged(within: stage.virtualBounds),
                    "the new target never came on stage at full size")

            // The one assertion that holds in both Stage Manager modes, and the
            // defect this ticket is about: what the seat says about the *other*
            // window is the window server's reading of it, not a memory of
            // which `stage` was called last.
            let otherIsFullSize = Self.serverShowsFullSize(second)
            #expect(seat.isStaged(b) == otherIsFullSize,
                    Comment(rawValue: "stage manager \(stageManager ? "on" : "off"): the seat says "
                        + "b staged \(seat.isStaged(b)) while the window server shows "
                        + "\(String(describing: WindowServerProbe.geometry(of: b.id)?.frame))"))
            if !stageManager {
                #expect(otherIsFullSize,
                        "with Stage Manager off both windows stay on the display at full size")
            }
            print("MW01 after switch: a staged \(seat.isStaged(a)), b staged \(seat.isStaged(b)), "
                + "server full size b \(otherIsFullSize)")

            try await Self.clickAndVerify(first, other: second, window: a, seat: seat)

            // MARK: releasing the target hands the seat to its predecessor

            _ = await seat.release(a)
            LivePump.run(for: 1.0)
            second.refresh()

            #expect(seat.adoptedWindows.map(\.id) == [b.id])
            #expect(seat.currentTarget?.id == b.id, "the predecessor takes over when the target goes")
            #expect(seat.isStaged(b), "the predecessor is put back on stage, not only chosen")

            // The stream's reader is a task of its own, and `LivePump` turns the
            // application's loop rather than the concurrency runtime's: without
            // this the last event is published and not yet delivered.
            for _ in 0..<40 { await Task.yield() }
            let targetChanges = stage.events.events.compactMap { event -> (Int, SeatTargetChange)? in
                guard case .targetChanged(_, let to, let reason) = event else { return nil }
                return (to.windowNumber, reason)
            }
            #expect(targetChanges.map(\.1) == [.adopted, .adopted, .requested, .predecessor],
                    Comment(rawValue: "target changes published: \(targetChanges)"))
            #expect(targetChanges.map(\.0) == [a.id, b.id, a.id, b.id],
                    Comment(rawValue: "target changes published: \(targetChanges)"))

            // And the predecessor still receives what it is sent.
            try await Self.clickAndVerify(second, other: nil, window: b, seat: seat)

            await stage.giveBack(b, of: second, home: nil)

            // The User Seat, judged the way the rest of this tier judges it: a
            // cursor that moved while the fence was counting the person's own
            // events is their hand, and the row says inconclusive rather than
            // either passing or blaming the kit. An inconclusive row is a
            // recorded issue, so it can never be read as a pass.
            let after    = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount &- handBefore
            print("MW01 person after: \(after.frontmostName) (\(after.frontmostProcessID)) "
                + "cursor \(after.cursor), \(physical) physical events during the run")

            #expect(after.frontmostProcessID == person.frontmostProcessID,
                    "the person's frontmost application changed to \(after.frontmostName)")
            if physical == 0 {
                #expect(after.cursor == person.cursor,
                        "the physical cursor moved with no physical input to explain it")
            } else if after.cursor != person.cursor {
                Issue.record(Comment(rawValue: "inconclusive: the cursor moved with \(physical) "
                    + "physical events during the run. Rerun without touching the machine."))
            }
        }
    }

    /// Posts one click at the target's own button and proves the **effect**:
    /// that target's press counter moved and the other one's did not.
    private static func clickAndVerify(
        _ target: FixtureTarget,
        other   : FixtureTarget?,
        window  : AdoptedWindow,
        seat    : AgentSeat
    ) async throws {

        target.refresh()
        other?.refresh()
        let before      = target.state()["clicks"] ?? -1
        let otherBefore = other?.state()["clicks"] ?? 0
        let point       = try #require(target.clickPoint(), "the target published no reachable button")
        let location    = try target.location(of: point)

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            .click(location),
            to      : window,
            turn    : turn,
            platform: target.platform
        )
        let landed = LivePump.run(
            until  : { (target.state()["clicks"] ?? -1) > before },
            timeout: 3
        )
        try seat.confirm(receipt, landed ? .observed : .absent)
        _ = await seat.concludeObservation()
        try seat.release(turn)

        other?.refresh()
        let otherAfter = other?.state()["clicks"] ?? 0
        print("MW01 click on window \(window.id): clicks \(before) -> "
            + "\(target.state()["clicks"] ?? -1), routed to \(receipt.route.windowNumber), "
            + "other \(otherBefore) -> \(otherAfter)")

        #expect(receipt.route.windowNumber == window.id, "the events were routed to another window")
        #expect(landed, "the click never reached the window it was addressed to")
        #expect(otherAfter == otherBefore, "the other window received the click as well")
    }
}
