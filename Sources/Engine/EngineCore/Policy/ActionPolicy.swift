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
}

/// ActionPermissions is what the person, and only the person, has allowed. A model never sets it.
public struct ActionPermissions: Sendable, Equatable, Codable {

    /// Destructive targets are refused by default; the person flips this to let the agent delete or send.
    public var allowsDestructive: Bool

    public init(allowsDestructive: Bool = false) {
        self.allowsDestructive = allowsDestructive
    }
}
