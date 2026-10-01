//
//  GoalClause.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import Foundation
import PerceptionCore

/// GoalClause holds what every goal reader reads alike: the request's clauses, whole-word naming, the
/// companion clauses a single-step goal admits, and the words that make one step prove nothing about a
/// clause. `SelectionGoal` and the act goals (`ActGoal`) keep their own verbs; the rules here are the
/// ones they must not disagree on.
///
/// A step clause may hold only its verb, its own parameters, the words that name the target and the
/// section the step keeps, courtesy words, and the connectives listed here. Any other word may narrow
/// the target further than the step does, as "in Track 2" does for a step that keeps no section, so
/// the clause is `qualified` and nothing is learned or recalled from it.
enum GoalClause {

    /// The request's clauses: sentences split at `. ; : ! ?` followed by a space or the end, at line
    /// breaks and at a comma that ends a phrase, then at sequencing words. Punctuation inside a word,
    /// as in "HTML 4.01", "10:30" or "0,5", does not end a clause. Each clause is its lowercase word
    /// tokens; empty clauses are dropped.
    static func clauses(_ request: String) -> [[String]] {
        // Strip only line-leading numbered list markers, never numbers inside a control label.
        let prose = request.replacingOccurrences(of: #"(?m)^\h*[0-9]+[.)]\h+"#, with: "", options: .regularExpression)
        return sentences(splittingAtCommas(prose))
            .flatMap { sentence -> [[String]] in
                var result: [[String]] = [[]]
                for token in LabelText.tokens(sentence) {
                    if sequencing.contains(token) {
                        result.append([])
                    } else {
                        result[result.count - 1].append(token)
                    }
                }
                return result
            }
            .filter { !$0.isEmpty }
    }

    /// A qualified multiword title is one noun phrase, so the O in I/O Setup is no alternative.
    /// Match the whole title after a context introducer; never remove its individual words elsewhere.
    static func removingWindowNames(from words: [String], windows: [String]) -> [String] {
        let introducers: Set<String> = ["in", "nel", "nella", "the", "finestra", "window", "dialog", "dialogo",
                                         "chiudi", "chiudere", "close", "dismiss"]
        let titles = windows.map(LabelText.tokens).filter { $0.count > 1 }.sorted { $0.count > $1.count }
        var result: [String] = []
        var index = 0
        while index < words.count {
            if index > 0, introducers.contains(words[index - 1]), let title = titles.first(where: {
                index + $0.count <= words.count && Array(words[index ..< index + $0.count]) == $0
            }) {
                index += title.count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    /// Whether `words` appear in `clause` as one contiguous run of whole words.
    static func contains(_ clause: [String], _ words: [String]) -> Bool {
        guard !words.isEmpty, clause.count >= words.count else { return false }
        return (0...(clause.count - words.count)).contains { Array(clause[$0 ..< $0 + words.count]) == words }
    }

    /// Whether a step clause holds a negation or an alternative, which one verified step never proves.
    static func isHedged(_ words: Set<String>) -> Bool {
        isNegated(words) || !words.isDisjoint(with: alternatives)
    }

    /// Whether a clause holds a negation, an avoidance included ("evita di", "avoid").
    static func isNegated(_ words: Set<String>) -> Bool {
        !words.isDisjoint(with: negations)
    }

    /// Whether a clause's words verify, observe or report, the clauses any single-step goal admits.
    static func isAdmittedClause(_ words: Set<String>) -> Bool {
        !words.isDisjoint(with: verificationVerbs) || !words.isDisjoint(with: observationVerbs)
            || !words.isDisjoint(with: reportingVerbs)
    }

    /// A stop or guard condition: a stop verb ("fermati"), "stop" only as a condition ("stop if"), or
    /// "only if" around a generic act on the same goal. A bare "stop" may name a control, as a
    /// transport's Stop, so it is not a guard.
    static func isGuard(_ words: [String]) -> Bool {
        if !Set(words).isDisjoint(with: guardWords) { return true }
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        return pairs.contains { guardPhrases.contains($0) }
    }

    /// The words of a step clause left once the names, the courtesy words and the connectives are gone
    /// and `known` words, the step's own, are removed: empty for a clause the step explains entirely.
    /// The words of `windows`, the titles of the windows the step was proven in, are known too: they
    /// name the context the experience keeps, as in "Attiva Mute in Synthetic Mixer", not the target.
    static func unexplained(_ words: [String], known: Set<String>, windows: [String]) -> [String] {
        let context = Set(windows.flatMap(LabelText.tokens))
        return words.filter { !known.contains($0) && !connectives.contains($0) && !context.contains($0) }
    }

    /// The request with every comma that ends a phrase turned into a clause end. A comma inside a
    /// word, as in "0,5", is kept.
    private static func splittingAtCommas(_ request: String) -> String {
        let characters = Array(request)
        return String(characters.enumerated().map { index, character in
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            return character == "," && (next?.isWhitespace ?? true) ? ";" : character
        })
    }

    private static func sentences(_ request: String) -> [String] {
        let enders: Set<Character> = [".", ";", ":", "!", "?"]
        var sentences: [String] = []
        var current = ""
        let characters = Array(request)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character.isNewline || (enders.contains(character) && (next == nil || next?.isWhitespace == true)) {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        sentences.append(current)
        return sentences
    }

    // MARK: Vocabulary

    /// Every action verb the goal readers know, each kind's own included: a reader removes its own
    /// verbs to find the actions that make its goal compound.
    static let actionVerbs: Set<String> = SelectionGoal.otherActionVerbs.union(SelectionGoal.selectionVerbs)

    /// Words that make a step clause mean something other than one step on one target.
    static let negations: Set<String> = [
        "non", "not", "no", "don", "dont", "never", "mai", "senza", "without", "né", "nor", "neither",
        "evita", "evitare", "evitate", "avoid", "avoiding",
    ]

    /// Words that offer a choice or widen the target beyond one control.
    static let alternatives: Set<String> = [
        "o", "oppure", "or", "either", "altrimenti", "otherwise", "anche", "also", "both", "entrambi",
        "tutti", "tutte", "all",
    ]

    /// Courtesy words a clause may hold besides its verb, such as "Per favore, attiva Mute".
    static let fillers: Set<String> = ["per", "favore", "please", "grazie", "thanks"]

    /// Articles, prepositions, and generic control and section nouns, which join a verb to its target
    /// and section without naming anything themselves. The nouns are the interface's own, in any
    /// application; a noun of one application's domain, as a track, a layer or a channel, is a word the
    /// step does not represent.
    static let connectives: Set<String> = [
        "il", "lo", "la", "l", "i", "gli", "le", "un", "uno", "una", "di", "del", "dello", "della", "dei",
        "delle", "su", "sul", "sullo", "sulla", "in", "nel", "nello", "nella", "a", "al", "allo", "alla",
        "the", "an", "of", "to", "at", "into",
        "controllo", "pulsante", "bottone", "casella", "interruttore", "opzione", "voce", "icona",
        "control", "button", "checkbox", "option", "item", "icon",
        "sezione", "pannello", "scheda", "riquadro", "section", "panel", "tab", "pane",
    ]

    private static let sequencing: Set<String> = [
        "e", "ed", "poi", "quindi", "dopo", "infine", "and", "then", "after", "afterwards", "next",
    ]

    private static let verificationVerbs: Set<String> = [
        "verifica", "verificare", "controlla", "controllare", "conferma", "confermare", "assicurati",
        "verify", "check", "confirm", "ensure",
    ]

    private static let observationVerbs: Set<String> = [
        "osserva", "osservare", "guarda", "guardare", "leggi", "leggere", "esamina",
        "observe", "look", "read", "inspect",
    ]

    private static let reportingVerbs: Set<String> = [
        "dimmi", "dire", "spiega", "spiegami", "mostrami", "tell", "explain",
    ]

    private static let guardWords: Set<String> = [
        "fermati", "fermarti", "fermatevi", "unless",
    ]

    /// Two-word guards. A generic act ("agisci", "procedi") is admitted only inside one of these.
    private static let guardPhrases: Set<String> = [
        "solo se", "soltanto se", "only if", "non procedere", "stop if", "stop unless", "stop when",
    ]
}
