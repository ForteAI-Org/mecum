import Foundation

/// The non-overridable safety policy for LLM-driven actuation. The LLM cannot pass a "force" flag past
/// this — destructive targets are refused regardless of what it asks, and only a small set of verbs is
/// allowed unattended. Anything outside this is the human's job.
public enum ActionPolicy {
    /// Verbs Locator will perform unattended. Everything else → refused (needs a human / a later phase).
    public static let safeVerbs: Set<String> = ["click", "set_toggle", "double_click", "right_click"]

    /// Label substrings that mark a DESTRUCTIVE / irreversible target. Even inside a "safe" verb, clicking a
    /// button whose label matches these is refused (unless the user opted into destructive actions) —
    /// undoable damage must stay a deliberate choice. MULTILINGUAL: an English-only list let "Elimina"
    /// (Italian delete), "Invia" (send), "Esci" (quit) sail straight through in a non-English UI (measured
    /// on Ron's Italian Slack). Stems (substring match) catch inflections; over-matching is the SAFE
    /// direction here. Add languages as target apps demand.
    static let destructiveTerms: [String] = [
        // English
        "delete", "remove", "trash", "discard", "erase", "reset", "format", "uninstall", "purge", "wipe",
        "destroy", "overwrite", "replace all", "quit", "sign out", "log out", "logout", "deactivate",
        "revoke", "send", "publish", "submit", "buy", "purchase", "pay", "confirm order",
        // Italian (stems: "elimin" → elimina/eliminare, "rimuov" → rimuovi/rimuovere, …)
        "elimin", "cancell", "rimuov", "cestin", "ripristin", "azzera", "svuot", "sovrascriv",
        "esci", "disconnett", "invia", "pubblic", "acquist", "compra", "paga",
    ]

    /// Is this target label destructive/irreversible? Conservative substring match — when unsure, refuse.
    public static func isDestructive(label: String?) -> Bool {
        guard let l = label?.lowercased() else { return false }
        return destructiveTerms.contains { l.contains($0) }
    }
}
