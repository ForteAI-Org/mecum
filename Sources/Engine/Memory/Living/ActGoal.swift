//
//  ActGoal.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import PerceptionCore

/// ActGoal decides whether a user's request asks for exactly one act of one kind on one target, the
/// only act goal the living memory may learn from or recall for. The rule is the same for every kind
/// of act; what a clause asks for is read by the kind's `ActGoalVocabulary`.
///
/// Each clause is read with the target's and the section's words and the courtesy words removed, so
/// a control called "On Air" is not a state and one called "Open" is not a verb. A clause of another
/// action makes the goal compound; a clause with no recognized verb makes it uncertain. The one act
/// clause must name the target, and the section when one is given, as whole words, so "Unmute" does
/// not name "Mute" and "Track 10" does not name "Track 1". Any other word in it, beyond the kind's
/// own and `GoalClause`'s connectives, may narrow the target further than the step does, as "in
/// Track 2" for a step that keeps no section, and makes it `qualified`.
public enum ActGoal {

    /// Classification is the verdict for one request, where `Ask` is what the act clause asks for.
    public enum Classification<Ask: Sendable & Equatable>: Sendable, Equatable {
        /// One act clause naming the target and asking for this, with only admitted clauses beside it.
        case single(Ask)
        /// A clause asks for another action; the clause text is attached.
        case compound(String)
        /// A clause could not be understood, or what it asks is unclear; the clause text is attached.
        case uncertain(String)
        /// No clause asks for an act of this kind.
        case noStep
        /// More than one clause asks for an act of this kind.
        case severalSteps
        /// The act clause does not name the target.
        case targetNotNamed
        /// A section was given and the act clause does not name it.
        case sectionNotNamed
        /// The act clause holds words the step does not keep, such as a section it was not narrowed
        /// to; the words are attached.
        case qualified(String)
    }

    /// Clause is what one clause's words, the names and courtesy words removed, ask for.
    enum Clause<Ask> {
        /// An act of the vocabulary's kind, asking for this.
        case act(Ask)
        /// A companion clause: verifying, observing, reporting, a stop or guard condition, or nothing.
        case admitted
        /// Another action.
        case otherAction
        /// Nothing the vocabulary reads.
        case unrecognized
    }

    /// Classifies `request` as a goal for an act of `Vocabulary`'s kind on the element labelled
    /// `target`, in `section` when the goal must name one: the section the call or the remembered step
    /// narrowed it to. `windows` are the titles of the windows the step involves, whose words may name
    /// the context.
    static func classify<Vocabulary: ActGoalVocabulary>(
        _ request: String,
        as _     : Vocabulary.Type,
        target   : String,
        section  : String?,
        windows  : [String]
    ) -> Classification<Vocabulary.Ask> {
        let targetWords = LabelText.tokens(target)
        let sectionWords = LabelText.tokens(section ?? "")
        let names = Set(targetWords + sectionWords)
        var acts: [(clause: [String], words: [String], ask: Vocabulary.Ask)] = []
        for clause in GoalClause.clauses(request) {
            let words = clause.filter { !names.contains($0) && !GoalClause.fillers.contains($0) }
            switch Vocabulary.read(words) {
                case .act(let ask) : acts.append((clause, words, ask))
                case .admitted     : continue
                case .otherAction  : return .compound(clause.joined(separator: " "))
                case .unrecognized : return .uncertain(clause.joined(separator: " "))
            }
        }
        guard let act = acts.first else { return .noStep }
        guard acts.count == 1 else { return .severalSteps }
        guard GoalClause.contains(act.clause, targetWords) else { return .targetNotNamed }
        guard sectionWords.isEmpty || GoalClause.contains(act.clause, sectionWords) else { return .sectionNotNamed }
        let unexplained = GoalClause.unexplained(act.words, known: Vocabulary.actWords, windows: windows)
        guard unexplained.isEmpty else { return .qualified(unexplained.joined(separator: " ")) }
        return .single(act.ask)
    }
}
