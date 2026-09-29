//
//  Recall+Suggestion.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// Recall's living-memory answer. Every branch is a suggestion, a piece of history, or an
/// abstention with its reason: nothing here calls a tool, and a suggestion is never permission.
/// A remembered control is historical; whether it is on screen now is read only from the fresh
/// scene in the context, and its absence there is a reason to abstain, never a contradiction.
extension Recall {

    /// Context is where the decision is made: the application and window the person is in, when
    /// known, and the scene captured in this turn, when there is one. A scene cached from an earlier
    /// turn is not fresh and must not be passed.
    public struct Context: Sendable {
        public let bundleID: String?
        public let windowFamily: String?
        public let freshScene: SceneSnapshot?

        public init(bundleID: String? = nil, windowFamily: String? = nil, freshScene: SceneSnapshot? = nil) {
            self.bundleID     = bundleID
            self.windowFamily = windowFamily
            self.freshScene   = freshScene
        }

        /// The context a fresh scene establishes: its application, its window family, and itself.
        public init(freshScene scene: SceneSnapshot) {
            let family = LabelText.letters(scene.windowTitle)
            self.init(bundleID: scene.bundleID, windowFamily: family.isEmpty ? nil : family, freshScene: scene)
        }
    }

    /// Match is how the request relates to a remembered experience, strongest last.
    public enum Match: Int, Sendable, Equatable, Comparable {
        /// The request covers most of the remembered phrase's goal words.
        case partialPhrase
        /// The request asks for the same single selection, however it is phrased.
        case sameStep
        /// The request has exactly the remembered phrase's goal words.
        case exactPhrase

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Presence is what the fresh scene says about the remembered control right now.
    public enum Presence: String, Sendable, Equatable {
        /// No fresh scene of the remembered window: observe before acting.
        case notObserved
        /// The fresh scene shows the control, by its remembered value or by the item.
        case presentNow
        /// The fresh scene of the remembered window does not show it.
        case absentNow
        /// The fresh scene shows more than one candidate.
        case ambiguousNow
        /// The fresh scene cannot attribute controls to the window, such as one with pop-up rows.
        case unattributable
    }

    /// Suggestion is one remembered experience offered for this request, with its provenance.
    public struct Suggestion: Sendable, Equatable {
        public let record: ExperienceRecord
        public let match: Match
        public let presence: Presence
        /// How often the control was sighted in the remembered window, as history.
        public let sightingEvidence: Int

        /// Whether the suggestion may guide the next step. Even then the tool resolves the control
        /// again in a fresh scene and verifies the result.
        public var isOperational: Bool { presence == .presentNow || presence == .notObserved }
    }

    /// RefusedMemory is the matching memory recall would not offer, and why.
    public struct RefusedMemory: Sendable, Equatable {
        public let experienceID: ExperienceID
        public let refusal: Refusal
    }

    /// Refusal is why a matching memory was not suggested.
    public enum Refusal: Sendable, Equatable {
        /// More contradictions than verified successes, or none verified.
        case notReliable(successes: Int, failures: Int)
        /// It was learned in another application; memories never move between applications.
        case otherApplication(learnedIn: String, current: String)
    }

    /// Why a matching memory is offered only as history.
    public enum HistoricalReason: Sendable, Equatable {
        /// The request shares the remembered phrase's words but is not shown to ask for the step's
        /// single goal: it could not be read, asks for no selection, or holds words the step does not
        /// represent. Words alone never make a memory operational.
        case goalNotSingle
        /// It was learned in another window of this application.
        case otherWindow(learnedIn: String, current: String)
        /// The fresh scene does not show the control, or shows it ambiguously, or cannot attribute it.
        case notOperationalNow(Presence)
    }

    /// Consideration is one candidate record and what the decision made of it, for diagnosis.
    public struct Consideration: Sendable, Equatable {
        public let experienceID: ExperienceID
        public let match: Match?
        public let verdict: String
    }

    /// SuggestionAnswer is the decision for one request.
    public enum SuggestionAnswer: Sendable, Equatable {
        /// Offer this experience; observe and verify before and after acting on it.
        case suggest(Suggestion, considered: [Consideration])
        /// Mention this experience as history only; it gives no ground to act here and now.
        case historical(Suggestion, HistoricalReason, considered: [Consideration])
        /// Offer nothing, with the refusal of the best matching memory when one matched.
        case abstain(RefusedMemory?, considered: [Consideration])

        public var considered: [Consideration] {
            switch self {
                case .suggest(_, let considered), .historical(_, _, let considered), .abstain(_, let considered):
                    considered
            }
        }

        /// The decision to keep for the inspector, under the caller's idempotency key and time.
        public func decisionRecord(id: String, at date: Date, phrase: String,
                                   context: WindowContext?) -> RecallDecisionRecord {
            switch self {
                case .suggest(let suggestion, _):
                    RecallDecisionRecord(id: id, at: date, phrase: phrase, context: context,
                                         experienceID: suggestion.record.id, verdict: .suggested,
                                         reason: "\(suggestion.match) match, \(suggestion.presence.rawValue)")
                case .historical(let suggestion, let why, _):
                    RecallDecisionRecord(id: id, at: date, phrase: phrase, context: context,
                                         experienceID: suggestion.record.id, verdict: .refused,
                                         reason: "history only: \(why)")
                case .abstain(let refused?, _):
                    RecallDecisionRecord(id: id, at: date, phrase: phrase, context: context,
                                         experienceID: refused.experienceID, verdict: .refused,
                                         reason: "\(refused.refusal)")
                case .abstain(nil, _):
                    RecallDecisionRecord(id: id, at: date, phrase: phrase, context: context,
                                         experienceID: nil, verdict: .abstained, reason: "nothing remembered matches")
            }
        }
    }

