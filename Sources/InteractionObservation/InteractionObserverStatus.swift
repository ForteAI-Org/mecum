import InteractionListener

/// InteractionObserverStatus lets hosts present readiness without parsing CLI diagnostic text.
public enum InteractionObserverStatus: Sendable {
    case ready(window: InteractionWindow, elements: Int)
    case perceptionUnavailable(String)
}
