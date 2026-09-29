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
/// split as `GoalClause` splits it, at sentence punctuation, at a comma that ends a phrase and at
/// sequencing words, and every clause must be understood.
///
/// Admitted clause kinds, besides the one selection: verifying the result, observing, reporting
/// to the user, a stop or guard condition ("fermati se...", "agisci solo se..."), and courtesy
/// words alone ("Per favore,"). A clause with any other action verb makes the goal compound, and
/// a clause with no recognized verb makes it uncertain; neither is admitted, because one verified
/// `select` cannot prove either. A selection clause with a negation or an alternative is `hedged`,
/// and so is any clause that names the item under a negation, whatever its verb ("Non toccare
/// Output Busses"); a clause with a second selection verb asks for several selections. A negation
/// in another clause, as in "verifica che non cambi altro", is that clause's. Every clause is read:
/// one the reader cannot parse never hides a later one that shows another step. The item and
/// control names are removed before verbs are read, so an item called "Open" is not a verb and one
/// called "No Output" is not a negation.
///
/// In the selection clause, the item must appear as whole words, so "Track 10" does not name
/// "Track 1", and each time it appears, apart from inside the control's own name, it must be the
/// value reached, not a longer one or the one left:
/// - the word on each side of it is a verb, an article, a preposition, a generic control noun or
///   the clause's end, otherwise the item is `qualified`: "Output Busses 2" and "Stereo Output
///   Busses" do not name "Output Busses";
/// - it is not introduced by an origin ("da", "dal", "from") or a replacement ("invece di", "invece
///   che", "al posto delle", "piuttosto di", "anziché", "instead of", "rather than"), with at most
///   articles, prepositions and "valore" between ("from the Output Busses", "invece del valore Output
///   Busses"), and a change or setting verb does not send it on to another value ("Cambia Output
///   Busses in All Busses", "Cambia Output Busses con il valore All Busses"), otherwise it is the
///   origin, `itemIsOrigin`;
/// - a replacement whose direction cannot be read is not a selection of the item: a replacement
///   word without the preposition that says which value is left ("Seleziona invece Output Busses")
///   is `unexplained`, and an item after a replacement with other words between is `uncertain`.
/// Every other word of the selection clause must be one the step or its proof represents: the
/// item's, the control's, the words of the window the step was proven in, a selection verb, an
/// article, a preposition, courtesy, or a dropdown noun. Any other word may narrow the request
/// beyond the step, as "di Track 2", "della scheda Bus" or "in Pro Tools" do for a step that keeps
/// no section or application name, so the request is `unexplained` and nothing is learned or
/// recalled operationally for it. The vocabulary is Italian and English and deliberately small: an
/// unknown verb, and any unknown word in the selection clause, fail closed.
public enum SelectionGoal {

    /// Classification is the verdict for one request.
    public enum Classification: Sendable, Equatable {
        /// One selection clause naming the item, with only admitted clauses beside it.
        case single
        /// A clause asks for another action; the clause text is attached.
        case compound(String)
        /// A clause could not be understood, and no clause shows another step; the text of the first
        /// such clause is attached.
        case uncertain(String)
        /// The selection clause negates the selection or offers an alternative, or a clause names the
        /// item under a negation; the clause text is attached.
        case hedged(String)
        /// No clause asks for a selection.
        case noSelection
        /// More than one clause, or one clause with more than one selection verb, asks for a selection.
        case severalSelections
        /// The selection clause does not name the requested item.
        case itemNotNamed
        /// The selection clause names the item with a word beside it that the item does not hold, as
        /// "Output Busses 2" for "Output Busses"; the words are attached.
        case qualified(String)
        /// The selection clause names the item as the value to change from; the clause text is attached.
        case itemIsOrigin(String)
        /// The selection clause holds words the step does not represent, such as a section or an
        /// application name; the words are attached.
        case unexplained(String)

