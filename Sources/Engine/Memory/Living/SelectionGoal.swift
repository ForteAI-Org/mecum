//
//  SelectionGoal.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import PerceptionCore

/// SelectionGoal decides whether a user's request asks for exactly one dropdown selection, the
/// only goal the first milestone may learn from. It reads clauses, not keywords: a request is
/// split at sentence punctuation and at sequencing words, and every clause must be understood.
///
/// Admitted clause kinds, besides the one selection: verifying the result, observing, reporting
/// to the user, and a stop or guard condition ("fermati se...", "agisci solo se..."). A clause
/// with any other action verb makes the goal compound, and a clause with no recognized verb makes
/// it uncertain; neither is admitted, because one verified `select` cannot prove either. The item
/// and control names are removed before verbs are read, so an item called "Open" is not a verb.
/// The vocabulary is Italian and English and deliberately small: an unknown verb fails closed.
public enum SelectionGoal {

    /// Classification is the verdict for one request.
    public enum Classification: Sendable, Equatable {
        /// One selection clause naming the item, with only admitted clauses beside it.
        case single
        /// A clause asks for another action; the clause text is attached.
        case compound(String)
        /// A clause could not be understood; the clause text is attached.
        case uncertain(String)
        /// No clause asks for a selection.
        case noSelection
        /// More than one clause asks for a selection.
        case severalSelections
        /// The selection clause does not name the requested item.
        case itemNotNamed
    }

    /// Classifies `request` as a goal for selecting `item` in the control labelled `control`.
    public static func classify(_ request: String, item: String, control: String) -> Classification {
        let names = Set(LabelText.tokens(item) + LabelText.tokens(control))
        var selections: [[String]] = []
        for clause in clauses(request) {
            let words = clause.filter { !names.contains($0) }
            switch kind(of: words) {
                case .selection     : selections.append(clause)
                case .admitted      : continue
                case .otherAction   : return .compound(clause.joined(separator: " "))
                case .unrecognized  : return .uncertain(clause.joined(separator: " "))
            }
        }
        guard let selection = selections.first else { return .noSelection }
        guard selections.count == 1 else { return .severalSelections }
        let wanted = LabelText.normalize(item)
        guard !wanted.isEmpty, selection.joined().contains(wanted) else { return .itemNotNamed }
        return .single
    }

    // MARK: Clauses

    private enum ClauseKind {
        case selection, admitted, otherAction, unrecognized
    }

    /// Sentences split at `. ; : ! ?` followed by a space or the end, and at line breaks, then at
    /// sequencing words. Punctuation inside a word, as in "HTML 4.01" or "10:30", does not end a
    /// sentence. Each clause is its lowercase word tokens; empty clauses are dropped.
    static func clauses(_ request: String) -> [[String]] {
        sentences(request)
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

    private static func kind(of words: [String]) -> ClauseKind {
        let set = Set(words)
        if !set.isDisjoint(with: otherActionVerbs) { return .otherAction }
        if isGuard(words) { return .admitted }
        if !set.isDisjoint(with: selectionVerbs) { return .selection }
        if !set.isDisjoint(with: verificationVerbs) || !set.isDisjoint(with: observationVerbs)
            || !set.isDisjoint(with: reportingVerbs) { return .admitted }
        return .unrecognized
    }

    /// A stop or guard condition: a stop verb, or "only if" around a generic act on the same goal.
    private static func isGuard(_ words: [String]) -> Bool {
        if !Set(words).isDisjoint(with: guardWords) { return true }
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        return pairs.contains { guardPhrases.contains($0) }
    }

    // MARK: Vocabulary

    private static let sequencing: Set<String> = [
        "e", "ed", "poi", "quindi", "dopo", "infine", "and", "then", "after", "afterwards", "next",
    ]

    private static let selectionVerbs: Set<String> = [
        "seleziona", "selezionare", "scegli", "scegliere", "imposta", "impostare", "cambia", "cambiare",
        "metti", "mettere", "select", "choose", "pick", "set", "change", "switch",
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
        "fermati", "fermarti", "fermatevi", "stop", "unless",
    ]

    /// Two-word guards. A generic act ("agisci", "procedi") is admitted only inside one of these.
    private static let guardPhrases: Set<String> = [
        "solo se", "soltanto se", "only if", "non procedere",
    ]

    private static let otherActionVerbs: Set<String> = [
        "esporta", "salva", "apri", "chiudi", "premi", "clicca", "attiva", "disattiva", "abilita",
        "disabilita", "rinomina", "elimina", "cancella", "crea", "aggiungi", "rimuovi", "sposta", "copia",
        "incolla", "digita", "scrivi", "invia", "stampa", "riproduci", "registra", "trascina", "scorri",
        "export", "save", "open", "close", "press", "click", "enable", "disable", "toggle", "rename",
        "delete", "remove", "create", "add", "move", "copy", "paste", "type", "write", "send", "print",
        "play", "record", "drag", "scroll",
    ]
}
