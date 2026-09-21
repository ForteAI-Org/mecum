//
//  ObservationProfile.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ObservationProfileRefusal is why a configuration was not accepted. Every
/// budget of this profile is a finite positive value, and a zero, a negative or
/// a non finite one is refused at construction rather than turned into a default
/// nobody asked for.
nonisolated public enum ObservationProfileRefusal: String, Sendable, Equatable, Error {

    case frameAgeLimitNotPositive
    case captureDeadlineNotPositive
    case captureAttemptsNotPositive
    case menuInteractionBudgetNotPositive
    case menuCleanupBudgetNotPositive
}

/// ObservationProfile is the set of finite positive budgets the observation and
/// admission path is run under.
///
/// The initial values are the ones already decided: the content of a Frame may
/// be at most 120 s old when a Command is admitted, one capture has 5 s in total
/// and at most 2 attempts sharing that one absolute deadline, a menu interaction
/// has 180 s from the moment its opening starts, and its cleanup has a separate
/// 2 s measured from the end, the error or the expiry of the interaction.
///
/// ## What these numbers are not
///
/// The 120 s is a policy limit from qualified content to admission, Vision and
/// every wait included. It is not a measured latency, not a timeout of a model
/// and not a statement that any of it has been observed on a real machine. The
/// capture budget is not a promise that ScreenCaptureKit answers inside it: a
/// deadline that passes leaves the native call counted and the resource
/// unconfirmed, and it never declares a slot free.
///
/// Nothing renews: a submenu, a new sample or a late callback does not extend
/// the menu budget, and a coalesced capture does not extend the capture one.
nonisolated public struct ObservationProfile: Sendable, Equatable {

    /// From qualified Frame content to the admission of the Command, 120 s.
    public let frameAgeLimitNanoseconds: UInt64

    /// One whole capture, queueing and waiting included, 5 s.
    public let captureDeadlineNanoseconds: UInt64

    /// Attempts inside that one absolute deadline, 2. They share it; the second
    /// attempt does not restart the count.
    public let captureAttempts: Int

    /// The whole menu interaction from the start of its opening, 180 s.
    public let menuInteractionNanoseconds: UInt64

    /// Cleanup and close verification, measured from the end, the error or the
    /// expiry of the interaction, 2 s.
    public let menuCleanupNanoseconds: UInt64

    /// The profile the initial Lab configuration was decided with.
    public static let initialLab = ObservationProfile(
        frameAgeLimitNanoseconds  : 120_000_000_000,
        captureDeadlineNanoseconds:   5_000_000_000,
        captureAttempts           : 2,
        menuInteractionNanoseconds: 180_000_000_000,
        menuCleanupNanoseconds    :   2_000_000_000
    )

    private init(
        frameAgeLimitNanoseconds  : UInt64,
        captureDeadlineNanoseconds: UInt64,
        captureAttempts           : Int,
        menuInteractionNanoseconds: UInt64,
        menuCleanupNanoseconds    : UInt64
    ) {
        self.frameAgeLimitNanoseconds   = frameAgeLimitNanoseconds
        self.captureDeadlineNanoseconds = captureDeadlineNanoseconds
        self.captureAttempts            = captureAttempts
        self.menuInteractionNanoseconds = menuInteractionNanoseconds
        self.menuCleanupNanoseconds     = menuCleanupNanoseconds
    }

    /// Builds a profile the consumer configured, or refuses before anything uses
    /// it. There is no clamping and no default substitution: a budget the
    /// consumer could not state is a budget the kit will not invent.
    public static func configured(
        frameAgeLimitNanoseconds  : UInt64,
        captureDeadlineNanoseconds: UInt64,
        captureAttempts           : Int,
        menuInteractionNanoseconds: UInt64,
        menuCleanupNanoseconds    : UInt64
    ) throws -> ObservationProfile {

        guard frameAgeLimitNanoseconds > 0 else {
            throw ObservationProfileRefusal.frameAgeLimitNotPositive
        }
        guard captureDeadlineNanoseconds > 0 else {
            throw ObservationProfileRefusal.captureDeadlineNotPositive
        }
        guard captureAttempts > 0 else {
            throw ObservationProfileRefusal.captureAttemptsNotPositive
        }
        guard menuInteractionNanoseconds > 0 else {
            throw ObservationProfileRefusal.menuInteractionBudgetNotPositive
        }
        guard menuCleanupNanoseconds > 0 else {
            throw ObservationProfileRefusal.menuCleanupBudgetNotPositive
        }
        return ObservationProfile(
            frameAgeLimitNanoseconds  : frameAgeLimitNanoseconds,
            captureDeadlineNanoseconds: captureDeadlineNanoseconds,
            captureAttempts           : captureAttempts,
            menuInteractionNanoseconds: menuInteractionNanoseconds,
            menuCleanupNanoseconds    : menuCleanupNanoseconds
        )
    }
}
