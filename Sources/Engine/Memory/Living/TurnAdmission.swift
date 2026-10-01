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
/// - the tools were only status, windows, open_session and observe, plus exactly one learnable
///   step: one `select`, or one `act` with any verb;
/// - the request is that single goal: `SelectionGoal.single` naming the item, `ToggleGoal.single`
///   naming the control and asking for the state the call requested, or `ClickGoal.single` naming
///   the target and asking for the gesture the call made and, when it names one, the surface opened;
/// - no tool call failed and the turn ended `.completed`;
/// - the step's evidence proves the goal: the dropdown now reads the item; the toggle read the other
///   definite state before, a click was sent, and it reads the requested state after; or a menu or
///   window is attributed to the gesture, with the tool's outcome `found_acted`;
/// - the step's arguments are the evidence's control and item, state, or target and gesture, and
///   the evidence names an attributable window context.
/// A turn that meets all of these and repeats the followed experience's step in its context confirms
/// that experience instead. Anything uncertain is neither promoted nor confirmed. A single step's own
/// evidence is still kept as history, as a success only when the tool's outcome verified it, and a
/// readback of another value after following a remembered step contradicts that memory, in a turn of
/// several steps too when that is the only verdict about it.
public enum TurnAdmission {

    /// Attempt is one tool call of the turn, as the tool layer observed it.
    public enum Attempt: Sendable, Equatable {
        /// A read or setup call: status, windows, apps, open_session, observe.
        case preparation(String)
        /// A select with its arguments, its outcome kind, and its evidence when it chose an item.
        case select(control: String, item: String, kind: ActOutcomeKind, evidence: DropdownEvidence?)
        /// A direct act with its arguments, its outcome kind, and its evidence: a `set_toggle`'s once it
        /// resolved its control, a click's once its gesture was attempted.
        case act(ActionArguments, kind: ActOutcomeKind, evidence: ActEvidence?)
        case menu(MenuStep.Call, kind: ActOutcomeKind, evidence: MenuEvidence?)
        /// A batch of steps.
        case batch
        /// Any other tool, such as close_session.
        case other(String)
        /// A call that threw, by tool name, with an act's arguments when they could be read.
        case failed(String, act: ActionArguments? = nil)

        /// The preparation calls a single-step turn may make.
        public static let preparationTools: Set<String> = ["status", "windows", "apps", "open_session", "observe", "menus", "resolve_action"]
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

        /// Whether a step proven in this context repeats this experience's step, as its kind defines
        /// repeating: the same tool on the same control, with the same item, the same state and section,
        /// or the same gesture, section and surface.
        func isRepeated(by other: ExperienceStep, in context: WindowContext?) -> Bool {
            step.isRepeated(by: other) && (self.context == nil || context == nil || self.context == context)
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
        case admittedSingleToggle
        case admittedSingleMenu
        case admittedSingleClick
        case confirmsFollowedExperience
        /// No select and no act was made.
        case noSelection
        case severalSelections
        /// More than one learnable step, and not all of them selects.
        case severalSteps
        case batchUsed
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
        case controlNotInGoal
        /// The request asks for the other state than the one the toggle was set to.
        case stateNotInGoal
        /// The call narrowed the toggle or the target to a section the request does not name.
        case sectionNotInGoal
        /// The request qualifies the control or the target with words the step does not keep, such as
        /// a section the call did not narrow it to.
        case qualifierNotInStep
        /// The request asks for another gesture than the one the call made.
        case gestureNotInGoal
        /// The request names another surface than the one the gesture opened.
        case surfaceNotInGoal
        /// The request names the selected item as the value to change from, not the one to reach.
        case itemIsOrigin
        case contradictsFollowedExperience

        /// Whether the reason records a verified success: a single step admitted, or the followed
        /// experience confirmed.
        public var verifiesStep: Bool {
            switch self {
                case .admittedSingleSelection, .admittedSingleToggle, .admittedSingleClick, .admittedSingleMenu,
                     .confirmsFollowedExperience: true
                default                         : false
            }
        }
    }

