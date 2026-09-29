//
//  ActOutcome.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import PerceptionCore

/// ActOutcomeKind is the closed vocabulary an action answers with. A model's next move depends on
/// which one it is, so each names a distinct situation and none is a synonym for another.
public enum ActOutcomeKind: String, Sendable, Codable, CaseIterable {
    /// The target was found and a structural change was observed after acting.
    case foundActed = "found_acted"
    /// The gesture went out but no change could be attributed to it. Re-perceive, do not retry blind.
    case actedUnverified = "acted_unverified"
    /// Nothing was done on purpose, and the message says what to do instead.
    case actedNoop = "acted_noop"
    /// Several elements carry the target's name; the caller must add a section or an id.
    case ambiguous
    /// No such target on this screen.
    case honestMiss = "honest_miss"
    /// The action is not allowed here: a destructive target, a disabled row.
    case refused
    /// A dry run: what would have happened.
    case dryRun = "dry_run"
}

/// ActOutcome is one action's answer: its kind, a sentence a person can act on, and the scene after
/// acting when one was taken, so the caller never pays a second perception to see what happened.
/// It also carries at most one typed proof: a dropdown selection its `DropdownEvidence`, a
/// `set_toggle` its `ToggleEvidence`, and a delivered click, double-click or right-click its
/// `ClickEvidence`. The sentence is for people only.
public struct ActOutcome: Sendable, Equatable {

    public let kind: ActOutcomeKind
    public let message: String
    public let scene: SceneSnapshot?

    /// The outcome's typed proof, or nil when the action proved nothing structured: another action, a
    /// selection that never chose an item, a toggle that never resolved its control, a dry run, or a
    /// gesture that never went out.
    public let evidence: ActEvidence?

    public init(
        _ kind   : ActOutcomeKind,
        _ message: String,
        scene    : SceneSnapshot? = nil,
        evidence : ActEvidence? = nil
    ) {
        self.kind     = kind
        self.message  = message
        self.scene    = scene
        self.evidence = evidence
    }

    /// The proof of a dropdown selection, or nil for any other proof.
    public var dropdown: DropdownEvidence? { evidence?.dropdown }

    /// The proof of a `set_toggle`, or nil for any other proof.
    public var toggle: ToggleEvidence? { evidence?.toggle }

    /// The proof of a click, double-click or right-click, or nil for any other proof.
    public var click: ClickEvidence? { evidence?.click }

    /// True for the one outcome that claims success. Everything else asks the caller to look again.
    public var isSuccess: Bool { kind == .foundActed }

    /// The dropdown evidence when the outcome claims success and its readback shows the requested
    /// item. A `found_acted` without evidence proves nothing structured and answers nil.
    public var verifiedDropdown: DropdownEvidence? {
        guard isSuccess, let dropdown, dropdown.isVerified else { return nil }
        return dropdown
    }

    /// The answer to a selection whose item was chosen and whose menu closed: `found_acted` when
    /// the readback shows the item, `acted_unverified` otherwise, always with the evidence. The
    /// menu's window number appears in the sentence only; it is not evidence.
    public static func dropdownSelection(
        _ evidence      : DropdownEvidence,
        menuWindowNumber: Int,
        scene           : SceneSnapshot
    ) -> ActOutcome {
        let item = evidence.requestedItem
        let message = evidence.isVerified
            ? "selected '\(item)' in menu window #\(menuWindowNumber); the dropdown now reads '\(item)'"
            : "requested '\(item)' in menu window #\(menuWindowNumber), but the dropdown value was not verified"
        return ActOutcome(evidence.isVerified ? .foundActed : .actedUnverified, message, scene: scene,
                          evidence: .dropdown(evidence))
    }
}
