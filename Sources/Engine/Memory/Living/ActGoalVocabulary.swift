//
//  ActGoalVocabulary.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

/// ActGoalVocabulary reads one kind of act in a request's clause, for `ActGoal`: which clause asks for
/// the act and what it asks, and which words the act's clause may hold. A conformer is a closed,
/// deliberately small vocabulary, Italian and English: an unknown verb fails closed.
protocol ActGoalVocabulary {

    /// Ask is what one act clause asks for, such as the state a toggle must reach.
    associatedtype Ask: Sendable & Equatable

    /// What a clause asks for, from its words with the target's and the section's words and the
    /// courtesy words removed.
    static func read(_ words: [String]) -> ActGoal.Clause<Ask>

    /// Every word an act clause may hold besides the names and `GoalClause`'s connectives.
    static var actWords: Set<String> { get }
}