        /// Whether the request is shown to ask for something the step does not do: another action,
        /// several selections, a negated or alternative one, another item, a longer name, or this
        /// item as the value left. Recall never offers the step's memory for such a request,
        /// whatever words it shares with the remembered phrase. An uncertain request, one with no
        /// selection, or one with words the step does not represent, shows no such difference, but
        /// it is not the step's single goal either.
        public var asksForAnotherStep: Bool {
            switch self {
                case .single, .uncertain, .noSelection, .unexplained                  : false
                case .compound, .hedged, .severalSelections, .itemNotNamed, .qualified,
                     .itemIsOrigin                                                    : true
            }
        }
    }

    /// Classifies `request` as a goal for selecting `item` in the control labelled `control`. `shown` is
    /// the value the proof read on the control before the menu opened, which a person may name it by as
    /// well as by its label; a control read in pixels shows its value as its label. `windows` are the
    /// titles of the windows the step was proven in, whose words may name its context.
    public static func classify(
        _ request: String,
        item     : String,
        control  : String,
        shown    : String? = nil,
        windows  : [String] = []
    ) -> Classification {
        let itemWords = LabelText.tokens(item)
        let controlNames = [LabelText.tokens(control)] + (shown.map { [LabelText.tokens($0)] } ?? [])
        let names = Set(itemWords + controlNames.flatMap { $0 })
        var selections: [[String]] = []
        var unclear: String?
        for clause in GoalClause.clauses(request) {
            let text = clause.joined(separator: " ")
            let words = clause.filter { !names.contains($0) }
            let content = words.filter { !GoalClause.fillers.contains($0) }
            // Courtesy alone, as "Per favore," before the selection, is no goal of its own.
            if content.isEmpty, !words.isEmpty { continue }
            switch kind(of: content) {
                case .selection     : selections.append(clause)
                case .repeated      : return .severalSelections
                case .hedged        : return .hedged(text)
                case .admitted      : continue
                case .otherAction   : return .compound(text)
                case .unrecognized:
                    // A clause that names the item under a negation refuses it, whatever its verb.
                    if GoalClause.contains(clause, itemWords), GoalClause.isNegated(Set(content)) { return .hedged(text) }
                    if unclear == nil { unclear = text }
            }
        }
        guard selections.count <= 1 else { return .severalSelections }
        guard let selection = selections.first else { return unclear.map(Classification.uncertain) ?? .noSelection }
        let reading = naming(in: selection, item: itemWords, controls: controlNames, windows: windows)
        guard reading == .single else { return reading }
        return unclear.map(Classification.uncertain) ?? .single
    }

    // MARK: The item

