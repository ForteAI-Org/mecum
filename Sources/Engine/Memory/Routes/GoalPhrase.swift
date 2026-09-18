//
//  GoalPhrase.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// GoalPhrase reads a goal the way routes and recall need it: filler words carry no goal content, so
/// "Simone chat" and "go to simone" name one goal. English and Italian navigation filler, and the
/// messaging-domain words that mean "open the conversation", are the stopwords.
public enum GoalPhrase {

    public static let stopwords: Set<String> = [
        "go", "to", "open", "the", "a", "an", "in", "on", "at", "of", "my", "and", "with",
        "vai", "apri", "su", "nel", "nella", "il", "la", "lo", "le", "da", "di", "e", "con", "al", "alla",
        "chat", "chats", "conversation", "conversazione", "message", "messages", "messaggio", "messaggi", "dm",
    ]

    /// Content tokens: lowercase runs of letters and digits, at least two characters, filler removed.
    public static func tokens(_ phrase: String) -> [String] {
        LabelText.tokens(phrase).filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// The content words joined by spaces, for scoring against another phrase.
    public static func content(_ phrase: String) -> String {
        LabelText.tokens(phrase).filter { !stopwords.contains($0) }.joined(separator: " ")
    }

    /// Whether a navigation goal is already satisfied by a window title: "go to simone" is done when
    /// the title reads "Simone (MD) ...". Every content token of three or more letters must appear in
    /// the title's letter family.
    public static func goalSatisfied(byTitle title: String, goal: String) -> Bool {
        let family = LabelText.letters(title)
        guard !family.isEmpty else { return false }
        let phrase = content(goal)
        let tokens = LabelText.tokens(phrase.isEmpty ? goal : phrase)
            .map(LabelText.letters)
            .filter { $0.count >= 3 }
        return !tokens.isEmpty && tokens.allSatisfy { family.contains($0) }
    }
}
