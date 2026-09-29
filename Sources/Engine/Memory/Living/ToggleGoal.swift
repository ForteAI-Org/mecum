//
//  ToggleGoal.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import PerceptionCore

/// ToggleGoal is the vocabulary of a request for exactly one toggle to reach one state, read by
/// `ActGoal`. Any other action, a dropdown selection included, makes the goal compound.
///
/// The state comes from the request, never from the tool call. A verb that carries it ("attiva",
/// "disable") decides it, and a contradicting state word in the same clause makes the clause
/// uncertain; a verb that does not ("imposta", "turn", "set") needs exactly one state word ("on",
/// "spento"). A toggle clause with a negation, an alternative, or a second setting verb is uncertain,
/// because one verified toggle proves none of them.
public enum ToggleGoal: ActGoalVocabulary {

    /// Classification is the verdict for one request: `single` names the state asked for.
    public typealias Classification = ActGoal.Classification<ControlState>

    /// Classifies `request` as a goal for the toggle labelled `control`, in `section` when the goal
    /// must name one: the section the call or the remembered step narrowed the control to. `windows`
    /// are the titles of the windows the step was proven in, whose words may name the context.
    public static func classify(
        _ request: String,
        control  : String,
        section  : String? = nil,
        windows  : [String] = []
    ) -> Classification {
        ActGoal.classify(request, as: Self.self, target: control, section: section, windows: windows)
    }

    static func read(_ words: [String]) -> ActGoal.Clause<ControlState> {
        let set = Set(words)
        if !set.isDisjoint(with: otherActionVerbs) { return .otherAction }
        if GoalClause.isGuard(words) { return .admitted }
        let actions = words.filter { stateVerbs[$0] != nil || settingVerbs.contains($0) }
        if let action = actions.first {
            guard actions.count == 1, !GoalClause.isHedged(set) else { return .unrecognized }
            let wordStates = Set(set.compactMap { stateWords[$0] })
            if let state = stateVerbs[action] {
                return wordStates.isSubset(of: [state]) ? .act(state) : .unrecognized
            }
            guard wordStates.count == 1, let state = wordStates.first else { return .unrecognized }
            return .act(state)
        }
        if words.isEmpty || GoalClause.isAdmittedClause(set) { return .admitted }
        return .unrecognized
    }

    static let actWords: Set<String> = settingVerbs.union(stateVerbs.keys).union(stateWords.keys)

    // MARK: Vocabulary

    /// Verbs that carry the state they ask for.
    private static let stateVerbs: [String: ControlState] = [
        "attiva": .on, "attivare": .on, "abilita": .on, "abilitare": .on, "accendi": .on, "accendere": .on,
        "spunta": .on, "enable": .on, "activate": .on,
        "disattiva": .off, "disattivare": .off, "disabilita": .off, "disabilitare": .off, "spegni": .off,
        "spegnere": .off, "disable": .off, "deactivate": .off, "uncheck": .off, "untick": .off,
    ]

    /// Verbs that set a toggle only together with a state word.
    private static let settingVerbs: Set<String> = [
        "imposta", "impostare", "metti", "mettere", "porta", "portare", "cambia", "cambiare",
        "set", "turn", "switch", "put", "change", "toggle",
    ]

    /// Words that name a state.
    private static let stateWords: [String: ControlState] = [
        "on": .on, "acceso": .on, "accesa": .on, "attivo": .on, "attivato": .on, "attivata": .on,
        "abilitato": .on, "abilitata": .on, "enabled": .on, "active": .on, "checked": .on,
        "off": .off, "spento": .off, "spenta": .off, "disattivo": .off, "disattivato": .off, "disattivata": .off,
        "disabilitato": .off, "disabilitata": .off, "disabled": .off, "inactive": .off, "unchecked": .off,
    ]

    /// Every action verb that is not a toggle's, a dropdown selection's included.
    private static let otherActionVerbs: Set<String> = GoalClause.actionVerbs
        .subtracting(stateVerbs.keys)
        .subtracting(settingVerbs)
}
