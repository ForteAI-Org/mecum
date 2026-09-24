//
//  TurnAdmission.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// TurnAdmission decides what one finished chat turn may teach the living memory. It is a pure
/// function of typed facts: the user's request, the tool attempts in order with their typed
/// outcomes and proof, how the turn ended, and the remembered experience the turn followed, if
/// any. No provider, transcript text, or tool narration is read, and a provider's "completed"
/// only means the turn ended normally: it never attests the goal.
///
/// A turn is promoted to a verified experience only when all of these hold:
/// - the request is a single-selection goal (`SelectionGoal.single`) naming the item;
/// - the tools were only status, windows, open_session and observe, plus exactly one `select`;
/// - no tool call failed and the turn ended `.completed`;
/// - the select answered `found_acted` with evidence that the control changed to the item, and
///   its arguments are the evidence's control and item;
/// - the evidence names an attributable window context.
/// Anything uncertain is not promoted. A select's own evidence is still kept as history, and a
/// readback of another value after following a remembered step contradicts that memory.
public enum TurnAdmission {

    /// Attempt is one tool call of the turn, as the tool layer observed it.
    public enum Attempt: Sendable, Equatable {
        /// A read or setup call: status, windows, apps, open_session, observe.
        case preparation(String)
        /// A select with its arguments, its outcome kind, and its evidence when it chose an item.
        case select(control: String, item: String, kind: ActOutcomeKind, evidence: DropdownEvidence?)
        /// A direct act.
        case act(ActOutcomeKind)
        /// A batch of steps.
        case batch
        /// Any other tool, such as close_session.
        case other(String)
        /// A call that threw, by tool name.
        case failed(String)

        /// The preparation calls a single-selection turn may make.
        public static let preparationTools: Set<String> = ["status", "windows", "apps", "open_session", "observe"]
    }

    /// Ending is how the turn ended, as the chat layer knows it, never inferred from wording.
    public enum Ending: Sendable, Equatable {
        /// The provider finished the turn normally.
        case completed
        /// The provider or the chat failed.
        case failed
        /// The person or a signal stopped the turn.
        case interrupted
        /// The turn ended by leaving work to the person.
        case handedToUser
    }

    /// FollowedExperience is the remembered experience recall suggested for this turn. With its
    /// context, a verified repetition of its step there confirms it; without, it is only contradicted.
    public struct FollowedExperience: Sendable, Equatable {
        public let id: ExperienceID
        public let step: ExperienceStep
        public let context: WindowContext?

        public init(id: ExperienceID, step: ExperienceStep, context: WindowContext? = nil) {
            self.id      = id
            self.step    = step
            self.context = context
        }

        /// Whether a select with these arguments, proven in this context, repeats this experience's step.
        func isRepeated(control: String, item: String, in context: WindowContext?) -> Bool {
            TurnAdmission.names(control, step.control) && TurnAdmission.names(item, step.item)
                && (self.context == nil || context == nil || self.context == context)
        }
    }

    /// Turn is everything the decision reads.
    public struct Turn: Sendable, Equatable {
        public let request: String
        public let attempts: [Attempt]
        public let ending: Ending
        public let followed: FollowedExperience?

        public init(request: String, attempts: [Attempt], ending: Ending, followed: FollowedExperience? = nil) {
            self.request  = request
            self.attempts = attempts
            self.ending   = ending
            self.followed = followed
        }
    }

    /// Reason is why the decision came out as it did.
    public enum Reason: String, Sendable, Equatable {
        case admittedSingleSelection
        case confirmsFollowedExperience
        case noSelection
        case severalSelections
        case batchUsed
        case actUsed
        case unexpectedTool
        case toolFailed
        case turnFailed
        case turnInterrupted
        case handedToUser
        case noEvidence
        case notVerified
        case alreadySet
        case argumentsDoNotMatchEvidence
        case noAttributableContext
        case compoundGoal
        case uncertainGoal
        case itemNotInGoal
        case contradictsFollowedExperience
    }

    /// Action is what the recorder should do.
    public enum Action: Sendable, Equatable {
        /// Record a verified success for this draft: it creates or strengthens the experience.
        case promote(ExperienceDraft, DropdownEvidence)
        /// Record a verified success of the followed experience, whatever the request's wording.
        case confirm(ExperienceID, DropdownEvidence)
        /// Record a contradiction of the followed experience; its successes are kept.
        case contradict(ExperienceID, ExperienceEvent.Contradiction)
        /// Keep the select's outcome as unlinked history in its context; nothing is learned.
        case keepAttempt(WindowContext, ExperienceEvent.Outcome)
        /// Nothing attributable to record.
        case nothing
    }

    /// Decision is the action and its reason.
    public struct Decision: Sendable, Equatable {
        public let action: Action
        public let reason: Reason