    /// Decides which remembered experience, if any, to offer for `input` in the world's context.
    ///
    /// A record matches as its step's kind defines (`LearnableStep.recallMatch`): a selection by its
    /// exact goal words, by asking for the same single selection, or by the hint coverage, and never
    /// for a request `SelectionGoal` shows asks for another step; a toggle only by a request for its own
    /// state (`ToggleGoal`), and a click only by a request for its own gesture that names no other
    /// surface (`ClickGoal`). Only the step's single goal makes a match operational: a match by words
    /// alone is history (`goalNotSingle`). A matching record
    /// is then refused when it is not trustworthy or belongs to another application; offered as
    /// history when it belongs to another window or the fresh scene does not show its control;
    /// and suggested otherwise. The best answer wins: a suggestion over history over a refusal,
    /// then the stronger match, more successes, and the most recent verification.
    public static func suggest(input: String, in world: World) -> SuggestionAnswer {
        let inputTokens = Set(GoalPhrase.tokens(input))
        var suggestions: [Suggestion] = []
        var history: [(Suggestion, HistoricalReason)] = []
        var refusals: [(Match, RefusedMemory)] = []
        var considered: [Consideration] = []
        for record in world.records {
            guard let (match, isGoal) = match(record, input: input, inputTokens: inputTokens) else {
                considered.append(Consideration(experienceID: record.id, match: nil, verdict: "no match"))
                continue
            }
            guard Experience.isTrustworthy(ok: record.successCount, fail: record.failureCount) else {
                let refusal = Refusal.notReliable(successes: record.successCount, failures: record.failureCount)
                refusals.append((match, RefusedMemory(experienceID: record.id, refusal: refusal)))
                considered.append(Consideration(experienceID: record.id, match: match, verdict: "\(refusal)"))
                continue
            }
            if let current = world.context.bundleID, current != record.context.bundleID {
                let refusal = Refusal.otherApplication(learnedIn: record.context.bundleID, current: current)
                refusals.append((match, RefusedMemory(experienceID: record.id, refusal: refusal)))
                considered.append(Consideration(experienceID: record.id, match: match, verdict: "\(refusal)"))
                continue
            }
            let suggestion = Suggestion(record: record, match: match, presence: presence(of: record, in: world.context),
                                        sightingEvidence: sightingEvidence(for: record, in: world.sightings))
            if !isGoal {
                history.append((suggestion, .goalNotSingle))
                considered.append(Consideration(experienceID: record.id, match: match,
                                                verdict: "history: \(HistoricalReason.goalNotSingle)"))
            } else if let current = world.context.windowFamily, current != record.context.windowFamily {
                let why = HistoricalReason.otherWindow(learnedIn: record.context.windowFamily, current: current)
                history.append((suggestion, why))
                considered.append(Consideration(experienceID: record.id, match: match, verdict: "history: \(why)"))
            } else if suggestion.isOperational {
                suggestions.append(suggestion)
                considered.append(Consideration(experienceID: record.id, match: match,
                                                verdict: "suggested, \(suggestion.presence.rawValue)"))
            } else {
                let why = HistoricalReason.notOperationalNow(suggestion.presence)
                history.append((suggestion, why))
                considered.append(Consideration(experienceID: record.id, match: match, verdict: "history: \(why)"))
            }
        }
        if let best = suggestions.max(by: isWeaker) { return .suggest(best, considered: considered) }
        if let best = history.max(by: { isWeaker($0.0, $1.0) }) {
            return .historical(best.0, best.1, considered: considered)
        }
        return .abstain(refusals.max { $0.0 < $1.0 }?.1, considered: considered)
    }

    // MARK: Rules

    /// How the request relates to the record's step, as the step's kind defines it
    /// (`LearnableStep.recallMatch`), or nil for a request without goal content.
    private static func match(
        _ record   : ExperienceRecord,
        input      : String,
        inputTokens: Set<String>
    ) -> (match: Match, isGoal: Bool)? {
        guard !inputTokens.isEmpty else { return nil }
        return record.step.learnable.recallMatch(input, tokens: inputTokens, in: record)
    }

    /// What the fresh scene says about the record's control, when the scene is of its window.
    private static func presence(of record: ExperienceRecord, in context: Context) -> Presence {
        guard let scene = context.freshScene,
              scene.bundleID == record.context.bundleID,
              LabelText.letters(scene.windowTitle) == record.context.windowFamily else { return .notObserved }
        guard scene.coverage == .window else { return .unattributable }
        let readings = record.step.learnable.resolutions(in: scene)
        if readings.contains(where: { if case .found = $0 { true } else { false } }) { return .presentNow }
        if readings.contains(where: { if case .ambiguous = $0 { true } else { false } }) { return .ambiguousNow }
        return .absentNow
    }

    private static func sightingEvidence(for record: ExperienceRecord, in sightings: [Sighting]) -> Int {
        let names = Set(record.step.learnable.sightedLabels.map(LabelText.normalize))
        return sightings
            .filter { $0.key.context == record.context && names.contains(LabelText.normalize($0.name)) }
            .reduce(0) { $0 + $1.evidenceCount }
    }

    /// The ranking among answers of one kind: match, then successes, then the latest verification.
    private static func isWeaker(_ lhs: Suggestion, _ rhs: Suggestion) -> Bool {
        let left  = (lhs.match, lhs.record.successCount, lhs.record.lastVerifiedAt ?? .distantPast)
        let right = (rhs.match, rhs.record.successCount, rhs.record.lastVerifiedAt ?? .distantPast)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }
}
