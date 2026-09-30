//
//  SeatAdmission.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

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
        state      : SeatState,
        recovery   : UserFocusRecoveryReport.Outcome?,
        application: String
    ) -> SeatAdmission {
        if state.acceptsCommands { return .admit }
        switch (state, recovery) {
        case (.recovering, _),
             (.waiting, .restoring),
             (.waiting, .waitingForUser):
            return .wait
        default:
            return .refuse(refusal(for: state, application: application))
        }
    }

    /// The sentence for a seat in `state` that is not admitted, written for the model that has
    /// to decide what to do next. It says nothing about a retry policy: the tool layer appends
    /// its own "Observe before any retry." to every error.
    public static func refusal(for state: SeatState, application: String) -> String {
        switch state {
        case .waiting:
            "The seat is waiting: \(application) took the focus in the person's own seat, so the seat "
                + "is waiting for the person to go back to their own window. Do not close the session: "
                + "that would throw \(application) away. Tell the person, then observe and try again."
        case .recovering:
            "The seat is putting the window of \(application) back where it can act on it. "
                + "Observe and try again."
        case .failed:
            "The seat stopped for good and will not act again. Close the session and open "
                + "\(application) again."
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
                state      : seat.state,
                recovery   : seat.lastFocusRecovery?.outcome,
                application: application
            )
            guard admission == .wait else { return admission }
            // A cancelled wait is answered like one that ran out: nothing was sent either way.
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(20))) != nil else {
                return .refuse(refusal(for: seat.state, application: application))
            }
        }
    }
}
