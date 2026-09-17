//
//  SeatEvent.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CursorGuard
import SeatCapture
import SeatCore
import VirtualScreens

/// SeatTransitionReason is why a state changed, as a value. It is here and not
/// as a string because a consumer branches on it: "the caller asked" and "an
/// Issue happened" produce different reports and different next moves.
nonisolated public enum SeatTransitionReason: Sendable, Equatable {

    /// The caller asked: `start`, `stop`, `adopt`, `release`.
    case requested

    /// One or more Issues were detected, in detection order.
    case issues([SeatIssue])

    /// A recoverable episode closed and the window is back where it belongs.
    case recovered

    /// The target application went back to the background, which is the only
    /// way out of `waiting` other than cancellation.
    case targetWentInactive

    /// The work was cancelled.
    case cancelled
}

/// SeatTargetChange is why the seat's operating target moved, as a value: a
/// consumer answers a change it asked for and one it was handed differently.
nonisolated public enum SeatTargetChange: String, Sendable, Equatable {

    /// `switchTarget(to:)` asked for it.
    case requested

    /// A window was adopted and became the target.
    case adopted

    /// A window of a driven application appeared on a physical display, was
    /// recognised by the seat itself and brought onto the Virtual Display. The
    /// consumer did not ask for it, which is the whole reason it is a case of
    /// its own: nothing on the consumer's side was expecting this target.
    case detected

    /// The target was destroyed and the most recent earlier one took over.
    case predecessor
}

/// WindowTransferRefusal is why a window of a driven application was left where
/// it was. Each case is an outcome and not a failure to report: a window that
/// cannot be moved with the primitive this kit has is a fact about the window,
/// and a seat that stayed silent about it would read as a seat that never saw
/// it.
nonisolated public enum WindowTransferRefusal: String, Sendable, Equatable {

    /// No accessibility element answers for this Window ID, so `AXPosition`
    /// has nothing to write. An external popup drawn by a process that publishes
    /// no window element is the ordinary case, and the kit adds no primitive to
    /// reach it.
    case notMovable

    /// The window does not fit inside the Virtual Display. Nothing is resized:
    /// a window shrunk to fit is a window the person gets back smaller than
    /// they left it.
    case tooLarge

    /// The move, or one of the two readings that confirm it, was refused. The
    /// window was put back where it was found, and `lastAdoptionFailure`
    /// carries the whole record including the rollback.
    case moveRefused

    /// The seat has spent its attempts on this Window ID. An application that
    /// puts its own window back on the physical display after every move is an
    /// application that disagrees, and this is where the disagreement stops
    /// instead of becoming a loop.
    case attemptsExhausted
}

/// WindowReleaseOutcome is what happened to an Adopted Window when the seat let
/// it go. A window that vanished is not a failure: the person may have closed
/// it, and closing is not the kit's business.
nonisolated public enum WindowReleaseOutcome: String, Sendable, Equatable {

    /// Back at its original frame in the User Seat.
    case returned

    /// Left on the virtual display, as asked.
    case leftOnVirtualDisplay

    /// The window is gone. Reported, not an error.
    case vanished

    /// The move back was refused. On a fail-closed teardown this is the field
    /// that names which windows did not make it home.
    case refused
}

