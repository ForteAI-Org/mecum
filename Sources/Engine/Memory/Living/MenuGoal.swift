/// MenuGoal recognizes one request to open the named window, using the shared conservative clause rules.
/// Other actions, negation and unmodeled qualifiers prevent admission. A native path is not a click.
enum MenuGoal: ActGoalVocabulary {
    typealias Ask = Bool
    static let openWords: Set<String> = ["apri", "aprire", "open", "opens"]
    static let actWords = openWords.union(["finestra", "window", "dialog", "dialogo"])

    static func read(_ words: [String]) -> ActGoal.Clause<Bool> {
        let set = Set(words)
        if !set.isDisjoint(with: GoalClause.actionVerbs.subtracting(openWords)) { return .otherAction }
        if GoalClause.isGuard(words) { return .admitted }
        if !set.isDisjoint(with: openWords) {
            return GoalClause.isHedged(set) ? .unrecognized : .act(true)
        }
        return words.isEmpty || GoalClause.isAdmittedClause(set) ? .admitted : .unrecognized
    }

    static func refusal(_ request: String, window: String, context: [String]) -> TurnAdmission.Reason? {
        ActGoal.classify(request, as: Self.self, target: window, section: nil, windows: context).refusal { _ in nil }
    }
}
