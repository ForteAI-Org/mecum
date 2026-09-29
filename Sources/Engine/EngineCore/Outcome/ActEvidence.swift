//
//  ActEvidence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

/// ActEvidence is the typed proof one outcome carries: a dropdown selection's, a toggle's, or a
/// click's, double-click's or right-click's, each a `StepEvidence`. It is what a higher layer keeps
/// as the proof of a step, so each kind of step is judged by its own readings and never by a shared
/// success flag.
///
/// Encoding: a dropdown proof encodes as the bare `DropdownEvidence` it has always been stored as,
/// so every proof recorded before toggles existed decodes as `.dropdown` unchanged. A toggle proof
/// encodes under a `toggle` key and a click proof under a `click` key, which no dropdown proof has.
public enum ActEvidence: Sendable, Equatable {

    case dropdown(DropdownEvidence)
    case toggle(ToggleEvidence)
    case click(ClickEvidence)

    public var dropdown: DropdownEvidence? {
        if case .dropdown(let evidence) = self { evidence } else { nil }
    }

    public var toggle: ToggleEvidence? {
        if case .toggle(let evidence) = self { evidence } else { nil }
    }

    public var click: ClickEvidence? {
        if case .click(let evidence) = self { evidence } else { nil }
    }

    /// The application the proof was recorded in.
    public var bundleID: String {
        switch self {
            case .dropdown(let evidence): evidence.bundleID
            case .toggle(let evidence)  : evidence.bundleID
            case .click(let evidence)   : evidence.bundleID
        }
    }

    /// The title of the window the proof was recorded in.
    public var windowTitle: String {
        switch self {
            case .dropdown(let evidence): evidence.windowTitle
            case .toggle(let evidence)  : evidence.windowTitle
            case .click(let evidence)   : evidence.windowTitle
        }
    }

    /// The titles of the windows the proof involves, whose words may name its context.
    public var windowTitles: [String] {
        switch self {
            case .dropdown(let evidence): evidence.windowTitles
            case .toggle(let evidence)  : evidence.windowTitles
            case .click(let evidence)   : evidence.windowTitles
        }
    }
}

extension ActEvidence: Codable {

    private enum CodingKeys: String, CodingKey {
        case toggle, click
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.toggle) {
            self = .toggle(try container.decode(ToggleEvidence.self, forKey: .toggle))
        } else if container.contains(.click) {
            self = .click(try container.decode(ClickEvidence.self, forKey: .click))
        } else {
            self = .dropdown(try DropdownEvidence(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
            case .dropdown(let evidence):
                try evidence.encode(to: encoder)
            case .toggle(let evidence):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(evidence, forKey: .toggle)
            case .click(let evidence):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(evidence, forKey: .click)
        }
    }
}
