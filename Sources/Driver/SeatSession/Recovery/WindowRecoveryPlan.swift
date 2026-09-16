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
/// It never authorizes repeating an input. That decision is
/// `RecoveryPolicy.begin` in Core, which fails the seat with `ambiguousEffect`
/// when a Command was posted and its confirmation is `unknown`.
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
    public private(set) var agreeingReadings    = 0
    public private(set) var unreadableNanoseconds: UInt64 = 0

    private var lastReading: WindowReference?

    public init(
        target         : WindowReference,
        expectedOrigin : CGPoint,
        displayBounds  : CGRect,
        cadence        : Duration = defaultCadence,
        stableReadings : Int      = defaultStableReadings,
        relocationLimit: Int      = defaultRelocationLimit,
        unreadableLimit: Duration = defaultUnreadableLimit
    ) {
        self.target          = target
        self.expectedOrigin  = expectedOrigin
        self.displayBounds   = displayBounds
        self.cadence         = cadence
        self.stableReadings  = stableReadings
        self.relocationLimit = relocationLimit
        self.unreadableLimit = unreadableLimit
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
    public mutating func step(
        server        : WindowReference?,
        targetIsActive: Bool?
    ) -> RecoveryStep {

        guard let targetIsActive else { return .fail(.processUnavailable) }

        guard let server else {

            unreadableNanoseconds &+= UInt64(cadence.wholeNanoseconds)
            agreeingReadings = 0
            lastReading      = nil

            return unreadableNanoseconds >= UInt64(unreadableLimit.wholeNanoseconds)
                ? .fail(.recoveryExhausted)
                : .observe
        }

        unreadableNanoseconds = 0

        guard server.hasSameIdentity(as: target) else { return .fail(.identityChanged) }

        // The person is in the application. Keep watching, write nothing: the
        // seat is in `waiting` and the exit from it is theirs, not a timeout's.
        if targetIsActive {
            agreeingReadings = 0
            lastReading      = server
            return .observe
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

        // Two readings that agree, not one: a single reading taken while the
        // window is still moving would call the move finished.
        if let lastReading, VirtualWindowPlacementCheck.framesMatch(lastReading.frame, server.frame) {
            agreeingReadings += 1
        } else {
            agreeingReadings = 1
        }

        lastReading = server

        return agreeingReadings >= stableReadings ? .finish : .observe
    }
}

extension Duration {

    /// The duration in whole nanoseconds, which is the unit the recovery's
    /// budgets are accumulated in. `components` is seconds plus attoseconds,
    /// and an attosecond is 1e-18, so the second term divides by 1e9.
    nonisolated var wholeNanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
