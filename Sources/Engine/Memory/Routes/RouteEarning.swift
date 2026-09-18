//
//  RouteEarning.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// RouteEarning decides whether a turn earned a procedure, and whether the next user turn takes it
/// back. Before it existed a route was written whenever a turn ended, so real sessions taught the
/// engine to replay a metronome toggle mistaken for un-soloing and a person's own correction.
///
/// Two guards, because the two failures look nothing alike: the outcome span, over the outcomes the
/// route's own steps cover, withholds a turn that found its way by trial and error; the answer guard
/// withholds a turn whose final answer hands the work back to the user. Both are pure functions of
/// values a test can construct.
public enum RouteEarning {

    /// Outcome is one acting tool result as the engine reported it: the tool and its outcome kind.
    public struct Outcome: Sendable, Equatable {
        public let tool: String
        public let kind: ActOutcomeKind

        public init(tool: String, kind: ActOutcomeKind) {
            self.tool = tool
            self.kind = kind
        }
    }

    /// Verdict is the decision: a proof to store on the route, or the sentence an operator sees.
    public enum Verdict: Sendable, Equatable {
        case earned(proof: String)
        case withheld(reason: String)
    }

    /// The tools a route is made of, the only ones that can condemn it: a miss from an API probe says
    /// the API is off, not that the procedure is wrong.
    public static let structuralTools: Set<String> = ["act", "run_menu", "reach", "type", "go_to_folder"]

    /// Outcome kinds that mean the goal was not reached on that call.
    public static let failingKinds: Set<ActOutcomeKind> = [.honestMiss, .actedUnverified, .ambiguous, .refused]

    /// The outcome kind a tool result opens with, or nil when the result is prose rather than an outcome.
    public static func outcomeKind(ofResult text: String) -> ActOutcomeKind? {
        let head = String(text.prefix(while: { $0 != ":" && !$0.isNewline }))
        return ActOutcomeKind(rawValue: head)
    }

    /// The slice of the tape the route covers: from the outcome of its first stored step to the end. A
    /// false start before the route begins belongs to the model's search, not to the procedure.
    public static func span(of tape: [Outcome], steps: Int) -> [Outcome] {
        guard steps > 0, !tape.isEmpty else { return tape }
        var counted = 0
        var start = 0
        for i in stride(from: tape.count - 1, through: 0, by: -1) where isVerifiedStep(tape[i]) {
            counted += 1
            if counted == steps {
                start = i
                break
            }
        }
        return Array(tape[start...])
    }

    /// Whether the turn earned a route over this span.
    public static func verdict(over span: [Outcome]) -> Verdict {
        let failures = span.filter {
            failingKinds.contains($0.kind) && (structuralTools.contains($0.tool) || $0.kind == .refused)
        }
        if !failures.isEmpty {
            let tally = Dictionary(grouping: failures, by: \.kind)
                .map { "\($0.value.count)× \($0.key.rawValue)" }.sorted().joined(separator: ", ")
            return .withheld(reason: "the run was not clean: \(tally) inside the route's own steps. "
                + "A Route is earned by a verified goal, not found by trial and error.")
        }
        let acts = span.filter(isVerifiedStep).count
        guard acts >= RoutePolicy.minimumRouteSteps else {
            return .withheld(reason: "only \(acts) verified step\(acts == 1 ? "" : "s"): "
                + "a Route is a procedure of at least \(RoutePolicy.minimumRouteSteps).")
        }
        return .earned(proof: "\(acts) verified steps, none missed or unverified")
    }

    private static func isVerifiedStep(_ outcome: Outcome) -> Bool {
        outcome.kind == .foundActed && structuralTools.contains(outcome.tool)
    }

    // MARK: The answer

    /// Phrases with which a model hands the job back. A blocklist on purpose: requiring a completion
    /// claim withholds every answer in a language or register not enumerated. Every entry is from a
    /// real answer that produced a garbage route.
    private static let handbackMarkers: [String] = [
        "here is how you can", "here s how you can", "here is how to", "here s how to",
        "you can easily", "you can do it yourself", "you will need to", "you ll need to",
        "i can t", "i cannot", "i am unable", "i m unable", "unable to",
        "ecco come puoi", "puoi farlo tu", "non posso", "non sono in grado", "dovrai",
    ]

    /// Whether the turn's final answer lets it keep what it did. False when the answer explains how
    /// the user could do the thing.
    public static func answerEarnsARoute(_ answer: String) -> Bool {
        let phrase = padded(answer)
        return !handbackMarkers.contains { phrase.contains(" \($0) ") }
    }

    // MARK: The correction

    /// Correction is a user turn that says the previous one was wrong, with the trigger that matched
    /// so the narration and the stored cause can quote what was said.
    public struct Correction: Sendable, Equatable {
        public let trigger: String
        public let text: String

        public init(trigger: String, text: String) {
            self.trigger = trigger
            self.text    = text
        }
    }

    /// Explicit negations of what the engine just did. Every entry is from a real correction.
    private static let correctionPhrases: [String] = [
        "not that", "wrong", "you went", "you did not", "you didn t", "you should have",
        "you were supposed", "i said", "didn t say", "that s not", "thats not", "it s not",
        "not what i",
        "non e", "non hai", "non ha", "non era", "sbagliato", "sbagliata", "non quello",
        "non cosi", "ti ho detto", "avevo detto", "non va bene", "non funziona",
    ]

    /// A turn that opens with one of these is a correction whatever follows. Only in first position:
    /// "now" is not "no", and "no fade" mid-sentence is not a verdict on the engine.
    private static let openingNegations: Set<String> = ["no", "nope", "nah", "non"]

    /// Whether this user turn retracts what the last one did. Conservative by construction: a false
    /// positive deletes a procedure the engine earned, a false negative keeps a stale one the next
    /// replay failure demotes anyway. Only explicit negations and reproaches count.
    public static func correction(in userTurn: String) -> Correction? {
        let words = LabelText.tokens(fold(userTurn))
        guard !words.isEmpty else { return nil }
        let phrase = " " + words.joined(separator: " ") + " "
        if let hit = correctionPhrases.first(where: { phrase.contains(" \($0) ") }) {
            return Correction(trigger: hit, text: userTurn)
        }
        if openingNegations.contains(words[0]) {
            return Correction(trigger: words[0], text: userTurn)
        }
        return nil
    }

    // MARK: Text

    /// Diacritic-folded, so "non è quello" and "non e quello" are the same sentence.
    private static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func padded(_ string: String) -> String {
        " " + LabelText.tokens(fold(string)).joined(separator: " ") + " "
    }
}
