/// ListenerFailure distinguishes startup permission failures from a stream that lost input.
public enum ListenerFailure: Error, Sendable, CustomStringConvertible {
    case inputMonitoringDenied
    case tapUnavailable
    case bufferOverflow
    case tapDisabled

    public var description: String {
        switch self {
        case .inputMonitoringDenied:
            "Input Monitoring is unavailable. Allow the launching terminal in System Settings > Privacy & Security > Input Monitoring, then relaunch it."
        case .tapUnavailable:
            "The passive event tap could not start. Check Input Monitoring and Accessibility for the launching process."
        case .bufferOverflow:
            "The listener stopped because its 128-event buffer filled. Some input was lost; restart the listener."
        case .tapDisabled:
            "macOS disabled the event tap. The listener stopped because continuity cannot be guaranteed; restart it."
        }
    }
}