    /// Action is what the recorder should do.
    public enum Action: Sendable, Equatable {
        /// Record a verified success for this draft: it creates or strengthens the experience.
        case promote(ExperienceDraft, ActEvidence)
        /// Record a verified success of the followed experience. It needs every promotion rule above,
        /// the request asking for that single step included; the wording may differ from the remembered one.
        case confirm(ExperienceID, ActEvidence)
        /// Record a contradiction of the followed experience; its successes are kept.
        case contradict(ExperienceID, ExperienceEvent.Contradiction)
        /// Keep the step's outcome as unlinked history in its context; nothing is learned.
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
        let steps = turn.attempts.compactMap(Step.init)
        guard let step = steps.first else {
            let batched = turn.attempts.contains(.batch)
            let threw = turn.attempts.contains { if case .failed = $0 { true } else { false } }
            return Decision(action: .nothing, reason: batched ? .batchUsed : threw ? .toolFailed : .noSelection)
        }
        guard steps.count == 1 else {
            let selects = steps.allSatisfy(\.isSelect)
            return severalSteps(turn, steps, reason: selects ? .severalSelections : .severalSteps)
        }
        if let refusal = promotionRefusal(turn, step) {
            return fallback(turn, step, reason: refusal)
        }
        guard let evidence = step.evidence, let context = step.context, let judgement = step.judgement,
              let remembered = judgement.remembered,
              let draft = ExperienceDraft(phrase: turn.request, step: remembered, context: context) else {
            return fallback(turn, step, reason: .uncertainGoal)
        }
        if let followed = turn.followed,
           followed.context != nil,
           followed.isRepeated(by: remembered, in: context) {
            return Decision(action: .confirm(followed.id, evidence), reason: .confirmsFollowedExperience)
        }
        return Decision(action: .promote(draft, evidence), reason: judgement.admission)
    }

    // MARK: Rules

    /// Step is the turn's one learnable call: a select, a `set_toggle`, or a click, double-click or
    /// right-click, with its outcome kind, its typed evidence, and its kind's judgement of them.
    private struct Step {

        /// Judgement is what the call's kind of step makes of its evidence, once the evidence is of that
        /// kind: why the call cannot teach its step for a request, the step the evidence proves, and the
        /// reason a promotion of that step is admitted with.
        struct Judgement {
            let refusal: (String) -> Reason?
            let remembered: ExperienceStep?
            let admission: Reason
        }

        let isSelect: Bool
        let kind: ActOutcomeKind
        let evidence: ActEvidence?

        /// Nil when the call made no proof, or one of another kind than its own.
        let judgement: Judgement?

        init?(_ attempt: Attempt) {
            switch attempt {
                case .menu(let call, let kind, let evidence):
                    let proof = evidence.map(ActEvidence.menu)
                    self.init(isSelect: false, kind: kind, evidence: proof,
                              judgement: Self.judge(MenuStep.self, call, kind, proof))
                case .select(let control, let item, let kind, let evidence):
                    let proof = evidence.map(ActEvidence.dropdown)
                    let call = SelectionStep.Call(control: control, item: item)
                    self.init(isSelect: true, kind: kind, evidence: proof,
                              judgement: Self.judge(SelectionStep.self, call, kind, proof))
                case .act(let arguments, let kind, let evidence):
                    let judgement = arguments.verb == .setToggle
                        ? Self.judge(ToggleStep.self, arguments, kind, evidence)
                        : Self.judge(ClickStep.self, arguments, kind, evidence)
                    self.init(isSelect: false, kind: kind, evidence: evidence, judgement: judgement)
                default:
                    return nil
            }
        }

        private init(isSelect: Bool, kind: ActOutcomeKind, evidence: ActEvidence?, judgement: Judgement?) {
            self.isSelect  = isSelect
            self.kind      = kind
            self.evidence  = evidence
            self.judgement = judgement
        }

