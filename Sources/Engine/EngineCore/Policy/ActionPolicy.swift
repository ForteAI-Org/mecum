//
//  ActionPolicy.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// ActionPolicy is the safety rule a model cannot argue with: a target whose label reads as
/// destructive or irreversible is refused unless the person opted in. Over-matching is the safe
/// direction, so the terms are stems and the match is a substring, in every language a driven app
/// has spoken so far. An English-only list once let "Elimina", "Invia" and "Esci" through.
public enum ActionPolicy {

    static let destructiveTerms: [String] = [
        // English
        "delete", "remove", "trash", "discard", "erase", "reset", "format", "uninstall", "purge", "wipe",
        "destroy", "overwrite", "replace all", "quit", "sign out", "log out", "logout", "deactivate",
        "revoke", "send", "publish", "submit", "buy", "purchase", "pay", "confirm order",
        // Italian, as stems
        "elimin", "cancell", "rimuov", "cestin", "ripristin", "azzera", "svuot", "sovrascriv",
        "esci", "disconnett", "invia", "pubblic", "acquist", "compra", "paga",
    ]

    /// True when the label names something destructive or irreversible. Conservative: when unsure, refuse.
    public static func isDestructive(label: String?) -> Bool {
        guard let lowered = label?.lowercased() else { return false }
        return destructiveTerms.contains { lowered.contains($0) }
    }

    /// True for Command with Q or W, whatever else is held: they quit or close what the agent is
    /// driving, so they are refused even when the person allowed destructive actions.
    public static func closesTheTarget(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.contains(.command), case .character(let character) = chord.key else { return false }
        return ["q", "w"].contains(character.lowercased())
    }

    /// The roles whose press opens a menu the panel service of a remote file panel owns.
    public static let menuOpeningRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]

    /// Why a click on such a control in a remote file panel was refused, in the seat's own words:
    /// `RemoteContentActuationRefusal.opensMenu` says the same, and a test holds the two together.
    public static func menuOpeningRefusal(role: String) -> String {
        "That \(role) opens a menu a click here cannot follow, so it was not pressed. "
            + "Use select with this control and the item, or context_menu."
    }

    /// True for Command with Delete, whatever else is held: it moves to the Trash, deletes a message
    /// or empties the Trash in the applications that bind it.
    public static func isDestructive(_ chord: KeyChord) -> Bool {
        chord.modifiers.contains(.command) && chord.key == .delete
    }
}

/// ActionPermissions is what the person, and only the person, has allowed. A model never sets it.
public struct ActionPermissions: Sendable, Equatable, Codable {

    /// Destructive targets are refused by default; the person flips this to let the agent delete or send.
    public var allowsDestructive: Bool

    /// A contextual menu may be opened only on a text field. Set for a Qt application on the seat: a
    /// custom widget there draws its menu under the person's own pointer, outside the seat, where it
    /// cannot be read, moved or closed, and the seat stays suspended until the person closes it. A text
    /// field's menu opens where the click landed, and it is the only way to reach Copy and Paste.
    public var contextMenusOnTextFieldsOnly: Bool

    /// A field's text is selected with a triple click and no key. Set while the seat holds a file
    /// panel the system draws out of process: measured on 30/09/2026 in Photoshop's Save As panel,
    /// Command and Up went to the enclosing folder, the other selecting keys did nothing, and replacing
    /// the name typed into its middle, while a triple click selected all of it.
    public var selectsFieldsByTripleClick: Bool

    /// A click on a popup or a menu button is refused and nothing presses it. Set while the seat
    /// holds a file panel the system draws out of process: pressed, it opens a menu window the panel
    /// service owns, outside the scene, which stays open (05/10/2026); `select` chooses in it.
    public var refusesMenuOpeningClicks: Bool

    public init(
        allowsDestructive           : Bool = false,
        contextMenusOnTextFieldsOnly: Bool = false,
        selectsFieldsByTripleClick  : Bool = false,
        refusesMenuOpeningClicks    : Bool = false
    ) {
        self.allowsDestructive            = allowsDestructive
        self.contextMenusOnTextFieldsOnly = contextMenusOnTextFieldsOnly
        self.selectsFieldsByTripleClick   = selectsFieldsByTripleClick
        self.refusesMenuOpeningClicks     = refusesMenuOpeningClicks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsDestructive            = try container.decode(Bool.self, forKey: .allowsDestructive)
        contextMenusOnTextFieldsOnly = try container.decodeIfPresent(Bool.self, forKey: .contextMenusOnTextFieldsOnly)
            ?? false
        selectsFieldsByTripleClick   = try container.decodeIfPresent(Bool.self, forKey: .selectsFieldsByTripleClick)
            ?? false
        refusesMenuOpeningClicks     = try container.decodeIfPresent(Bool.self, forKey: .refusesMenuOpeningClicks)
            ?? false
    }
}
