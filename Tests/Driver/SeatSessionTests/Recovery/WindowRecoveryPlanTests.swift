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

    /// The written clock every timing row uses. The plan takes the instant of
    /// each reading, so a suite can spend the budget without spending the wait
    /// and, more to the point, can spend the wait without spending the budget.
    static let start: UInt64 = 1_000_000_000

    static func plan(startedAt: UInt64) -> WindowRecoveryPlan {
        WindowRecoveryPlan(
            target              : FakeGeometry.adoptedWindow,
            expectedOrigin      : FakeGeometry.windowOrigin,
            displayBounds       : FakeGeometry.virtual,
            startedAtNanoseconds: startedAt
        )
    }

    @Test("an unreadable window gets five measured seconds, then the episode is exhausted")
    func unreadableWindowBudget() {

        var plan = Self.plan(startedAt: Self.start)

        // Four readings that span five seconds, not twenty that assume it.
        #expect(plan.step(server: nil, targetIsActive: false, at: Self.start) == .observe)
        #expect(plan.step(server: nil, targetIsActive: false,
                          at: Self.start + 2_000_000_000) == .observe)
        #expect(plan.step(server: nil, targetIsActive: false,
                          at: Self.start + 4_999_000_000) == .observe)
        #expect(plan.step(server: nil, targetIsActive: false,
                          at: Self.start + 5_000_000_000) == .fail(.recoveryExhausted))
        #expect(plan.readings == 4)
    }

    /// The defect the concurrent suite showed: twenty readings at the nominal
    /// cadence were called five seconds however long they really took, so the
    /// budget expired on a lap count and a starved main actor could hold the
    /// episode open for over a minute.
    @Test("twenty readings inside a second do not spend the five second budget")
    func readingsAreNotTheBudget() {

        var plan = Self.plan(startedAt: Self.start)

        for lap in 0..<20 {
            let step = plan.step(
                server        : nil,
                targetIsActive: false,
                at            : Self.start + UInt64(lap) * 50_000_000
            )
            #expect(step == .observe, "lap \(lap) of a fast loop is not a second of the budget")
        }

        #expect(plan.readings == 20)
        #expect(plan.unreadableNanoseconds == 950_000_000)
    }

    /// The other half of the same rule: the deadline is absolute from the
    /// first miss, so the loop reaching it in two readings is the same answer
    /// as reaching it in fifty.
    @Test("a delayed loop spends the same budget in two readings as in fifty")
    func aDelayedLoopSpendsTheSameBudget() {

        var few  = Self.plan(startedAt: Self.start)
        var many = Self.plan(startedAt: Self.start)

        #expect(few.step(server: nil, targetIsActive: false, at: Self.start) == .observe)
        #expect(few.step(server: nil, targetIsActive: false,
                         at: Self.start + 6_000_000_000) == .fail(.recoveryExhausted))

        var last = RecoveryStep.observe
        for lap in 0...50 {
            last = many.step(
                server        : nil,
                targetIsActive: false,
                at            : Self.start + UInt64(lap) * 120_000_000
            )
        }

        #expect(last == .fail(.recoveryExhausted))
        #expect(few.readings == 2)
        #expect(many.readings == 51, "the laps differ and the verdict does not")
    }

    /// Polling is how the loop asks the question again, and asking again is
    /// not a reason to grant more time.
    @Test("polling does not renew the deadline the first miss fixed")
    func pollingDoesNotRenewTheDeadline() {

        var plan = Self.plan(startedAt: Self.start)

        _ = plan.step(server: nil, targetIsActive: false, at: Self.start)
        for lap in 1...40 {
            _ = plan.step(
                server        : nil,
                targetIsActive: false,
                at            : Self.start + UInt64(lap) * 100_000_000
            )
        }

        // Forty polls later the clock says four seconds and so does the plan.
        #expect(plan.unreadableNanoseconds == 4_000_000_000)
        #expect(plan.step(server: nil, targetIsActive: false,
                          at: Self.start + 5_000_000_000) == .fail(.recoveryExhausted))
    }

    @Test("a window that becomes readable again resets the unreadable budget")
    func readableAgainResets() {

        var plan = Self.plan(startedAt: Self.start)

        for lap in 0..<10 {
            _ = plan.step(
                server        : nil,
                targetIsActive: false,
                at            : Self.start + UInt64(lap) * 250_000_000
            )
        }
        #expect(plan.unreadableNanoseconds > 0)

        _ = plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: false,
                      at: Self.start + 3_000_000_000)
        #expect(plan.unreadableNanoseconds == 0)

        // And the miss after it starts a new deadline rather than resuming the
        // one the readable reading ended.
        _ = plan.step(server: nil, targetIsActive: false, at: Self.start + 3_100_000_000)
        #expect(plan.unreadableNanoseconds == 0)
        #expect(plan.step(server: nil, targetIsActive: false,
                          at: Self.start + 7_000_000_000) == .observe)
    }

    /// The starved case, which is what the concurrent suite measured: the loop
    /// was given the actor once, a minute after the episode opened, and the
    /// window had been unreadable for the whole minute. One reading is enough
    /// to say so, and the budget the episode was always going to spend is not
    /// owed twenty more laps first.
    @Test("a first reading that misses is charged from the episode, not from itself")
    func aStarvedFirstReadingIsChargedFromTheEpisode() {

        var plan = Self.plan(startedAt: Self.start)

        let step = plan.step(
            server        : nil,
            targetIsActive: false,
            at            : Self.start + 65_000_000_000
        )

        #expect(step == .fail(.recoveryExhausted))
        #expect(plan.readings == 1)
        #expect(plan.unreadableNanoseconds == 65_000_000_000)
    }

    /// And the other side of it: once a reading has answered, the outage
    /// starts at the miss, because the window was readable a moment before.
    @Test("a miss after a good reading is charged from the miss")
    func aMissAfterAnAnswerIsChargedFromTheMiss() {

        var plan = Self.plan(startedAt: Self.start)

        _ = plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: false,
                      at: Self.start + 60_000_000_000)
        let step = plan.step(server: nil, targetIsActive: false,
                             at: Self.start + 60_100_000_000)

        #expect(step == .observe)
        #expect(plan.unreadableNanoseconds == 0)
    }

    @Test("the wall clock, the measured budget and the readings are reported apart")
    func theThreeMeasurementsAreDistinct() {

        var plan = Self.plan(startedAt: Self.start)

        _ = plan.step(server: FakeGeometry.adoptedWindow, targetIsActive: false, at: Self.start)
        _ = plan.step(server: nil, targetIsActive: false, at: Self.start + 4_000_000_000)
        _ = plan.step(server: nil, targetIsActive: false, at: Self.start + 5_000_000_000)

        #expect(plan.elapsedNanoseconds == 5_000_000_000, "the wall clock since the episode began")
        #expect(plan.unreadableNanoseconds == 1_000_000_000, "the part of it the budget counted")
        #expect(plan.readings == 3, "and the laps it took, which decide nothing")
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

    static func window(frame: CGRect) -> WindowReference {
        FakeGeometry.reference(frame: frame)
    }

    /// The oracle is independent of the plan: the seat took the window in at
    /// 800 by 600 and the window server reads 880 by 640 twice, which is a
    /// resize of 80 by 40 points at the same identity inside the display.
    @Test("a resize that came to rest inside the display is accepted, not relocated")
    func aSettledResizeIsAccepted() {

        var plan = Self.plan()
        let resized = Self.window(frame: CGRect(
            origin: FakeGeometry.windowOrigin,
            size  : CGSize(width: 880, height: 640)
        ))

        #expect(plan.step(server: resized, targetIsActive: false) == .observe)
        #expect(plan.step(server: resized, targetIsActive: false) == .acceptResize(resized))
        #expect(plan.relocations == 0, "a move is never the answer to a size")
        #expect(plan.adaptations == 0)
    }

    @Test("20 and 100 points are both a resize and neither is a relocation")
    func theAcceptanceRange() {

        for delta in [CGFloat(20), 100] {
            var plan = Self.plan()
            let resized = Self.window(frame: CGRect(
                origin: FakeGeometry.windowOrigin,
                size  : CGSize(width: FakeGeometry.windowSize.width + delta,
                               height: FakeGeometry.windowSize.height + delta)
            ))
            _ = plan.step(server: resized, targetIsActive: false)
            #expect(plan.step(server: resized, targetIsActive: false) == .acceptResize(resized))
            #expect(plan.relocations == 0)
        }
    }

    /// An animated startup and a window being dragged by its corner read a
    /// different size every time. Nothing is accepted and nothing is written.
    @Test("a resize still in flight is accepted by nothing")
    func aResizeInFlightIsNotAccepted() {

        var plan = Self.plan()

        for step in 1...6 {
            let growing = Self.window(frame: CGRect(
                origin: FakeGeometry.windowOrigin,
                size  : CGSize(width: FakeGeometry.windowSize.width + CGFloat(step) * 30,
                               height: FakeGeometry.windowSize.height + CGFloat(step) * 20)
            ))
            #expect(plan.step(server: growing, targetIsActive: false) == .observe)
        }

        #expect(plan.relocations == 0)
        #expect(plan.adaptations == 0)
    }

    @Test("a resize at another identity is refused before anything else")
    func anIncoherentResizeIsRefused() {

        var plan = Self.plan()
        let other = FakeGeometry.reference(
            frame       : CGRect(origin: FakeGeometry.windowOrigin,
                                 size  : CGSize(width: 880, height: 640)),
            windowNumber: FakeGeometry.windowNumber,
            lifetime    : 7
        )

        #expect(plan.step(server: other, targetIsActive: false) == .fail(.identityChanged))
    }

    /// The rule the live case broke: three relocations answered a size the
    /// window still had after all three, and the episode was exhausted having
    /// written nothing that could change it.
    @Test("a size the plan disagrees with never produces a move")
    func aSizeIsNeverAnsweredByAMove() {

        var plan = Self.plan()
        // Moved and resized at once, inside the display.
        let both = Self.window(frame: CGRect(
            x: FakeGeometry.virtual.minX + 40,
            y: FakeGeometry.virtual.minY + 40,
            width : 880,
            height: 640
        ))

        _ = plan.step(server: both, targetIsActive: false)
        #expect(plan.step(server: both, targetIsActive: false) == .acceptResize(both))
        #expect(plan.relocations == 0)
    }

    /// The adaptation, from inside the episode that verifies it: the window
    /// settles larger than the display, is resized to fit, and the readings
    /// that follow are what say the write took.
    @Test("a window too large for the display is adapted and the result verified")
    func aTooLargeWindowIsAdapted() {

        var plan = Self.plan()
        let huge = Self.window(frame: CGRect(
            origin: FakeGeometry.virtual.origin,
            size  : CGSize(width: FakeGeometry.virtual.width + 300,
                           height: FakeGeometry.virtual.height + 200)
        ))

        #expect(plan.step(server: huge, targetIsActive: false) == .observe)
        #expect(plan.step(server: huge, targetIsActive: false)
            == .resize(to: FakeGeometry.virtual.size))
        #expect(plan.adaptations == 1)
        #expect(plan.relocations == 0)

        // The result: the window now fits and two agreeing readings accept it.
        let fitted = Self.window(frame: CGRect(
            origin: FakeGeometry.virtual.origin,
            size  : FakeGeometry.virtual.size
        ))
        #expect(plan.step(server: fitted, targetIsActive: false) == .observe,
                "the agreement starts again from the reading after the write")
        #expect(plan.step(server: fitted, targetIsActive: false) == .acceptResize(fitted))
    }

    @Test("an application that will not take the smaller size exhausts the episode")
    func anAdaptationThatNeverTakes() {

        var plan = Self.plan()
        let huge = Self.window(frame: CGRect(
            origin: FakeGeometry.virtual.origin,
            size  : CGSize(width: FakeGeometry.virtual.width + 300,
                           height: FakeGeometry.virtual.height + 200)
        ))

        for attempt in 1...3 {
            #expect(plan.step(server: huge, targetIsActive: false) == .observe)
            #expect(plan.step(server: huge, targetIsActive: false)
                == .resize(to: FakeGeometry.virtual.size))
            #expect(plan.adaptations == attempt)
        }

        _ = plan.step(server: huge, targetIsActive: false)
        #expect(plan.step(server: huge, targetIsActive: false) == .fail(.recoveryExhausted))
    }

    @Test("a resized window whose application is active is still never written to")
    func anActiveTargetIsNeverResized() {

        var plan = Self.plan()
        let resized = Self.window(frame: CGRect(
            origin: FakeGeometry.windowOrigin,
            size  : CGSize(width: 880, height: 640)
        ))

        for _ in 0..<10 {
            #expect(plan.step(server: resized, targetIsActive: true) == .observe)
        }
        #expect(plan.adaptations == 0)
    }

    @Test("the longest a command can take is what the recovery waits for")
    func commandDuration() {
        // A drag is a mouseMoved, eight paced points and the 900 ms settle the
        // consumer's verification needs.
        #expect(WindowRecoveryPlan.maximumCommandDuration >= .milliseconds(900))
    }
}