    /// How the selection clause names the item: every place it appears outside one of the control's own
    /// names must name it whole, as the value to reach, and every other word must be represented.
    private static func naming(
        in clause: [String],
        item     : [String],
        controls : [[String]],
        windows  : [String]
    ) -> Classification {
        let itemSpans = spans(of: item, in: clause)
        let controlSpans = controls.flatMap { spans(of: $0, in: clause) }
        // An item inside the control's longer name is the control's, and a control inside the item's the item's.
        func within(_ inner: Range<Int>, _ outer: Range<Int>) -> Bool {
            inner != outer && outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
        }
        let items = itemSpans.filter { span in !controlSpans.contains { within(span, $0) } }
        let controls = controlSpans.filter { span in !itemSpans.contains { within(span, $0) } }
        guard !items.isEmpty else { return .itemNotNamed }
        let text = clause.joined(separator: " ")
        let changes = !Set(clause).isDisjoint(with: changeVerbs)
        let replacements = replacementSpans(in: clause)
        let context = Set(windows.flatMap(LabelText.tokens))
        /// The index of the first word from `index` on that is not an article or a preposition.
        func nextContent(from index: Int) -> Int? {
            (index ..< clause.count).first { !GoalClause.connectives.contains(clause[$0]) }
        }
        /// Whether the words that introduce a value, ending at `end`, introduce the item at `start`: only
        /// articles, prepositions and value nouns stand between.
        func introduces(_ end: Int, _ start: Int) -> Bool {
            end <= start && (end ..< start).allSatisfy {
                GoalClause.connectives.contains(clause[$0]) || valueNouns.contains(clause[$0])
            }
        }
        let origins = clause.indices.filter { originWords.contains(clause[$0]) }.map { $0 ..< $0 + 1 }
        for span in items {
            let before = span.lowerBound > 0 ? clause[span.lowerBound - 1] : nil
            let after = span.upperBound < clause.count ? clause[span.upperBound] : nil
            if (origins + replacements).contains(where: { introduces($0.upperBound, span.lowerBound) }) {
                return .itemIsOrigin(text)
            }
            // Other words between a replacement and the item: which value it leaves cannot be read.
            if replacements.contains(where: { $0.upperBound <= span.lowerBound }) { return .uncertain(text) }
            let replaces = replacements.contains { $0.lowerBound == span.upperBound }
            if changes, !replaces, let after, destinationWords.contains(after) || changeLinks.contains(after),
               let next = nextContent(from: span.upperBound + 1) {
                // "Cambia X in <control>" and "Set X to Mix" send X on; "Set X in the filter" does not, and
                // "Cambia X con il valore Y" names a value, not a place.
                let isPlace = placeNouns.contains(clause[next]) || context.contains(clause[next])
                if !isPlace { return .itemIsOrigin(text) }
            }
            let qualifiers = [before, after].compactMap { $0 }.filter { !isBoundary($0) }
            if !qualifiers.isEmpty { return .qualified(qualifiers.joined(separator: " ")) }
        }
        let named = Set((items + controls + replacements).flatMap { Array($0) })
        // A replacement word outside a whole replacement says a value is left without saying which.
        let unexplained = clause.indices.filter { index in
            let word = clause[index]
            return !named.contains(index) && (!isBoundary(word) || replacementMarks.contains(word))
                && !context.contains(word)
        }
        guard unexplained.isEmpty else { return .unexplained(unexplained.map { clause[$0] }.joined(separator: " ")) }
        return .single
    }

    /// The ranges of the words that introduce a replaced value: a replacement head and the preposition
    /// or conjunction after it, as "invece di", "al posto delle" and "instead of", or "anziché" alone.
    private static func replacementSpans(in clause: [String]) -> [Range<Int>] {
        replacementHeads.flatMap { head in
            spans(of: head, in: clause).compactMap { span -> Range<Int>? in
                if span.upperBound < clause.count, replacementLinks.contains(clause[span.upperBound]) {
                    return span.lowerBound ..< span.upperBound + 1
                }
                return head.allSatisfy(standaloneReplacements.contains) ? span : nil
            }
        }
    }

    /// The ranges where `words` appear in `clause` as one contiguous run.
    private static func spans(of words: [String], in clause: [String]) -> [Range<Int>] {
        guard !words.isEmpty, clause.count >= words.count else { return [] }
        return (0...(clause.count - words.count))
            .filter { Array(clause[$0 ..< $0 + words.count]) == words }
            .map { $0 ..< $0 + words.count }
    }

    /// Whether a word beside the item joins it to the clause rather than extending its name.
    private static func isBoundary(_ word: String) -> Bool {
        selectionVerbs.contains(word) || GoalClause.connectives.contains(word) || GoalClause.fillers.contains(word)
            || originWords.contains(word) || destinationWords.contains(word) || selectionWords.contains(word)
            || replacementMarks.contains(word) || replacementLinks.contains(word)
    }

    // MARK: Clauses

    private enum ClauseKind {
        case selection, repeated, hedged, admitted, otherAction, unrecognized
    }

