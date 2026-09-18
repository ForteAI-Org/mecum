//
//  SceneEffect.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// SceneEffect is what one input event did to a window, named from the scenes before and after it.
///
/// Its `encoded` form is the stable string memory accumulates evidence under: sorted, deduplicated,
/// count-free, so the same action produces the same string across observations. Its `family` is
/// what an expectation is compared against: a flip's direction or a menu's items may vary, the
/// kind of effect should not.
public enum SceneEffect: Sendable, Equatable, Hashable {

    /// The window title's letter family changed: a navigation.
    case windowTitleChanged(title: String)
    /// The target control's state flipped.
    case stateFlip(from: ControlState, to: ControlState)
    /// A cluster of new stable labels appeared close together.
    case menuOpened(labels: [String])
    /// New stable labels appeared, scattered.
    case elementsAppeared(labels: [String])
    /// A cluster of stable labels vanished.
    case elementsDisappeared(labels: [String])

    /// The effect family: `stateFlip`, `menuOpened`, `elementsAppeared`, `elementsDisappeared`,
    /// `windowTitleChanged`.
    public var family: String {
        switch self {
            case .windowTitleChanged : "windowTitleChanged"
            case .stateFlip          : "stateFlip"
            case .menuOpened         : "menuOpened"
            case .elementsAppeared   : "elementsAppeared"
            case .elementsDisappeared: "elementsDisappeared"
        }
    }

    /// The stable evidence string: `family:payload`.
    public var encoded: String {
        switch self {
            case .windowTitleChanged(let title)      : "windowTitleChanged:\(title)"
            case .stateFlip(let from, let to)        : "stateFlip:\(from.rawValue)>\(to.rawValue)"
            case .menuOpened(let labels)             : "menuOpened:\(labels.joined(separator: "|"))"
            case .elementsAppeared(let labels)       : "elementsAppeared:\(labels.joined(separator: "|"))"
            case .elementsDisappeared(let labels)    : "elementsDisappeared:\(labels.joined(separator: "|"))"
        }
    }

    /// A compact human rendering for annotations and reports.
    public var summary: String {
        switch self {
            case .stateFlip:
                return "toggles"
            case .menuOpened(let labels):
                return "opens menu(\(labels.prefix(3).joined(separator: "|"))\(labels.count > 3 ? "…" : ""))"
            case .elementsAppeared:
                return "reveals elements"
            case .elementsDisappeared:
                return "closes elements"
            case .windowTitleChanged(let title):
                return "navigates to \(title)"
        }
    }

    /// Decodes an evidence string produced by `encoded`, or nil for an unknown family or payload.
    public init?(encoded: String) {
        guard let colon = encoded.firstIndex(of: ":") else { return nil }
        let family = String(encoded[..<colon])
        let payload = String(encoded[encoded.index(after: colon)...])
        let labels = payload.isEmpty ? [] : payload.split(separator: "|").map(String.init)
        switch family {
            case "windowTitleChanged":
                self = .windowTitleChanged(title: payload)
            case "stateFlip":
                let parts = payload.split(separator: ">").map(String.init)
                guard parts.count == 2, let from = ControlState(rawValue: parts[0]),
                      let to = ControlState(rawValue: parts[1]) else { return nil }
                self = .stateFlip(from: from, to: to)
            case "menuOpened"         : self = .menuOpened(labels: labels)
            case "elementsAppeared"   : self = .elementsAppeared(labels: labels)
            case "elementsDisappeared": self = .elementsDisappeared(labels: labels)
            default                   : return nil
        }
    }
}
