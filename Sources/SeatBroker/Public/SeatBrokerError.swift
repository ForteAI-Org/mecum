import Foundation

public enum SeatBrokerError: LocalizedError {
    case windowNotAttested(windowNumber: Int)
    case noObservation
    case elementOutOfRange(index: Int, count: Int)
    case frameUnavailable
    case sessionClosed
    /// The session is open and the seat is holding nothing: the application it
    /// was using has gone back to the person and the next one is not adopted
    /// yet.
    case noAdoptedApplication
    case capabilityMissing(String)
    /// A Seat error, already turned into one sentence by `SeatErrorMapper`.
    case driver(String)

    /// The application a planner asked to open names none of the installed
    /// ones, or several of them. Its own case because it is the one open
    /// failure the run carries on from: nothing was launched, nothing was
    /// released, and the seat still holds what it held, so the next decision
    /// is taken with this sentence in the history.
    case applicationNotResolved(String)

    /// The seat refused to observe because its situation was moving: the
    /// selection changed while the capture was in flight, or a surface is not
    /// settled yet. Nothing is wrong and nothing was posted; the next reading
    /// is taken of whatever the world settled into.
    case observationSuspended(String)

    /// Input was not admitted because the person's focus is being restored.
    /// It is its own case because it is the one driver refusal that can end by
    /// itself: nothing was posted, and the seat reopens the gate when the
    /// focused user window is verified. The caller decides again; nothing here
    /// replays a Command.
    case inputPaused(String)

    /// An application was launched, or found running, and showed no window
    /// within the wait. Its own case because the reason is often the
    /// application waiting to be brought to the front, which the seat never
    /// does. `wasLaunched` says whether this call started it: nothing quits it.
    case noWindowShown(application: String, seconds: Int64, wasLaunched: Bool)

    public var errorDescription: String? {
        switch self {
        case .windowNotAttested(let n): "Window \(n) could not be attested by the window server."
        case .noObservation: "Observe the scene before executing an action."
        case .elementOutOfRange(let i, let c): "Element \(i) does not exist; the scene has \(c) elements."
        case .frameUnavailable: "No frame could be captured from the adopted window."
        case .sessionClosed: "The session is closed."
        case .noAdoptedApplication: "No application is adopted; open one before observing or acting."
        case .capabilityMissing(let d): "Missing capability: \(d)"
        case .driver(let sentence): sentence
        case .applicationNotResolved(let sentence): sentence
        case .inputPaused(let sentence): sentence
        case .observationSuspended(let sentence): sentence
        case .noWindowShown(let application, let seconds, _):
            "\(application) launched but showed no window within \(seconds) s."
        }
    }
}