/// TeardownReport is the whole outcome of taking a seat host down, as fields.
/// Assembled instead from prose scattered over a hundred lines, the same report
/// cannot be asserted on; here the facts come out of the kit and the sentences
/// stay with whoever shows them to a person.
nonisolated public struct TeardownReport: Sendable, Equatable {

    /// True when the virtual display's id is no longer in the online list.
    public let displayRemoved: Bool

    /// True when the fence's tap was released and is no longer active.
    public let fenceReleased: Bool

    /// True when the main display is the one the host started with.
    public let mainDisplayRestored: Bool

    /// What was done about the physical origins.
    ///
    /// `topologyChangedByUser` is not a failure, and it is the case a plain
    /// "restore refused" cannot tell apart: the person plugged or unplugged a
    /// display during the session, so the arrangement is theirs and the kit
    /// writes nothing.
    /// `nil` means the restore itself was refused by CoreGraphics.
    public let topologyRestoration: TopologyRestoration?

    /// Every window the host let go, with what happened to it.
    public let windows: [Int: WindowReleaseOutcome]

    /// How long the removal took, from releasing the private object to the id
    /// being absent from the online list.
    public let removalNanoseconds: UInt64

    public init(
        displayRemoved     : Bool,
        fenceReleased      : Bool,
        mainDisplayRestored: Bool,
        topologyRestoration: TopologyRestoration?,
        windows            : [Int: WindowReleaseOutcome],
        removalNanoseconds : UInt64
    ) {
        self.displayRemoved      = displayRemoved
        self.fenceReleased       = fenceReleased
        self.mainDisplayRestored = mainDisplayRestored
        self.topologyRestoration = topologyRestoration
        self.windows             = windows
        self.removalNanoseconds  = removalNanoseconds
    }

    /// The windows that did not make it back to the User Seat, which is the
    /// one line of a teardown report a person has to read.
    public var windowsNotReturned: [Int] {
        windows.filter { $0.value == .refused }.keys.sorted()
    }
}

/// SeatEvent is the single channel out of the session layer. There is no
/// delegate and there is no second mechanism: state transitions with their
/// reason, Issues as they are detected, recovery progress, the fence's latched
/// batch, the Monitor's quality changes and the teardown's outcome all arrive
/// here, and `state` is the same information as a property for a consumer that
/// only wants to look.
///
/// The stream is single consumer. An `AsyncStream` has one continuation, so two
/// iterators would split the events between them rather than each seeing all of
/// them; a consumer that needs to fan out does it on its own side.
nonisolated public enum SeatEvent: Sendable, Equatable {

    /// The host moved. `reason` says why.
    case hostStateChanged(from: SeatHostState, to: SeatHostState, reason: SeatTransitionReason)

    /// The seat moved.
    case seatStateChanged(from: SeatState, to: SeatState, reason: SeatTransitionReason)

    /// One Issue was detected. `cause` is present when the watchdog found it,
    /// and names which of the eight invariants broke: the Issue set is coarse
    /// (three values for eight causes) and a report needs the cause.
    case issueDetected(SeatIssue, cause: WatchdogViolation?)

    /// What the fence's tap latched since the last drain, published on every
    /// heartbeat that finds something. This is the consumer of the fence's
    /// `drainSignals()`, and it is how an escape the fence
    /// already corrected becomes visible at all: polling the cursor afterwards
    /// finds it back inside.
    case fenceSignals(FenceSignals)

    /// One step of a recovery episode.
    case recoveryProgressed(episode: Int, step: RecoveryStep)

    /// Focus restoration, including refusals and measured verification latency.
    case userFocusRecoveryChanged(UserFocusRecoveryReport)

    /// The Monitor's quality policy dropped a level, with the reason. The policy
    /// hands the same change back to whoever supplies the CPU reading; this is
    /// how everyone else hears about it, and the share it was judged against
    /// comes from the watchdog's heartbeat.
    case monitorQualityChanged(MonitorQualityChange)

    /// The seat's operating target moved to another Adopted Window, which is
    /// on stage and confirmed there. `to` is the reference as it reads **after**
    /// the transfer, and the consumer observes again before sending any
    /// coordinate: nothing computed against the previous target survives this.
    case targetChanged(from: Int?, to: WindowReference, reason: SeatTargetChange)

    /// A requested target change did not happen and the target is unchanged.
    /// `issues` is empty when the refusal was about the seat's state rather
    /// than about the window.
    case targetChangeRefused(windowNumber: Int, state: SeatState, issues: [SeatIssue])

    /// A window of a driven application was found on a physical display and
    /// **not** brought onto the Virtual Display, with the reason. A successful
    /// transfer arrives as `targetChanged` with reason `.detected` instead.
    case windowTransferRefused(
        windowNumber: Int,
        processID   : Int32,
        reason      : WindowTransferRefusal
    )

    /// A window was let go.
    case windowReleased(windowNumber: Int, outcome: WindowReleaseOutcome)

    /// The host came down, with the whole outcome.
    case teardownFinished(TeardownReport)
}
