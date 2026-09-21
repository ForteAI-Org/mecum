import Foundation

/// One command discovered by READ-ONLY enumeration of the app's menu bar (AXMenuBar → AXMenuBarItem →
/// AXMenu → AXMenuItem, recursive). Pure metadata — recording a command NEVER executes it. `path` is the
/// human menu path (["Setup", "Playback Engine…"]); `topLevelTitle` lets a reach re-find the top menu even
/// if its index shifts. Marks/shortcuts are captured read-only for context.
public struct MenuCommand: Codable, Equatable, Sendable {
    public var path: [String]
    public var topLevelTitle: String
    public var identifier: String?
    public var hasSubmenu: Bool
    public var enabled: Bool
    public var markChar: String?        // checkmark/state glyph if any (read-only)
    public var cmdChar: String?         // keyboard-shortcut key if any
    public var firstSeen: Date
    public var lastSeen: Date

    public init(path: [String], topLevelTitle: String, identifier: String? = nil, hasSubmenu: Bool = false,
                enabled: Bool = true, markChar: String? = nil, cmdChar: String? = nil,
                firstSeen: Date, lastSeen: Date) {
        self.path = path; self.topLevelTitle = topLevelTitle; self.identifier = identifier
        self.hasSubmenu = hasSubmenu; self.enabled = enabled; self.markChar = markChar; self.cmdChar = cmdChar
        self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    public var leaf: String { path.last ?? "" }
    /// Stable merge key: the FULL menu path. (NOT the AX identifier — apps like Pro Tools reuse one
    /// identifier across hundreds of items, which would collapse distinct commands into one.)
    public var key: String { path.joined(separator: "/") }
    /// Digit-sensitive match: the better of the leaf name and the full menu path, so a query naming the
    /// parent ("New Track" → "Track > New…") outranks a same-leaf command elsewhere ("File > New…").
    public func matchScore(query: String) -> Double {
        max(KnowledgeText.matchScore(query: query, against: leaf),
            KnowledgeText.matchScore(query: query, against: path.joined(separator: " ")))
    }
}

public extension AppKnowledge {
    /// Merge a fresh read-only menu enumeration: known commands (by `key`) refresh their fields + lastSeen;
    /// new ones are appended. Deterministic order by path.
    mutating func observeMenus(_ incoming: [MenuCommand], now: Date) {
        var byKey = Dictionary(menuCommands.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for var cmd in incoming {
            if let existing = byKey[cmd.key] {
                cmd.firstSeen = existing.firstSeen
            }
            cmd.lastSeen = now
            byKey[cmd.key] = cmd
        }
        menuCommands = byKey.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    /// Best matching EXECUTABLE menu command for a query, or nil. Two hard rules (measured on Premiere,
    /// query "export"): (1) submenu PARENTS are never returned — pressing one just flashes the menu open
    /// while reporting success ("File > Export" beat every real command on exact-leaf score); (2) the
    /// winner must be CLEAR — with parents skipped, eight "File > Export > …" children tie at 2.0, and
    /// auto-picking "AAF…" would be a confident wrong action. Same unique-accept rule as the relocator:
    /// runner-up within 0.5 → refuse to guess (nil), let the caller fall back or ask.
    func bestMenuCommand(for query: String, minScore: Double = 2) -> MenuCommand? {
        guard let top = topMenuMatch(for: query, minScore: minScore) else { return nil }
        // THE COVERAGE GATE (rule 3), paid for in a live session: "Option + Click Solo" — a MODIFIER
        // GESTURE naming no command — executed Options > Click and silently armed Pro Tools' metronome.
        // The mechanism: KnowledgeText.matchScore awards 2.0 whenever the COMMAND's tokens all appear in
        // the query (tt ⊆ qt) — so any query CONTAINING a one-word leaf ("click", "new", "open") clears
        // the accept threshold, however little of the query it explains. Executing demands the reverse:
        // the winner's own words must explain MOST of the query. Below the bar the resolution is worth
        // SAYING (menuSuggestion feeds the miss message) but never worth RUNNING.
        let qt = Set(KnowledgeText.tokens(query))
        let ct = Set(KnowledgeText.tokens(top.leaf)).union(KnowledgeText.tokens(top.path.joined(separator: " ")))
        guard !qt.isEmpty else { return nil }
        let coverage = Double(qt.intersection(ct).count) / Double(qt.count)
        // ≥ half the query explained. Not higher: the tokenizer drops ≤2-char tokens ("I/O" → nothing),
        // so "open io setup" → Setup > I/O… legitimately scores 0.5. The metronome case scores 0.33.
        return coverage >= 0.5 ? top : nil
    }

    /// The raw unique winner, WITHOUT the coverage gate — for a "did you mean …?" in a miss message,
    /// where naming a near-match helps and running it would be the metronome bug again.
    func menuSuggestion(for query: String) -> MenuCommand? {
        topMenuMatch(for: query, minScore: 1.0)
    }

    private func topMenuMatch(for query: String, minScore: Double) -> MenuCommand? {
        var scored: [(cmd: MenuCommand, score: Double)] = []
        for cmd in menuCommands where !cmd.hasSubmenu {
            let s = cmd.matchScore(query: query)
            if s >= minScore { scored.append((cmd, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.cmd.path.count < b.cmd.path.count }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].score > top.score - 0.5 { return nil }
        return top.cmd
    }
}

/// Words that mark a menu item / control as MUTATING or destructive. The auto-explorer must never actively
/// traverse or press anything whose title/identifier contains one — the backstop behind the absolute
/// "never press a leaf item" rule. Token-matched (word-boundary), so "Saved Search" doesn't match "save".
public enum DestructiveDenylist {
    public static let words: Set<String> = [
        "bounce", "commit", "render", "freeze", "flatten", "consolidate", "delete", "clear", "remove",
        "destroy", "erase", "trim", "crop", "overwrite", "replace", "save", "export", "import", "print",
        "send", "share", "upload", "publish", "purchase", "buy", "quit", "reset", "restore", "revert",
        "discard", "empty", "duplicate", "merge", "mixdown", "record", "arm", "punch", "normalize",
        "gain", "reverse", "audiosuite", "process", "automation", "deactivate", "disable", "enable",
    ]
    public static func matches(_ title: String?, _ identifier: String? = nil) -> Bool {
        let toks = Set(KnowledgeText.tokens([title, identifier].compactMap { $0 }.joined(separator: " ")))
        return !toks.isDisjoint(with: words)
    }
}
