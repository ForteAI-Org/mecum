/// ListenerFailure distinguishes startup permission failures from a tap that stopped delivering input.
/// Queue pressure is not a failure: it degrades into counted coalescing and in-band gap events.
public enum ListenerFailure: Error, Sendable, CustomStringConvertible {
    case inputMonitoringDenied
    case tapUnavailable
    case tapDisabled
    case consumerTooSlow

    public var description: String {
        switch self {
        case .inputMonitoringDenied:
            "Input Monitoring is unavailable. Allow the launching app or terminal in System Settings > Privacy & Security > Input Monitoring, then relaunch it."
        case .tapUnavailable:
            "The passive event tap could not start. Check Input Monitoring and Accessibility for the launching process."
        case .consumerTooSlow:
            "The observer could not keep up with input. Watching stopped to keep memory bounded; restart it when input settles."
        case .tapDisabled:
            "macOS disabled the event tap. The listener stopped because continuity cannot be guaranteed; restart it."
        }
    }
}
