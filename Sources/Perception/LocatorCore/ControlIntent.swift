import Foundation

/// What KIND of control a recorded element is — drives idempotent actuation. Stateful kinds
/// (toggle/checkbox/radio) must be set to a DESIRED state, not blindly clicked.
public enum ControlKind: String, Codable, Sendable { case button, toggle, checkbox, radio, menu }

/// The on/off state of a stateful control. `unknown` = couldn't be read (→ never guess-click).
public enum ToggleState: String, Codable, Sendable { case on, off, unknown }

/// What actuation should do given the live state of a control.
public enum ActuationAction: String, Equatable, Sendable {
    case click   // perform the click/press
    case noop    // already in the desired state — do nothing (idempotent success)
    case skip    // state unreadable on a stateful control — do NOT guess-click (honest skip)
}

/// The recorded INTENT for actuating an element: its kind, and (for a stateful control) the state to LEAVE
/// it in. Lets replay be idempotent — "ensure TikTok is ON" sets the toggle to on whether or not it was
/// already, instead of re-clicking the spot and flipping an already-on toggle the wrong way. Optional on a
/// `Descriptor` (legacy / plain-click elements have none).
public struct ControlIntent: Codable, Equatable, Sendable {
    public var kind: ControlKind
    /// The state to leave a stateful control in = the state AFTER the recorded action (post-click for a
    /// mark-and-click, current for a mark-only). `unknown` ⇒ no idempotent target → plain click.
    public var desiredState: ToggleState

    public init(kind: ControlKind, desiredState: ToggleState = .unknown) {
        self.kind = kind
        self.desiredState = desiredState
    }

    public var isStateful: Bool { kind == .toggle || kind == .checkbox || kind == .radio }

    /// Idempotent actuation decision from the LIVE current state. For a stateful control: click only if the
    /// live state DIFFERS from the desired end-state; NO-OP if it already matches; SKIP if the live state
    /// can't be read (a blind flip of a stateful control is 50% exactly-wrong, undoable damage). A
    /// non-stateful control, or one with no desired target, just clicks. Pure → unit-tested.
    public func action(givenCurrent current: ToggleState?) -> ActuationAction {
        guard isStateful, desiredState != .unknown else { return .click }
        guard let current, current != .unknown else { return .skip }
        return current == desiredState ? .noop : .click
    }
}