        /// The event the recorder writes under its own idempotency key and time, or nil for `.nothing`.
        public func event(id: String, at date: Date) -> ExperienceEvent? {
            switch action {
                case .promote(let draft, let proof):
                    ExperienceEvent(id: id, subject: .step(draft), outcome: .verified(proof), at: date)
                case .confirm(let experience, let proof):
                    ExperienceEvent(id: id, subject: .experience(experience), outcome: .verified(proof), at: date)
                case .contradict(let experience, let why):
                    ExperienceEvent(id: id, subject: .experience(experience), outcome: .contradicted(why), at: date)
                case .keepAttempt(let context, let outcome):
                    ExperienceEvent(id: id, subject: .unattributed(context), outcome: outcome, at: date)
                case .nothing:
                    nil
            }
        }
    }

    /// Decides one turn.
    public static func decide(_ turn: Turn) -> Decision {
        let selects = turn.attempts.compactMap { attempt -> Select? in
            guard case .select(let control, let item, let kind, let evidence) = attempt else { return nil }
            return Select(control: control, item: item, kind: kind, evidence: evidence)
        }
        guard let select = selects.first else {
            let batched = turn.attempts.contains(.batch)
            let threw = turn.attempts.contains { if case .failed = $0 { true } else { false } }
            return Decision(action: .nothing, reason: batched ? .batchUsed : threw ? .toolFailed : .noSelection)
        }
        guard selects.count == 1 else { return Decision(action: .nothing, reason: .severalSelections) }
        if let refusal = promotionRefusal(turn, select) {
            return fallback(turn, select, reason: refusal)
        }
        guard let evidence = select.evidence,
              let context = WindowContext(bundleID: evidence.bundleID, windowTitle: evidence.windowTitle),
              let draft = ExperienceDraft(phrase: turn.request, step: ExperienceStep(evidence), context: context) else {
            return fallback(turn, select, reason: .uncertainGoal)
        }
        if let followed = turn.followed,
           followed.context != nil,
           followed.isRepeated(control: select.control, item: select.item, in: context) {
            return Decision(action: .confirm(followed.id, evidence), reason: .confirmsFollowedExperience)
        }
        return Decision(action: .promote(draft, evidence), reason: .admittedSingleSelection)
    }

    // MARK: Rules

    private struct Select {
        let control: String
        let item: String
        let kind: ActOutcomeKind
        let evidence: DropdownEvidence?
    }

    /// The first reason the turn cannot be promoted, checked from the turn's shape inward to the goal.
    private static func promotionRefusal(_ turn: Turn, _ select: Select) -> Reason? {
        for attempt in turn.attempts {
            switch attempt {
                case .preparation(let tool) where !Attempt.preparationTools.contains(tool):
                    return .unexpectedTool
                case .preparation, .select: continue
                case .batch               : return .batchUsed
                case .act                 : return .actUsed
                case .other               : return .unexpectedTool
                case .failed              : return .toolFailed
            }
        }
        switch turn.ending {
            case .completed   : break
            case .failed      : return .turnFailed
            case .interrupted : return .turnInterrupted
            case .handedToUser: return .handedToUser
        }
        guard let evidence = select.evidence else { return .noEvidence }
        guard select.kind == .foundActed, evidence.isVerified else { return .notVerified }
        guard evidence.change == .changed else { return .alreadySet }
        guard names(select.control, evidence.control), names(select.item, evidence.requestedItem) else {
            return .argumentsDoNotMatchEvidence
        }
        guard WindowContext(bundleID: evidence.bundleID, windowTitle: evidence.windowTitle) != nil else {
            return .noAttributableContext
        }
        switch SelectionGoal.classify(turn.request, item: evidence.requestedItem, control: evidence.control) {
            case .single                         : return nil
            case .compound, .severalSelections   : return .compoundGoal
            case .uncertain, .noSelection        : return .uncertainGoal
            case .itemNotNamed                   : return .itemNotInGoal
        }
    }

    /// What a turn that was not promoted still records: a contradiction of the followed experience
    /// when the select repeated its step and read another value, else the select's own outcome as
    /// unlinked history when its context is attributable, else nothing.
    private static func fallback(_ turn: Turn, _ select: Select, reason: Reason) -> Decision {
        guard let evidence = select.evidence,
              let context = WindowContext(bundleID: evidence.bundleID, windowTitle: evidence.windowTitle) else {
            return Decision(action: .nothing, reason: reason)
        }
        let outcome = ExperienceEvent.Outcome(evidence)
        if case .contradicted(let why) = outcome, let followed = turn.followed,
           followed.isRepeated(control: select.control, item: select.item, in: context) {
            return Decision(action: .contradict(followed.id, why), reason: .contradictsFollowedExperience)
        }
        return Decision(action: .keepAttempt(context, outcome), reason: reason)
    }

    /// Whether a tool argument names this label: the same normalized text, or the same after the
    /// display annotations a model copies from the rendered scene (" (Impostazioni#2)", " [on]") are
    /// removed from the argument, the reading the scene resolver gives it. The label is never
    /// stripped, so "Unicode (UTF-16)" does not name "Unicode (UTF-8)".
    static func names(_ argument: String, _ label: String) -> Bool {
        let wanted = LabelText.normalize(label)
        return LabelText.normalize(argument) == wanted
            || LabelText.normalize(LabelText.strippingDisplayAnnotations(argument)) == wanted
    }
}
