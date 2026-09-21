import Foundation

/// Recognising a FILE OPEN/SAVE PANEL from the scene alone — and the one sentence that tells an agent
/// what to do with it.
///
/// Why this exists: the engine already has everything needed to drive a file dialog in ONE call
/// (`go_to_folder` sends ⌘⇧G, types the path, and for a file presses the panel's default button), and a
/// model still spent thirteen rounds clicking a column browser, because the SCENE never said what kind
/// of window it was looking at. A tool description read once at startup loses to the scene in front of
/// the model. So the situation announces its own verb.
///
/// Deliberately conservative: a panel counts only when it carries BOTH buttons every file dialog has
/// (a Cancel and a confirm) AND one independent corroborating signal — a standard-places sidebar entry,
/// or a panel-shaped window title. The blast radius of a false positive is one advisory sentence, never
/// an action, which is what justifies matching truncated OCR labels ("Applicatio…") at all.
public enum FileDialog {
    /// What made this look like a file dialog. `confirm` is the panel's own button label, so the hint can
    /// name the real word ("Import", "Choose") instead of guessing "Open".
    public struct Signals: Equatable, Sendable {
        public let confirm: String
        public let corroboration: String
        public init(confirm: String, corroboration: String) {
            self.confirm = confirm; self.corroboration = corroboration
        }
    }

    /// The button that commits a file panel. Multi-word entries are real: Pro Tools' import panels.
    static let confirmWords: Set<String> = [
        "open", "save", "import", "choose", "select", "export", "apri", "salva", "importa", "scegli",
        "import media", "import session data", "save as", "salva con nome",
    ]

    /// Sidebar standard places. English + Italian, because Ron drives in both.
    static let standardPlaces: [String] = [
        "desktop", "documents", "downloads", "applications", "recents", "icloud drive", "home",
        "movies", "music", "pictures", "library", "network", "airdrop", "shared",
        "scrivania", "documenti", "applicazioni", "immagini", "filmati", "musica", "recenti",
    ]

    /// Window titles macOS and app panels use. A panel titled "Open" is about as clear as evidence gets.
    static let panelTitles: Set<String> = [
        "open", "save", "save as", "import", "export", "choose", "select",
        "apri", "salva", "salva con nome", "importa", "esporta", "scegli",
    ]

    /// Lowercased, trimmed, with the ellipsis and trailing dots of a TRUNCATED label removed —
    /// "Applicatio…" and "Applicatio..." both become "applicatio", which prefix-matches "applications".
    static func norm(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("…") || t.hasSuffix(".") || t.hasSuffix(" ") {
            t = String(t.dropLast())
        }
        return t
    }

    /// A standard place, tolerating truncation — but never on a stub: a 4-character floor keeps "do"
    /// or "li" from matching "documents"/"library".
    static func isStandardPlace(_ label: String) -> Bool {
        let n = norm(label)
        guard n.count >= 4 else { return false }
        return standardPlaces.contains { $0 == n || $0.hasPrefix(n) }
    }

    /// Is this scene a file open/save panel? Returns the signals that say so, or nil.
    public static func detect(_ scene: SceneSnapshot) -> Signals? {
        let labels = scene.elements.map(\.label)
        guard labels.contains(where: { norm($0) == "cancel" || norm($0) == "annulla" }) else { return nil }
        guard let confirm = labels.first(where: { confirmWords.contains(norm($0)) }) else { return nil }
        // Corroboration: the window's own title, else a standard place in the sidebar.
        if panelTitles.contains(norm(scene.windowTitle)) {
            return Signals(confirm: confirm, corroboration: "the window is titled “\(scene.windowTitle)”")
        }
        if let place = labels.first(where: isStandardPlace) {
            return Signals(confirm: confirm, corroboration: "a standard-places sidebar (“\(place)”)")
        }
        return nil
    }

    /// The line `describe_scene` LEADS with. Names the path-typing verb, the shell-shaped reader, and the
    /// fact that browsing the columns by eye is the slow road — the three things the failing session
    /// needed and was never told.
    public static func orientation(_ s: Signals) -> String {
        "▲ THIS IS A FILE DIALOG (\(s.corroboration)) — do NOT browse the sidebar or columns by eye. "
            + "go_to_folder(path:\"~/…\") types the path straight in (⌘⇧G): a FOLDER navigates there, and a "
            + "FILE is selected AND confirmed for you — one call, no separate '\(s.confirm)' click. "
            + "Don't know the path yet? list_files(path:) reads a folder without touching the UI, and "
            + "make_folder(path:) creates one."
    }

    /// The shorter form appended to a MISS or an unverified action, where the agent has just spent a
    /// round clicking inside a panel.
    public static func missHint(_ s: Signals) -> String {
        "▲ you are in a FILE DIALOG: clicking through its sidebar/columns is the slow road and often "
            + "does not register — go_to_folder(path:\"~/…\") jumps there and confirms in ONE call, and "
            + "list_files(path:) tells you what a folder holds without clicking."
    }
}