        /// The judgement of `S` over `call` and its evidence, when the evidence is of kind `S`.
        private static func judge<S: LearnableStep>(
            _: S.Type,
            _ call    : S.Call,
            _ kind    : ActOutcomeKind,
            _ evidence: ActEvidence?
        ) -> Judgement? {
            guard let evidence = evidence.flatMap(S.evidence(in:)) else { return nil }
            return Judgement(
                refusal   : { request in S.refusal(request, call: call, kind: kind, evidence: evidence) },
                remembered: S(proving: evidence, for: call)?.experienceStep,
                admission : S.admission
            )
        }

        /// The outcome the evidence proves, as history: a success only when the tool's outcome verified
        /// it too, so history never keeps as verified what the tool reported unverified.
        func keptOutcome(of evidence: ActEvidence) -> ExperienceEvent.Outcome {
            let outcome = ExperienceEvent.Outcome(evidence)
            if case .verified = outcome, kind != .foundActed { return .uncertain(.outcomeNotVerified) }
            return outcome
        }

        /// The window the evidence names, when it can be attributed.
        var context: WindowContext? {
            evidence.flatMap { WindowContext(bundleID: $0.bundleID, windowTitle: $0.windowTitle) }
        }

        /// The step as an experience would remember it, from its evidence of the matching kind.
        var remembered: ExperienceStep? { judgement?.remembered }
    }

    /// The first reason the turn cannot be promoted, checked from the turn's shape inward to the goal.
    private static func promotionRefusal(_ turn: Turn, _ step: Step) -> Reason? {
        for attempt in turn.attempts {
            switch attempt {
                case .preparation(let tool) where !Attempt.preparationTools.contains(tool):
                    return .unexpectedTool
                case .preparation, .select, .act, .menu: continue
                case .batch                     : return .batchUsed
                case .other                     : return .unexpectedTool
                case .failed                    : return .toolFailed
            }
        }
        switch turn.ending {
            case .completed   : break
            case .failed      : return .turnFailed
            case .interrupted : return .turnInterrupted
            case .handedToUser: return .handedToUser
        }
        guard step.evidence != nil else { return .noEvidence }
        guard let judgement = step.judgement else { return .argumentsDoNotMatchEvidence }
        return judgement.refusal(turn.request)
    }

    /// What a turn of several steps records: never a promotion or a confirmation, since no single step
    /// is the request's goal, but a contradiction of the followed experience when every verdict about it
    /// is that one contradiction. A verdict about it is the outcome of a step that repeated its step in its
    /// context; a verified repetition beside the contradiction, or two different readings, decide nothing.
    /// The other steps' outcomes are not kept: one turn records one event.
    private static func severalSteps(_ turn: Turn, _ steps: [Step], reason: Reason) -> Decision {
        guard let followed = turn.followed else { return Decision(action: .nothing, reason: reason) }
        let verdicts = steps.compactMap { step -> ExperienceEvent.Outcome? in
            guard let evidence = step.evidence, let context = step.context, let remembered = step.remembered,
                  followed.isRepeated(by: remembered, in: context) else { return nil }
            switch step.keptOutcome(of: evidence) {
                case .verified(let proof)     : return .verified(proof)
                case .contradicted(let why)   : return .contradicted(why)
                case .noChange, .uncertain    : return nil
            }
        }
        let contradictions = verdicts.compactMap { verdict -> ExperienceEvent.Contradiction? in
            if case .contradicted(let why) = verdict { why } else { nil }
        }
        guard let why = contradictions.first, contradictions.count == verdicts.count,
              contradictions.allSatisfy({ $0 == why }) else {
            return Decision(action: .nothing, reason: reason)
        }
        return Decision(action: .contradict(followed.id, why), reason: .contradictsFollowedExperience)
    }

    /// What a turn that was not promoted still records: a contradiction of the followed experience
    /// when the step repeated its step in its context and read another value, else the step's own
    /// outcome as unlinked history when its context is attributable, else nothing.
    private static func fallback(_ turn: Turn, _ step: Step, reason: Reason) -> Decision {
        guard let evidence = step.evidence, let context = step.context else {
            return Decision(action: .nothing, reason: reason)
        }
        let outcome = step.keptOutcome(of: evidence)
        if case .contradicted(let why) = outcome, let followed = turn.followed, let remembered = step.remembered,
           followed.isRepeated(by: remembered, in: context) {
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
