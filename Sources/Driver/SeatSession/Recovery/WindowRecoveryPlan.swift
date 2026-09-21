//
//  WindowRecoveryPlan.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// RecoveryStep is what the recovery loop should do next. It is a value and not
/// a call, so the policy that decides it is a pure function and the loop that
/// performs it has no decisions in it at all.
nonisolated public enum RecoveryStep: Sendable, Equatable {

    /// Read again after the cadence. Nothing is written to the window.
    case observe

    /// Two consecutive readings agree and the window is where it belongs: the
    /// seat goes back to work.
    case finish

    /// Put the window back on the virtual display at this origin. Never while
    /// the target application is active, which the policy checks and does not
    /// leave to the loop.
    case relocate(to: CGPoint)

    /// Adapt a window that came to rest larger than the display to this size.
    ///
    /// It exists because a move cannot change a size. The plan verifies the
    /// window's whole frame, and answering a size it disagrees with by writing
    /// an origin is a recovery whose effect cannot reach the property it is
    /// checking: it relocated the window three times, each time read the same
    /// size back, and gave up with `recoveryExhausted`.
    case resize(to: CGSize)

    /// The window came to rest at a new size, inside the display, under the
    /// same identity: a legitimate resize. The seat takes this reading as its
    /// operational geometry and the previous coordinates stop being current.
    case acceptResize(WindowReference)

    /// Give up with this Issue.
    case fail(SeatIssue)
}

