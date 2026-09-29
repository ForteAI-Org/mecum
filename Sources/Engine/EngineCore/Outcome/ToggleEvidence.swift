//
//  ToggleEvidence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import PerceptionCore

/// ToggleEvidence is what one `set_toggle` proved, as values a higher layer compares instead of
/// parsing the outcome's sentence: the control it resolved, the state requested, the state read
/// there before acting and where that reading came from, whether a click was sent, and the state
/// read after it and where. A success message is not evidence; only these readings are.
///
/// Every reading is attributed to the resolved control before it is compared with the requested
/// state, so an ambiguous reading is unreadable rather than favorable. It holds no image, coordinate,
/// or session, process or window number. `bundleID` is the application's own identifier; a caller
/// that only has a process fallback does not attach evidence.
public struct ToggleEvidence: StepEvidence {

    /// The application's bundle identifier.
    public let bundleID: String

    /// The title of the window the control belongs to, as the scene the request resolved in read it.
    public let windowTitle: String

    /// The label of the control the request resolved to.
    public let control: String

    /// The control's accessibility role when one was known.
    public let controlRole: String?

    /// The scene section holding the control when the scene named one.
    public let section: String?

    /// The panel the scene shows the control in, in braces, when it shows one. A proof decoded from
    /// before containers were kept reads nil.
    public let container: String?

    /// The state the caller asked for: `on` or `off`.
    public let desiredState: ControlState

    /// The control's state before acting, read on the resolved control or read again there.
    public let stateBefore: Reading

    /// Whether a click was sent to the control.
    public let click: Click

    /// The control's state after the click, or nil when no click was sent and nothing was read.
    public let stateAfter: Reading?

    public init(
        bundleID    : String,
        windowTitle : String,
        control     : String,
        controlRole : String?,
        section     : String?,
        container   : String? = nil,
        desiredState: ControlState,
        stateBefore : Reading,
        click       : Click,
        stateAfter  : Reading?
    ) {
        self.bundleID     = bundleID
        self.windowTitle  = windowTitle
        self.control      = control
        self.controlRole  = controlRole
        self.section      = section
        self.container    = container
        self.desiredState = desiredState
        self.stateBefore  = stateBefore
        self.click        = click
        self.stateAfter   = stateAfter
    }

    /// Click is whether the engine sent the one click a toggle takes.
    public enum Click: String, Sendable, Equatable, Codable {
        /// Nothing was sent: the control already read the requested state, or its state could not be
        /// read and a click would have been blind.
        case none
        /// The actuator accepted the click.
        case sent
        /// The actuator failed; the click may or may not have reached the application.
        case failed
    }

    /// Reading is a toggle state attributed to the resolved control, and which reading produced it,
    /// or why no definite state can be attributed to it.
    public enum Reading: Sendable, Equatable, Codable {

        /// A definite `on` or `off`, and its source.
        case read(ControlState, Source)

        /// No definite state could be attributed to the control.
        case unreadable(Unreadable)

        /// Source is where a reading came from.
        public enum Source: String, Sendable, Equatable, Codable {
            /// The state of the element the request resolved to, in the scene it resolved in.
            case resolvedElement
            /// The application reported the state of the control under the point of the element
            /// attributed to it.
            case accessibility
            /// The element attributed to the control in a later scene, matched by the resolved
            /// element's id, in its window and section.
            case sameElement
            /// The element attributed to the control in a later scene, matched by the resolved
            /// element's label and a state, in its window and section.
            case sameLabel
        }

        /// Unreadable names why a reading proves nothing about the control.
        public enum Unreadable: String, Sendable, Equatable, Codable {
            /// The control was found but read neither on nor off: no state, mixed, or unknown.
            case indefinite
            /// No scene could be read.
            case noScene
            /// No element with the control's id, and no stateful element with its label.
            case notFound
            /// Several elements could be the control, so none is attributed.
            case severalMatches
            /// The later scene is of another window or application.
            case otherWindow
            /// After the click, the one candidate is not at the clicked control's place, or the window
            /// changed size: it may be a homonym, so its state proves nothing about the control clicked.
            case notAtPlace
        }

        /// The reading when it is exactly `on` or `off`; any other value attributes nothing.
        public var definiteState: ControlState? {
            guard case .read(let state, _) = self, state == .on || state == .off else { return nil }
            return state
        }
    }

    /// Change is what the step did to the control's state.
    public enum Change: String, Sendable, Equatable, Codable {
        /// The control read the other definite state before, a click was sent, and it reads the
        /// requested state after.
        case changed
        /// The control already read the requested state and no click was sent. Nothing changed.
        case alreadySet
        /// Anything else: a start or an end that could not be read, a failed click, or another state.
        case unverified
    }

    /// What the step did, from the readings and the click alone.
    public var change: Change {
        guard let before = stateBefore.definiteState else { return .unverified }
        if before == desiredState, click == .none { return .alreadySet }
        guard before != desiredState, click == .sent, stateAfter?.definiteState == desiredState else {
            return .unverified
        }
        return .changed
    }

    /// Whether the control reads the requested state now: it already did, or it does after the click.
    public var isVerified: Bool { change != .unverified }
}
