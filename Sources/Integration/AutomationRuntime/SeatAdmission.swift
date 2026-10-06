//
//  SeatAdmission.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import SeatCore
import SeatSession

/// SeatAdmission is whether one Command may go to the seat now, and when it may not, the
/// sentence a model has to act on. Every session's act and deliver meet it before the engine.
///
/// It used to be `state == .ready` and one sentence for everything else: "Observe, then close
/// and reopen if recovery is needed." For a seat that is `.waiting` that advice is harmful.
/// Waiting is the person's choice and the only state with no deadline: it ends when the person
/// goes back to their own window, and closing the session only throws the application away. The
/// same test also refused a `.degraded` seat, which the kit says still acts.
///
/// **Admission is the state's, the gate stays the gate's.** A seat whose state accepts commands
/// is admitted whatever its last focus recovery said: a gate still held for another cause is
/// refused where input is posted, by the paths that already name that cause. Reading the pause
/// reasons here as well would put a second, earlier refusal in front of a better one.
///
/// **Only a recovery that is running is waited on.** A `.recovering` seat ends by itself, and so
/// does a `.waiting` one whose focus recovery is `restoring` or `waitingForUser`: the kit keeps
/// re-verifying on every activation and heartbeat and publishes `restored` when the readings
/// agree, which is why the broker's own focus wait treats both as an answer still coming. A seat
/// that is merely waiting, with nothing running, is answered at once.
nonisolated public enum SeatAdmission: Equatable, Sendable {

    /// The Command goes to the engine.
    case admit

    /// A recovery is running and the seat has not answered yet.
    case wait

    /// Refused, with what happened and what to do about it.
    case refuse(String)

    /// What the seat says right now, as one admission. `application` is the adopted
    /// application's name, the one the sentences speak of.
    public static func reading(
        state         : SeatState,
        recovery      : UserFocusRecoveryReport.Outcome?,
        application   : String,
        stoppedBecause: String? = nil
    ) -> SeatAdmission {
        if state.acceptsCommands { return .admit }
        switch (state, recovery) {
        case (.recovering, _),
             (.waiting, .restoring),
             (.waiting, .waitingForUser):
            return .wait
        default:
            return .refuse(refusal(for: state, application: application, stoppedBecause: stoppedBecause))
        }
    }

    /// The sentence for a seat in `state` that is not admitted, written for the model that has
    /// to decide what to do next. It says nothing about a retry policy: the tool layer appends
    /// its own "Observe before any retry." to every error.
    /// `stoppedBecause` is why a `.failed` seat stopped, `stopReason(of:)`, when it is known.
    public static func refusal(for state: SeatState, application: String, stoppedBecause: String? = nil) -> String {
        switch state {
        case .waiting:
            "The seat is waiting: \(application) took the focus in the person's own seat, so the seat "
                + "is waiting for the person to go back to their own window. Do not close the session: "
                + "that would throw \(application) away. Tell the person, then observe and try again."
        case .recovering:
            "The seat is putting the window of \(application) back where it can act on it. "
                + "Observe and try again."
        case .failed:
            if let stoppedBecause {
                "The seat stopped for good: \(stoppedBecause). Its windows were given back. Open "
                    + "\(application) again with open_session to continue; it replaces this ended session."
            } else {
                "The seat stopped for good and will not act again. Close the session and open "
                    + "\(application) again."
            }
        case .unavailable, .starting, .acting, .ready, .degraded:
            "The seat is not ready for input yet. Observe and try again."
        }
    }

    /// The admission of `seat`, waiting up to `limit` while a recovery is running, polled every
    /// 20 ms. A recovery still running at the limit is refused with its state's sentence.
    ///
    /// 2 s is the planner's own focus recovery wait: a verified restoration takes milliseconds,
    /// and a longer one is a person who has not come back, which no wait here answers.
    @MainActor
    public static func awaited(
        _ seat      : AgentSeat,
        application : String,
        within limit: Duration = .seconds(2)
    ) async -> SeatAdmission {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while true {
            let admission = reading(
                state         : seat.state,
                recovery      : seat.lastFocusRecovery?.outcome,
                application   : application,
                stoppedBecause: stopReason(of: seat)
            )
            guard admission == .wait else { return admission }
            // A cancelled wait is answered like one that ran out: nothing was sent either way.
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(20))) != nil else {
                return .refuse(refusal(for: seat.state, application: application, stoppedBecause: stopReason(of: seat)))
            }
        }
    }

    /// True when `seat` stopped for good, which ends the session holding it: a new `open` replaces it.
    @MainActor
    public static func stoppedForGood(_ seat: AgentSeat?) -> Bool {
        seat?.state == .failed
    }

    /// Why a seat that stopped for good stopped, in the words of its Issues and their causes, nil when
    /// it has not failed or kept no Issue.
    @MainActor
    public static func stopReason(of seat: AgentSeat) -> String? {
        guard seat.state == .failed else { return nil }
        // The one stop no Issue names: a window adopted on request that was neither taken in nor put back.
        guard !seat.failureIssues.isEmpty else {
            guard let failure = seat.lastAdoptionFailure, failure.restoration == .refused else { return nil }
            return untakenWindow(failure.window.windowNumber)
        }
        return stopReason(issues: seat.failureIssues, causes: seat.failureCauses)
    }

    /// The stop of a seat that could neither take a window into the seat nor put it back.
    public static func untakenWindow(_ windowNumber: Int) -> String {
        "a window the application opened could not be handled: window \(windowNumber) could not be "
            + "taken into the seat or put back where it was"
    }

    /// The stop's Issues as one clause, each with the cause found for it.
    public static func stopReason(issues: [SeatIssue], causes: [SeatIssueCause]) -> String {
        issues.map { issue in sentence(for: issue, cause: causes.first { $0.issue == issue }) }
            .joined(separator: "; ")
    }

    /// The Issue's sentence, unless the cause says more than the Issue can. A screen connected is
    /// `displayChanged` like any other, but the generic sentence reads as a fault, and this one is
    /// the person's own plug. `SeatErrorMapper` says the same words.
    public static func sentence(for issue: SeatIssue, cause: SeatIssueCause?) -> String {
        if cause == .watchdog(.physicalDisplayAdded) {
            return "a screen was connected while the seat was running, so the seat stopped and "
                + "will start again, including the new screen, the next time an application is opened"
        }
        return switch issue {
        case .keysNotReleased:         "held keys could not be released safely"
        case .displayChanged:          "the background display or the physical arrangement is no longer trustworthy"
        case .fenceUnavailable:        "the cursor fence is not active"
        case .processUnavailable:      "the target application is gone"
        case .identityChanged:         "the target's PID or window id changed"
        case .targetActivated:         "the target application became active in your seat"
        case .windowUnavailable:       "the target window is momentarily unreadable"
        case .geometryChanged:         "the target window moved or was resized"
        case .snapshotChanged:         "the accessibility and window server geometry have to be reconfirmed"
        case .cursorInterference:      "the cursor moved for a reason physical input does not explain"
        case .ambiguousEffect:         "the effect of the last input is unknown, and repeating it could duplicate an action"
        case .recoveryExhausted:       "the recovery did not succeed within its budget"
        case .monitorUnavailable:      "the preview of the background display is unavailable"
        case .windowStashed:           "the window stayed stashed: Stage Manager did not put it back on stage"
        case .preparationNotRestored:  "the target's internal AppKit state did not go back, and the events are already out"
        case .contextMenuLeftOpen:     "a contextual menu the seat opened stayed on the screen"
        }
    }
}
