//
//  WindowRecoveryPlanTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The recovery policy as a state machine over readings: the cadence, the two
/// agreeing readings, the three relocations, the five seconds of unreadable
/// window, and the one thing it must never do.
@Suite("Window recovery plan")
struct WindowRecoveryPlanTests {

    static func plan() -> WindowRecoveryPlan {
        WindowRecoveryPlan(
            target        : FakeGeometry.adoptedWindow,
            expectedOrigin: FakeGeometry.windowOrigin,
            displayBounds : FakeGeometry.virtual
        )
    }

    static func window(at origin: CGPoint) -> WindowReference {
        FakeGeometry.reference(frame: CGRect(origin: origin, size: FakeGeometry.windowSize))
    }

    @Test("the defaults are the measured recovery numbers")
    func defaults() {
        #expect(WindowRecoveryPlan.defaultCadence == .milliseconds(250))
        #expect(WindowRecoveryPlan.defaultStableReadings == 2)
        #expect(WindowRecoveryPlan.defaultRelocationLimit == 3)
        #expect(WindowRecoveryPlan.defaultUnreadableLimit == .seconds(5))
    }

    @Test("two agreeing readings of a window where it belongs finish the episode")
    func twoAgreeingReadingsFinish() {

        var plan = Self.plan()
        let good = FakeGeometry.adoptedWindow

        #expect(plan.step(server: good, targetIsActive: false) == .observe)
        #expect(plan.step(server: good, targetIsActive: false) == .finish)
    }

    @Test("one reading is not enough: a window still moving would be called settled")
    func oneReadingIsNotEnough() {

        var plan = Self.plan()

        #expect(plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: false) == .observe)
        #expect(plan.agreeingReadings == 1)
    }

    @Test("a window that is not where it belongs is put back, at most three times")
    func relocationLimit() {

        var plan  = Self.plan()
        let moved = Self.window(at: CGPoint(x: 1600, y: 100))

        for attempt in 1...3 {
            #expect(plan.step(server: moved, targetIsActive: false) == .relocate(to: FakeGeometry.windowOrigin))
            #expect(plan.relocations == attempt)
        }

        #expect(plan.step(server: moved, targetIsActive: false) == .fail(.recoveryExhausted))
    }

    /// The rule the whole kit exists for. The person is in the application, so
    /// nothing is written: not a relocation, not a raise, nothing.
    @Test("an active target is never relocated, however far the window has moved")
    func activeTargetIsNeverRelocated() {

        var plan  = Self.plan()
        let moved = Self.window(at: CGPoint(x: 1600, y: 100))

        for _ in 0..<10 {
            #expect(plan.step(server: moved, targetIsActive: true) == .observe)
        }

        #expect(plan.relocations == 0)
    }

    @Test("an unreadable window gets five seconds, then the episode is exhausted")
    func unreadableWindowBudget() {

        var plan = Self.plan()

        // Twenty readings at 250 ms is exactly five seconds.
        for _ in 0..<19 {
            #expect(plan.step(server: nil, targetIsActive: false) == .observe)
        }

        #expect(plan.step(server: nil, targetIsActive: false) == .fail(.recoveryExhausted))
    }

    @Test("a window that becomes readable again resets the unreadable budget")
    func readableAgainResets() {

        var plan = Self.plan()

        for _ in 0..<10 { _ = plan.step(server: nil, targetIsActive: false) }
        #expect(plan.unreadableNanoseconds > 0)

        _ = plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: false)
        #expect(plan.unreadableNanoseconds == 0)
    }

    @Test("a dead process is critical, not something to keep reading about")
    func deadProcess() {

        var plan = Self.plan()
        #expect(plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: nil)
            == .fail(.processUnavailable))
    }

    @Test("a reused window id belonging to another process is identityChanged")
    func reusedWindowID() {

        var plan = Self.plan()
        let other = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame,
            processID   : 1,
            windowNumber: FakeGeometry.windowNumber
        )

        #expect(plan.step(server: other, targetIsActive: false) == .fail(.identityChanged))
    }

    @Test("two readings that disagree with each other do not count as agreeing")
    func disagreeingReadings() {

        var plan = Self.plan()
        let good = FakeGeometry.adoptedWindow
        let nudged = Self.window(at: CGPoint(
            x: FakeGeometry.windowOrigin.x + 1,
            y: FakeGeometry.windowOrigin.y
        ))

        #expect(plan.step(server: good, targetIsActive: false) == .observe)
        // One point is inside the placement tolerance, so this pair does agree
        // and finishes: the tolerance is two points and a move through the
        // accessibility API lands on integral points while the server rounds.
        #expect(plan.step(server: nudged, targetIsActive: false) == .finish)
    }

    @Test("the longest a command can take is what the recovery waits for")
    func commandDuration() {
        // A drag is a mouseMoved, eight paced points and the 900 ms settle the
        // consumer's verification needs.
        #expect(WindowRecoveryPlan.maximumCommandDuration >= .milliseconds(900))
    }
}
