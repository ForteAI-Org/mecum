//
//  ClickEvidence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import PerceptionCore

/// ClickEvidence is what one `click`, `double_click` or `right_click` proved, as values a higher
/// layer compares instead of parsing the outcome's sentence: the target it resolved, the gesture,
/// whether the gesture was delivered, and the one effect attributed to it. An input sent is not
/// evidence, and neither is a scene that changed: only an effect attributed to the target is.
///
/// Opening a menu or a window is attributable. A menu is a pop-up window that was not listed before the gesture,
/// the only new surface, opened at the target, with items the scene after it reads. A window is a
/// window of the application that was not listed before, the only new surface, and the one the scene
/// after the gesture is of: the evidence links the window the target was in to the window that
/// opened. Anything else is `unattributed`, with the reason. A double-click is one gesture of two
/// clicks and one piece of evidence. It holds no image, coordinate, or session, process or window
/// number. A source window's closure is also attributable when two complete post-delivery window
/// inventories attest its destruction with unchanged surviving windows.
public struct ClickEvidence: StepEvidence {

    /// The application's bundle identifier.
    public let bundleID: String

    /// The title of the window the target was resolved in: where the gesture started.
    public let windowTitle: String

    /// The label of the element the request resolved to.
    public let target: String

    /// The target's accessibility role when one was known.
    public let targetRole: String?

    /// The scene section holding the target when the scene named one.
    public let section: String?

    /// The panel the scene shows the target in, in braces, when it shows one. A proof decoded from
    /// before containers were kept reads nil.
    public let container: String?

    public let gesture: Gesture
    public let delivery: Delivery
    public let effect: Effect

    public init(
        bundleID   : String,
        windowTitle: String,
        target     : String,
        targetRole : String?,
        section    : String?,
        container  : String? = nil,
        gesture    : Gesture,
        delivery   : Delivery,
        effect     : Effect
    ) {
        self.bundleID    = bundleID
        self.windowTitle = windowTitle
        self.target      = target
        self.targetRole  = targetRole
        self.section     = section
        self.container   = container
        self.gesture     = gesture
        self.delivery    = delivery
        self.effect      = effect
    }

    /// Gesture is which of the four pointer gestures was asked for. Each keeps its own meaning: a
    /// right-click is never a primary click, and a double- or triple-click is never single ones.
    public enum Gesture: String, Sendable, Equatable, Hashable, Codable {
        case click
        case doubleClick = "double_click"
        case tripleClick = "triple_click"
        case rightClick  = "right_click"

        /// The gesture a verb asks for, or nil for `set_toggle`, which proves a state instead.
        public init?(_ verb: ActionVerb) {
            switch verb {
                case .click      : self = .click
                case .doubleClick: self = .doubleClick
                case .tripleClick: self = .tripleClick
                case .rightClick : self = .rightClick
                case .setToggle  : return nil
            }
        }

        public var verb: ActionVerb {
            switch self {
                case .click      : .click
                case .doubleClick: .doubleClick
                case .tripleClick: .tripleClick
                case .rightClick : .rightClick
            }
        }

        /// The clicks the one gesture sends.
        public var clickCount: Int {
            switch self {
                case .doubleClick: 2
                case .tripleClick: 3
                default          : 1
            }
        }
    }

    /// Delivery is how the gesture reached the application.
    public enum Delivery: String, Sendable, Equatable, Codable {
        /// The actuator accepted the gesture.
        case sent
        /// The control's own press action was used instead of a pointer click.
        case pressed
        /// The actuator failed; the gesture may or may not have reached the application.
        case failed
    }

    /// Surface is what an attributed effect opened.
    public enum Surface: Sendable, Equatable, Hashable, Codable {
        /// A pop-up menu at the target.
        case menu
        /// A new window with this title.
        case window(title: String)

        /// The title of an opened window; nil for a menu.
        public var window: String? {
            if case .window(let title) = self { title } else { nil }
        }

        /// The surface for a person: "a menu" or "the window 'Export'".
        public var summary: String {
            switch self {
                case .menu             : "a menu"
                case .window(let title): "the window '\(title)'"
            }
        }
    }

    /// Effect is the one effect attributed to the gesture, or why none is.
    public enum Effect: Sendable, Equatable, Codable {
        /// A new pop-up opened at the target, showing these items.
        case menuOpened(items: [String])
        /// A new window with this title opened, and the scene after the gesture is of it.
        case windowOpened(title: String)
        /// The source window disappeared from two complete inventories; other windows survived unchanged.
        case windowClosed(title: String)
        /// Nothing can be attributed to the gesture.
        case unattributed(Unattributed)

        /// Whether the effect credits the gesture with a surface.
        public var opensSurface: Bool {
            switch self {
                case .menuOpened, .windowOpened: true
                case .windowClosed, .unattributed: false
            }
        }
    }

    /// Unattributed names why no effect is attributed to the gesture.
    public enum Unattributed: String, Sendable, Equatable, Codable {
        /// The gesture was not delivered.
        case notDelivered
        /// No scene could be read afterwards.
        case noScene
        /// The scene afterwards is identical.
        case noChange
        /// Pixels changed and nothing structural did.
        case repaint
        /// Something changed in the window, but no surface opened.
        case otherChange
        /// A new pop-up opened away from the target.
        case surfaceElsewhere
        /// More than one new surface opened, so none is attributed.
        case severalSurfaces
        /// A pop-up opened at the target, but fewer than two of its items could be read.
        case unreadableSurface
        /// A new window was listed, but the scene afterwards is not of it, or it has no title.
        case otherWindow
        /// The application's windows could not be listed before or after the gesture, so no surface
        /// can be told new.
        case noCensus
        /// The listing before the gesture answered without the window the gesture was delivered in,
        /// empty included, so a window listed afterwards cannot be told new.
        case originNotListed
        /// The only new window carries the origin's title while the origin is no longer listed: the
        /// window the gesture was delivered in, re-created, not a window it opened.
        case originRecreated
        /// A pop-up opened at the target, but the capture read afterwards is of the window clicked in
        /// alone, so the items it shows are not the menu's.
        case menuNotCaptured
        /// A surface opened, but the scenes did not verify the gesture's outcome, as when another effect
        /// was expected, so the surface is not credited to it.
        case outcomeUnverified
    }

    /// The surface the gesture opened, when an effect is attributed to it.
    public var surface: Surface? {
        switch effect {
            case .menuOpened         : .menu
            case .windowOpened(let title): .window(title: title)
            case .windowClosed, .unattributed: nil
        }
    }

    /// Whether the gesture was delivered and an effect is attributed to it.
    public var closedWindow: String? {
        if case .windowClosed(let title) = effect, gesture == .click, title == windowTitle,
           title.contains(where: { !$0.isWhitespace }) { title } else { nil }
    }

    public var isVerified: Bool { delivery != .failed && (surface != nil || closedWindow != nil) }

    /// The window the gesture started in, then the window it opened, when it opened one.
    public var windowTitles: [String] { [windowTitle] + (surface?.window.map { [$0] } ?? []) }
}
