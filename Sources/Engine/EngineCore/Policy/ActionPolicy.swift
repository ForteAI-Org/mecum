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

    /// Checks command components, excluding the top-level menu category. A bar item
    /// such as Format is navigation; destructive submenus such as Delete still count.
    public static func isDestructive(menuPath: [String]) -> Bool {
        menuPath.dropFirst().contains { isDestructive(label: $0) }
    }

    /// True for Command with Q or W, whatever else is held: they quit or close what the agent is
    /// driving, so they are refused even when the person allowed destructive actions.
    public static func closesTheTarget(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.contains(.command), case .character(let character) = chord.key else { return false }
        return ["q", "w"].contains(character.lowercased())
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

    public init(allowsDestructive: Bool = false, contextMenusOnTextFieldsOnly: Bool = false) {
        self.allowsDestructive            = allowsDestructive
        self.contextMenusOnTextFieldsOnly = contextMenusOnTextFieldsOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsDestructive            = try container.decode(Bool.self, forKey: .allowsDestructive)
        contextMenusOnTextFieldsOnly = try container.decodeIfPresent(Bool.self, forKey: .contextMenusOnTextFieldsOnly)
            ?? false
    }
}
