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

    /// The window does not fit inside the Virtual Display and could not be made
    /// to fit: the size attribute refused the write, or the application kept the
    /// size it had. A window that is shrunk is recorded with the frame it had
    /// before, and the return writes that size back, so a window nobody could
    /// shrink is refused rather than left half moved.
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

    /// The window is in native fullscreen and the seat was not asked to handle
    /// that. The experiment is off by default and this is what the ordinary
    /// path answers, instead of writing `AXPosition` on a window that measured
    /// `settable false` and `kAXErrorFailure` for it.
    case fullScreenTransferDisabled

    /// The window is in native fullscreen and cannot leave it: `AXFullScreen`
    /// is either not readable at all or readable and refused. Measured per
    /// window, not per application. The window is left exactly where it is,
    /// and this is a **not supported** answer rather than a retry.
    case fullScreenNotSupported

    /// The window is in native fullscreen and its Space is still the one on
    /// screen. Leaving now would take the person's display to that Space and
    /// animate it back. The next pass finds the same window.
    case fullScreenSpaceStillOnScreen
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

    /// One Issue was detected. `cause` is present when the finer fact behind
    /// the Issue was established, and nil when nothing established it: the Issue
    /// set is coarse and a report needs the cause, but a guessed cause is worse
    /// than none. `SeatIssueCause` carries the argument for keeping it here
    /// rather than inside `SeatIssue`.
    case issueDetected(SeatIssue, cause: SeatIssueCause?)

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

    /// The seat found a window of the driven application and adopted it, and
    /// the operating target did **not** move. `target` is the Window ID the
    /// seat is still operating, nil when it has none.
    ///
    /// This is the only announcement of such a window, and it is how a consumer
    /// learns a window it never asked for exists at all: it is an Adopted
    /// Window like any other, it is on the Virtual Display, the release loop and
    /// the handback own it, and nothing is observed or sent on it. A consumer
    /// that wants to work in it says so with `switchTarget(to:)`, which is the
    /// only way the target moves onto it.
    ///
    /// The seat does not decide, because it cannot: the system surface that
    /// made three previous rules fail is a 66 by 20 point `AXWindow` with
    /// subrole `AXDialog` that no readable attribute separates from a dialog a
    /// person operates. `window` carries the reference it was adopted at, size
    /// included, which is what a consumer needs to tell one from the other.
    case windowAdoptedNotTargeted(window: WindowReference, target: Int?)

    /// A window of a driven application was found on a physical display and
    /// **not** brought onto the Virtual Display, with the reason.
    ///
    /// A transfer that worked arrives as `windowAdoptedNotTargeted`, never as
    /// `targetChanged`: the window is held like any other and the operating
    /// target stays where it is, whatever the selection nucleus makes of the
    /// window.
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
