//
//  ClickGoal.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import EngineCore
import PerceptionCore

/// ClickGoal is the vocabulary of a request for exactly one click, double-click or right-click on one
/// target, read by `ActGoal`. Any other action makes the goal compound.
///
/// The gesture comes from the request, never from the tool call: "clicca", "premi" and "click" ask
/// for a click, a double word ("doppio", "double", "due volte") for a double-click, and a right word
/// ("destro", "right", "tasto destro") for a right-click. The clause may say what the gesture should
/// open, "per aprire il menu" or "to open the window", and then only that surface proves it. A clause
/// with a negation, an alternative, or both a double and a right word is uncertain. An open verb
/// without a click verb, as in "Apri il menu File", is another action: which gesture opens it is not
/// the request's to say.
public enum ClickGoal: ActGoalVocabulary {

    /// Surface is what the request says the gesture should open.
    public enum Surface: Sendable, Equatable {
        case menu
        case window

        /// Whether an attributed surface is of this kind.
        public func matches(_ surface: ClickEvidence.Surface) -> Bool {
            switch (self, surface) {
                case (.menu, .menu), (.window, .window): true
                default                                : false
            }
        }
    }

    /// Ask is what one click clause asks for: the gesture and, when it says one, the surface to open.
    public struct Ask: Sendable, Equatable {
        public let gesture: ClickEvidence.Gesture
        public let opens: Surface?
        public let closes: Bool

        public init(_ gesture: ClickEvidence.Gesture, opens: Surface?, closes: Bool = false) {
            self.gesture = gesture
            self.opens   = opens
            self.closes  = closes
        }

        /// Whether `gesture` opening `surface` is what this clause asks for.
        public func isAnswered(by gesture: ClickEvidence.Gesture, opening surface: ClickEvidence.Surface) -> Bool {
            !closes && gesture == self.gesture && (opens.map { $0.matches(surface) } ?? true)
        }
    }

    /// Classification is the verdict for one request: `single` names the gesture and surface asked for.
    public typealias Classification = ActGoal.Classification<Ask>

    /// Classifies `request` as a goal for a gesture on the element labelled `target`, in `section`
    /// when the goal must name one: the section the call or the remembered step narrowed it to.
    /// `windows` are the titles of the windows the step involves, the one it started in and the one
    /// it opened, whose words may name the context.
    public static func classify(
        _ request: String,
        target   : String,
        section  : String? = nil,
        windows  : [String] = []
    ) -> Classification {
        ActGoal.classify(request, as: Self.self, target: target, section: section, windows: windows)
    }

    static func read(_ words: [String]) -> ActGoal.Clause<Ask> {
        let set = Set(words)
        if !set.isDisjoint(with: otherActionVerbs) { return .otherAction }
        if GoalClause.isGuard(words) { return .admitted }
        let closes = !set.isDisjoint(with: closeVerbs)
        let rightByKey = set.contains("tasto") && !set.isDisjoint(with: rightWords)
        guard !set.isDisjoint(with: clickVerbs) || rightByKey || closes else {
            if !set.isDisjoint(with: openVerbs) { return .otherAction }
            if words.isEmpty || GoalClause.isAdmittedClause(set) { return .admitted }
            return .unrecognized
        }
        let double = !set.isDisjoint(with: doubleWords) || GoalClause.contains(words, ["due", "volte"])
        let right = !set.isDisjoint(with: rightWords)
        let menu = !set.isDisjoint(with: menuWords)
        let window = !set.isDisjoint(with: windowWords)
        guard !GoalClause.isHedged(set), !(double && right), !(menu && window) else { return .unrecognized }
        if closes && (double || right || menu || !set.isDisjoint(with: openVerbs)) { return .unrecognized }
        let gesture: ClickEvidence.Gesture = double ? .doubleClick : right ? .rightClick : .click
        return .act(Ask(gesture, opens: closes ? nil : menu ? .menu : window ? .window : nil, closes: closes))
    }

    static let actWords: Set<String> = clickVerbs.union(doubleWords).union(rightWords)
        .union(openVerbs).union(closeVerbs).union(menuWords).union(windowWords)
        .union(["fai", "fare", "do", "col", "con", "with", "tasto", "mouse", "due", "volte", "it"])

    // MARK: Vocabulary

    /// Verbs and nouns that ask for a pointer gesture.
    private static let clickVerbs: Set<String> = [
        "clicca", "cliccare", "cliccaci", "clic", "click", "premi", "premere", "press", "tap",
        "doubleclick", "rightclick",
    ]

    private static let doubleWords: Set<String> = ["doppio", "double", "doubleclick", "twice"]

    private static let rightWords: Set<String> = ["destro", "right", "secondario", "secondary", "rightclick"]

    /// A close request still has to name the exact control that performed the single click.
    private static let closeVerbs: Set<String> = ["chiudi", "chiudere", "chiuderla", "chiuderlo", "close", "dismiss"]

    private static let openVerbs: Set<String> = ["apri", "aprire", "aprirlo", "aprirla", "open", "opens"]

    private static let menuWords: Set<String> = ["menu", "menù", "contestuale", "context", "contextual"]

    private static let windowWords: Set<String> = ["finestra", "window", "dialogo", "dialog"]

    /// Every action verb that is not a click's, a selection's and a toggle's included.
    private static let otherActionVerbs: Set<String> = GoalClause.actionVerbs
        .subtracting(clickVerbs)
        .subtracting(openVerbs)
        .subtracting(closeVerbs)
}

extension ActGoal.Classification where Ask == ClickGoal.Ask {

    /// One click clause asking for `gesture` and, when it says one, the surface it `opens`.
    public static func single(_ gesture: ClickEvidence.Gesture, opens: ClickGoal.Surface?) -> Self {
        .single(ClickGoal.Ask(gesture, opens: opens))
    }
}