    private static func kind(of words: [String]) -> ClauseKind {
        let set = Set(words)
        if !set.isDisjoint(with: otherActionVerbs) { return .otherAction }
        if GoalClause.isGuard(words) { return .admitted }
        let selecting = words.filter(selectionVerbs.contains)
        if !selecting.isEmpty {
            if selecting.count > 1 { return .repeated }
            return GoalClause.isHedged(set) ? .hedged : .selection
        }
        if GoalClause.isAdmittedClause(set) { return .admitted }
        return .unrecognized
    }

    // MARK: Vocabulary

    /// The verbs that ask for a selection.
    static let selectionVerbs: Set<String> = [
        "seleziona", "selezionare", "scegli", "scegliere", "imposta", "impostare", "cambia", "cambiare",
        "metti", "mettere", "select", "choose", "pick", "set", "change", "switch",
    ]

    /// Words a change verb may send its item on with, besides the destination prepositions: "Cambia
    /// X con Y", "Switch X for Y".
    private static let changeLinks: Set<String> = ["con", "with", "for"]

    /// The heads of the phrases that introduce the value a selection replaces, each completed by one of
    /// `replacementLinks`: the item after the phrase is the one left.
    private static let replacementHeads: [[String]] = [
        ["invece"], ["al", "posto"], ["piuttosto"], ["anziché"], ["anziche"], ["instead"], ["rather"],
        ["in", "place"],
    ]

    /// The prepositions, alone or joined to an article, and the conjunctions that complete a replacement head.
    private static let replacementLinks: Set<String> = [
        "di", "del", "dello", "della", "dell", "dei", "degli", "delle", "che", "of", "than",
    ]

    /// Replacement heads that are whole without a link: "anziché Output Busses".
    private static let standaloneReplacements: Set<String> = ["anziché", "anziche"]

    /// The word of each head that makes it a replacement.
    private static let replacementMarks: Set<String> = [
        "invece", "posto", "piuttosto", "anziché", "anziche", "instead", "rather", "place",
    ]

    /// Selection verbs that name a change or a setting, whose "X in Y", "X su Y" or "X to Y" sends X to Y.
    private static let changeVerbs: Set<String> = [
        "cambia", "cambiare", "imposta", "impostare", "metti", "mettere", "change", "switch", "set",
    ]

    /// Words that introduce the value a change leaves.
    private static let originWords: Set<String> = [
        "da", "dal", "dallo", "dalla", "dall", "dai", "dagli", "dalle", "from",
    ]

    /// Words that introduce the value a change reaches, or the place of a selection.
    private static let destinationWords: Set<String> = ["a", "al", "in", "su", "sul", "to", "into", "on"]

    /// The dropdown's nouns that name a place, where a selection is made.
    private static let placeNouns: Set<String> = [
        "dropdown", "menu", "menù", "filtro", "elenco", "lista", "campo", "popup", "finestra", "window",
        "filter", "list", "field",
    ]

    /// The nouns that name a value, which may stand between an origin and the item: "from the value X".
    private static let valueNouns: Set<String> = ["valore", "value"]

    /// Other words that may stand beside the item without naming it: the dropdown's own nouns,
    /// "come", conditions and the preposition of a place.
    private static let selectionWords: Set<String> = placeNouns.union(valueNouns).union([
        "come", "as", "per", "for", "con", "with", "se", "if", "che", "that", "quando", "when",
    ])

    /// The action verbs that are not a selection's, each of which makes a selection goal compound.
    static let otherActionVerbs: Set<String> = [
        "esporta", "salva", "apri", "chiudi", "premi", "clicca", "attiva", "disattiva", "abilita",
        "disabilita", "rinomina", "elimina", "cancella", "crea", "aggiungi", "rimuovi", "sposta", "copia",
        "incolla", "digita", "scrivi", "invia", "stampa", "riproduci", "registra", "trascina", "scorri",
        "export", "save", "open", "close", "press", "click", "enable", "disable", "toggle", "rename",
        "delete", "remove", "create", "add", "move", "copy", "paste", "type", "write", "send", "print",
        "play", "record", "drag", "scroll",
    ]
}