/// WindowRecoveryPlan is the bounded sequence that answers a recoverable Issue,
/// as a state machine over window server readings.
///
/// Every number in it is a default rather than a constant: 250 ms between
/// readings, two consecutive agreeing readings before
/// the seat is called recovered, at most three relocations, and five seconds of
/// an unreadable window before `recoveryExhausted`.
///
/// ## What it refuses to do
///
/// It reads the **window server**, never Accessibility: an application's own
/// geometry and the server's are updated at different moments, so one of them
/// alone is not evidence.
///
/// It never relocates a window whose application is active. The person is using
/// that application, and moving its window while they are in it is the one
/// thing the whole kit exists not to do. In `waiting` there is no relocation at
/// all.
///
/// It never answers one property of the frame by writing another: a size it
/// disagrees with is adapted or accepted, never relocated.
///
/// It never authorizes repeating an input. That decision is
/// `RecoveryPolicy.begin` in Core, which fails the seat with `ambiguousEffect`
/// when a Command was posted and its confirmation is `unknown`.
///
/// ## The unreadable budget is elapsed time, not readings times cadence
///
/// The loop sleeps `cadence` between readings, so adding one cadence per
/// missed reading looks like the same number. It is not: the cadence is what
/// the loop asks for and the main actor is what it gets. Under a contended
/// actor twenty readings took over a minute of wall clock while the plan still
/// believed five seconds had passed, which is how a row that waits for
/// `recoveryExhausted` turned into a row that waits for the scheduler.
///
/// So the budget is measured. The first unreadable reading fixes the instant
/// the window stopped being readable and the limit is an absolute deadline
/// from it; later readings compare against that instant and cannot renew it,
/// however many or few of them arrive. `readings` and `elapsedNanoseconds` are
/// kept beside it so a caller can say which of the three it is looking at.
///
/// The instant is the episode's start while no reading has answered yet. An
/// episode opens because something was already wrong with the window, so a
/// first reading that misses is not the beginning of the outage, it is the
/// first measurement of one that was already running, and the loop's own
/// scheduling is not a reason to start the clock later. Past the first answer
/// the instant is the miss itself, because a window that read a moment ago was
/// readable a moment ago.
nonisolated public struct WindowRecoveryPlan: Sendable, Equatable {

    /// How long between two readings.
    public static let defaultCadence: Duration = .milliseconds(250)

    /// How many consecutive agreeing readings prove the window came to rest.
    public static let defaultStableReadings = 2

    /// How many times the window may be put back before giving up.
    public static let defaultRelocationLimit = 3

    /// How long a window may stay unreadable before `recoveryExhausted`.
    public static let defaultUnreadableLimit: Duration = .seconds(5)

    /// The longest a Command can take, which is what the recovery waits for
    /// before it changes any geometry: a drag is a `mouseMoved`, eight paced
    /// intermediate points and the 900 ms settle the consumer's verification
    /// needs. Past it the Command counts as `unknown` and
    /// `RecoveryPolicy.begin` turns that into a failed seat.
    public static let maximumCommandDuration: Duration = .milliseconds(1_500)

    public let cadence         : Duration
    public let stableReadings  : Int
    public let relocationLimit : Int
    public let unreadableLimit : Duration

    /// Where the window belongs on the virtual display.
    public let expectedOrigin: CGPoint

    /// The identity the window must still have.
    public let target: WindowReference

    /// The virtual display's bounds, which a recovered frame has to be inside.
    public let displayBounds: CGRect

    public private(set) var relocations         = 0
    /// How many times a too-large window has been adapted. It spends
    /// `relocationLimit` rather than a budget of its own: it is the same
    /// question asked of the other property of the same frame, and an
    /// application that keeps refusing the size is the case it bounds.
    public private(set) var adaptations         = 0
    public private(set) var agreeingReadings    = 0

    /// How long the window has been unreadable, measured from the first miss.
    public private(set) var unreadableNanoseconds: UInt64 = 0

    /// How many readings have been folded in. It is a diagnostic and never a
    /// budget: a reading that took a minute to arrive counts the same as one
    /// that took the cadence, which is exactly why nothing is decided on it.
    public private(set) var readings = 0

    /// When the episode started and when its last reading was folded, so the
    /// wall clock the loop actually spent can be told from the time the budget
    /// counted and from the number of laps it took.
    public let startedAtNanoseconds: UInt64
    public private(set) var lastStepAtNanoseconds: UInt64

    public var elapsedNanoseconds: UInt64 {
        lastStepAtNanoseconds > startedAtNanoseconds
            ? lastStepAtNanoseconds &- startedAtNanoseconds
            : 0
    }

    private var lastReading: WindowReference?

    /// The instant the window stopped being readable. The deadline is absolute
    /// from here, so polling does not renew it.
    private var unreadableSinceNanoseconds: UInt64?

    /// Whether any reading has ever answered. Until one has, an unreadable
    /// reading is charged from the episode's start rather than from itself:
    /// the episode was opened because something was already wrong, and the
    /// interval before the loop's first reading is part of the wait whether or
    /// not the loop was given the actor in time to measure it.
    private var hasEverBeenReadable = false

    public init(
        target             : WindowReference,
        expectedOrigin     : CGPoint,
        displayBounds      : CGRect,
        cadence            : Duration = defaultCadence,
        stableReadings     : Int      = defaultStableReadings,
        relocationLimit    : Int      = defaultRelocationLimit,
        unreadableLimit    : Duration = defaultUnreadableLimit,
        startedAtNanoseconds: UInt64  = DispatchTime.now().uptimeNanoseconds
    ) {
        self.target               = target
        self.expectedOrigin       = expectedOrigin
        self.displayBounds        = displayBounds
        self.cadence              = cadence
        self.stableReadings       = stableReadings
        self.relocationLimit      = relocationLimit
        self.unreadableLimit      = unreadableLimit
        self.startedAtNanoseconds = startedAtNanoseconds
        self.lastStepAtNanoseconds = startedAtNanoseconds
    }

    /// step folds one reading into the plan and answers what to do next.
    ///
    /// `server` is the window server's geometry for the Window ID, nil when the
    /// window is not readable, which is common while a Space or a Stage Manager
    /// transition is in flight and is the reason an unreadable window is given
    /// five seconds instead of failing on the first miss.
    ///
    /// `targetIsActive` is three-valued for the same reason it is on
    /// `SeatSensing`: nil means the process is gone, which is critical and not
    /// something to keep reading about.
    ///
    /// `now` is the monotonic clock this reading was taken at. It defaults to
    /// the clock so the loop does not have to carry one, and is written down
    /// by the suites that need the budget to pass without the wait passing.
    public mutating func step(
        server        : WindowReference?,
        targetIsActive: Bool?,
        at now        : UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> RecoveryStep {

        readings             += 1
        lastStepAtNanoseconds = now

        guard let targetIsActive else { return .fail(.processUnavailable) }

        guard let server else {

            let since = unreadableSinceNanoseconds
                ?? (hasEverBeenReadable ? now : startedAtNanoseconds)
            unreadableSinceNanoseconds = since
            unreadableNanoseconds      = now > since ? now &- since : 0
            agreeingReadings           = 0
            lastReading                = nil

            return unreadableNanoseconds >= UInt64(unreadableLimit.wholeNanoseconds)
                ? .fail(.recoveryExhausted)
                : .observe
        }

        unreadableSinceNanoseconds = nil
        unreadableNanoseconds      = 0
        hasEverBeenReadable        = true

        guard server.hasSameIdentity(as: target) else { return .fail(.identityChanged) }

        // The person is in the application. Keep watching, write nothing: the
        // seat is in `waiting` and the exit from it is theirs, not a timeout's.
        if targetIsActive {
            agreeingReadings = 0
            lastReading      = server
            return .observe
        }

        // Two readings that agree, not one, and counted before the frame is
        // judged: the size question needs the count as much as the origin does.
        if let lastReading, VirtualWindowPlacementCheck.framesMatch(lastReading.frame, server.frame) {
            agreeingReadings += 1
        } else {
            agreeingReadings = 1
        }

        lastReading = server

        // The size first and separately, so that every step this plan takes
        // can change the property that produced it.
        let sizeIsOperational = VirtualWindowPlacementCheck.framesMatch(
            CGRect(origin: .zero, size: server.frame.size),
            CGRect(origin: .zero, size: target.frame.size)
        )

        guard sizeIsOperational else {

            // Still moving: a reading taken mid-resize is a size the window is
            // already leaving, and neither accepting nor adapting it is right.
            guard agreeingReadings >= stableReadings else { return .observe }

            // Settled, inside the display, same identity: that is the whole of
            // what makes a resize legitimate here.
            if displayBounds.contains(server.frame) { return .acceptResize(server) }

            // It does not fit. The readings after the write are what verify
            // it, which is why the agreement starts again from nothing.
            guard adaptations < relocationLimit else { return .fail(.recoveryExhausted) }

            adaptations     += 1
            agreeingReadings = 0
            lastReading      = nil

            return .resize(to: CGSize(
                width : min(server.frame.width,  displayBounds.width),
                height: min(server.frame.height, displayBounds.height)
            ))
        }

        let isWhereItBelongs = VirtualWindowPlacementCheck.framesMatch(
            server.frame,
            CGRect(origin: expectedOrigin, size: target.frame.size)
        ) && displayBounds.contains(server.frame)

        guard isWhereItBelongs else {

            agreeingReadings = 0
            lastReading      = server

            guard relocations < relocationLimit else { return .fail(.recoveryExhausted) }

            relocations += 1
            return .relocate(to: expectedOrigin)
        }

        return agreeingReadings >= stableReadings ? .finish : .observe
    }
}

extension Duration {

    /// The duration in whole nanoseconds, which is the unit the recovery's
    /// budgets are accumulated in. `components` is seconds plus attoseconds,
    /// and an attosecond is 1e-18, so the second term divides by 1e9.
    nonisolated var wholeNanoseconds: Int64 {
        let seconds = components.seconds
        let (wholeSeconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let fractional = components.attoseconds / 1_000_000_000
        let (result, additionOverflow) = wholeSeconds.addingReportingOverflow(fractional)
        guard !secondsOverflow, !additionOverflow else {
            return seconds < 0 ? .min : .max
        }
        return result
    }
}
