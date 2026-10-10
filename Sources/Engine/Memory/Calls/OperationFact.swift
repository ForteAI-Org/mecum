//
//  OperationFact.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore

/// OperationEffect is what a call really did, beside what it asked (its request): the gesture that
/// went out (`OperationCheck.Performed`), the one that replaced it when another did, why none went
/// out when none did, the element it resolved, and whether its path reported a check at all. A call
/// whose path reported none keeps `checked` false: an explicit gap, never a pass.
public struct OperationEffect: Sendable, Equatable {

    public let callEventID: String
    public let performed: OperationCheck.Performed
    public let substitute: String?
    /// The outcome kind or reason a call sent no gesture for (`honest_miss`, `refused`, a no-op).
    public let notSentReason: String?
    public let target: OperationCheck.Target?
    public let checked: Bool

    public init(callEventID: String, performed: OperationCheck.Performed, substitute: String? = nil,
                notSentReason: String? = nil, target: OperationCheck.Target? = nil, checked: Bool) throws {
        func refuse(_ invalidity: OperationFactError.Invalidity) -> OperationFactError { .invalid(invalidity) }
        guard !callEventID.isEmpty else { throw refuse(.emptyText(field: "call")) }
        guard (performed == .substitute) == (substitute != nil) else { throw refuse(.substituteMismatch) }
        if notSentReason != nil, performed != .none { throw refuse(.reasonWithGesture) }
        self.callEventID   = callEventID
        self.performed     = performed
        self.substitute    = substitute
        self.notSentReason = notSentReason
        self.target        = target
        self.checked       = checked
    }
}

/// OperationVerification is one check of one call as a fact of the living memory: an event of its own
/// (`verification`, with the call's producer, trace and session), the call it judged, the condition,
/// the method and its version, the verdict, the expected and observed texts it compared (nil when the
/// method compares none, or withheld with the limit `value_withheld`), the limits of the evidence, the
/// target and the samples it rests on. The verdict is the oracle's, carried as it was given: nothing
/// here promotes an `unknown` or reads a tool's success as a pass. A later attribution to a step adds
/// to it (`VerificationStoring.attribute`) and never rewrites it.
public struct OperationVerification: Sendable {

    public let event: MemoryEventRecord
    public let callEventID: String
    public let check: OperationCheck
    public let samples: [CaptureSampleKey]

    public init(
        event      : MemoryEventRecord,
        callEventID: String,
        check      : OperationCheck,
        samples    : [CaptureSampleKey]
    ) throws {
        func refuse(_ invalidity: OperationFactError.Invalidity) -> OperationFactError { .invalid(invalidity) }
        try event.validate()
        guard event.kind == .verification else { throw refuse(.notAVerification) }
        guard !callEventID.isEmpty, !callEventID.utf8.elementsEqual(event.eventID.utf8) else {
            throw refuse(.emptyText(field: "call"))
        }
        var seen: Set<CaptureSampleKey> = []
        for sample in samples where !seen.insert(sample).inserted { throw refuse(.duplicateSample) }
        self.event       = event
        self.callEventID = callEventID
        self.check       = check
        self.samples     = samples
    }

    /// The identity a call's verification of `condition` has: the same for every offer of it, so a
    /// retried write is recognized as the same fact and never becomes a second verification.
    public static func eventID(call callEventID: String, condition: OperationCheck.Condition) -> String {
        "\(callEventID)/verification/\(condition.rawValue)"
    }

    /// The verdict in the store's vocabulary.
    public var verdict: VerificationVerdict {
        switch check.verdict {
            case .passed : .passed
            case .failed : .failed
            case .unknown: .unknown
        }
    }

    /// The base fact `memory_verifications` keeps, scope `call`.
    public func record() throws -> VerificationRecord {
        try VerificationRecord(event: event, scope: .call, method: VerificationMethod(check.method), verdict: verdict,
                               expectedText: check.expected, observedText: check.observed)
    }

    /// Whether the other verification states exactly the same facts.
    public func isExactly(_ other: OperationVerification) -> Bool {
        event.hasSameImmutableContent(as: other.event) && callEventID.utf8.elementsEqual(other.callEventID.utf8)
            && check == other.check && samples == other.samples
    }
}

/// WithholdingReason is why a value is not kept: the task declared it secret, it has the shape of a
/// credential, the control it went to is named for a secret, or the field was a secure one.
public enum WithholdingReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case declaredSecret    = "declared_secret"
    case credentialPattern = "credential_pattern"
    case secretTarget      = "secret_target"
    case secureField       = "secure_field"
}

/// ValueRedaction is the declared gap a withheld value leaves: which value of which event it was, and
/// why. The value itself is never kept, nor its length or a digest of it.
public struct ValueRedaction: Sendable, Equatable, Hashable {

    /// Location names the withheld value inside its event's facts.
    public enum Location: Sendable, Equatable, Hashable {
        /// An argument of the call, by name and position.
        case argument(name: String, position: Int)
        /// The message of the call's result.
        case resultMessage
        /// The expected or observed text of one of the call's verifications, by condition.
        case verificationExpected(OperationCheck.Condition)
        case verificationObserved(OperationCheck.Condition)
        /// The label of the element the call resolved.
        case targetLabel
        /// The section the element the call resolved sits in.
        case targetSection
        /// The identity or role of the element the call resolved, which may carry its label.
        case targetElement
        /// The label of an element of one of the event's samples, by phase, ordinal and position.
        case sampleLabel(phase: CapturePhase, ordinal: Int, element: Int)
        /// The container path of an element of one of the event's samples, which names its ancestors.
        case sampleContainer(phase: CapturePhase, ordinal: Int, element: Int)
        /// The window title of one of the event's samples, by phase and ordinal.
        case sampleTitle(phase: CapturePhase, ordinal: Int)
        /// A title or label of the effect the call observed.
        case observedEffect
        /// A text of one application of the call's listing (its name, location, version or a window's
        /// title), by the application's position.
        case listingEntry(application: Int)
    }

    public let eventID: String
    public let location: Location
    public let reason: WithholdingReason

    public init(eventID: String, location: Location, reason: WithholdingReason) {
        self.eventID  = eventID
        self.location = location
        self.reason   = reason
    }
}

/// OperationOpening is a call as its producer confirms it before any effect: the call planned and
/// started at an instant, the task attempt it belongs to when the agent declared one, and the values
/// withheld from its arguments. Written in one transaction: either all of it is in the archive, and
/// the gesture may go out, or none of it is, and the gesture does not.
public struct OperationOpening: Sendable {

    public let call: AgentCallRecord
    public let startedAtMS: Int64
    public let attribution: TaskCallAttribution?
    public let redactions: [ValueRedaction]

    public init(call: AgentCallRecord, startedAtMS: Int64, attribution: TaskCallAttribution? = nil,
                redactions: [ValueRedaction] = []) throws {
        guard redactions.allSatisfy({ $0.eventID.utf8.elementsEqual(call.event.eventID.utf8) }) else {
            throw OperationFactError.invalid(.otherEvent)
        }
        self.call        = call
        self.startedAtMS = startedAtMS
        self.attribution = attribution
        self.redactions  = redactions
    }
}

/// BatchOpening is a batch as its producer confirms it before its first step: the batch started, its
/// steps planned in order, the attempt it belongs to, and the values withheld from its steps.
public struct BatchOpening: Sendable {

    public let batch: AgentCallRecord
    public let steps: [AgentCallRecord]
    public let startedAtMS: Int64
    public let attribution: TaskCallAttribution?
    public let redactions: [ValueRedaction]

    public init(batch: AgentCallRecord, steps: [AgentCallRecord], startedAtMS: Int64,
                attribution: TaskCallAttribution? = nil, redactions: [ValueRedaction] = []) throws {
        let owners = Set(([batch] + steps).map { Array($0.event.eventID.utf8) })
        guard redactions.allSatisfy({ owners.contains(Array($0.eventID.utf8)) }) else {
            throw OperationFactError.invalid(.otherEvent)
        }
        self.batch       = batch
        self.steps       = steps
        self.startedAtMS = startedAtMS
        self.attribution = attribution
        self.redactions  = redactions
    }
}

/// OperationConclusion is a call's end as its producer confirms it after the effect: the samples it
/// perceived, its terminal state with its result, what it really did, its verifications and the
/// values withheld from them, written in one transaction. `withdrawn` names argument values the
/// opening kept and a later fact showed to be secret (the resolved field is one): the conclusion
/// replaces them with the marker in the same transaction and declares why.
public struct OperationConclusion: Sendable {

    public let end: AgentCallTransition
    public let samples: [CaptureSample]
    public let effect: OperationEffect?
    public let verifications: [OperationVerification]
    public let redactions: [ValueRedaction]
    public let withdrawn: [ValueRedaction]
    /// The parts of the end the archive refused as offered and the call concludes without.
    public let unsaved: [OperationRecordingGap]

    public init(end: AgentCallTransition, samples: [CaptureSample] = [], effect: OperationEffect? = nil,
                verifications: [OperationVerification] = [], redactions: [ValueRedaction] = [],
                withdrawn: [ValueRedaction] = [], unsaved: [OperationRecordingGap] = []) throws {
        func refuse(_ invalidity: OperationFactError.Invalidity) -> OperationFactError { .invalid(invalidity) }
        let call = end.eventID
        guard end.progress.status.isTerminal else { throw refuse(.notTerminal) }
        if let effect, !effect.callEventID.utf8.elementsEqual(call.utf8) { throw refuse(.otherEvent) }
        guard verifications.allSatisfy({ $0.callEventID.utf8.elementsEqual(call.utf8) }) else {
            throw refuse(.otherEvent)
        }
        var conditions: Set<OperationCheck.Condition> = []
        for verification in verifications where !conditions.insert(verification.check.condition).inserted {
            throw refuse(.duplicateCondition)
        }
        for withdrawal in withdrawn {
            guard case .argument = withdrawal.location, withdrawal.eventID.utf8.elementsEqual(call.utf8) else {
                throw refuse(.otherEvent)
            }
        }
        var parts: Set<OperationRecordingGap.Part> = []
        for gap in unsaved {
            guard gap.callEventID.utf8.elementsEqual(call.utf8) else { throw refuse(.otherEvent) }
            guard parts.insert(gap.part).inserted else { throw refuse(.unsavedPartKept) }
            let kept = switch gap.part {
                case .samples     : !samples.isEmpty
                case .effect      : effect != nil
                case .verification: !verifications.isEmpty
            }
            if kept { throw refuse(.unsavedPartKept) }
        }
        self.end           = end
        self.samples       = samples
        self.effect        = effect
        self.verifications = verifications
        self.redactions    = redactions
        self.withdrawn     = withdrawn
        self.unsaved       = unsaved
    }
}

/// OperationRecordingGap is a part of a call's end that the archive refused as it was offered (the
/// contract's refusal, or a conflict with a fact under the same identity) and that the call was
/// concluded without, so its state and result are kept: which part, why, and what the archive said.
/// A call with one is incomplete evidence. What it did may be read; nothing may be qualified on it,
/// and a missing verification is never read as one that passed or as an operation with no oracle.
public struct OperationRecordingGap: Sendable, Equatable {

    public enum Part: String, Sendable, Equatable, Hashable, CaseIterable {
        case samples, effect, verification
    }

    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case refused, conflict
    }

    /// The longest detail kept, in UTF-8 bytes: a diagnosis, never a value.
    public static let maximumDetailBytes = 512

    public let callEventID: String
    public let part: Part
    public let reason: Reason
    /// What the archive answered, already minimized by the producer, cut at a character boundary to
    /// `maximumDetailBytes`.
    public let detail: String?

    public init(callEventID: String, part: Part, reason: Reason, detail: String?) throws {
        guard !callEventID.isEmpty else { throw OperationFactError.invalid(.emptyText(field: "event_id")) }
        self.callEventID = callEventID
        self.part        = part
        self.reason      = reason
        self.detail      = detail.flatMap { text in
            guard !text.isEmpty else { return nil }
            var bytes = 0
            return String(text.prefix { character in
                bytes += character.utf8.count
                return bytes <= Self.maximumDetailBytes
            })
        }
    }
}

/// OperationFactError is an operation fact the contract or the store refuses.
public enum OperationFactError: Error, Sendable, Equatable {

    case invalid(Invalidity)

    /// A conclusion, an effect or a verification for a call the store does not hold.
    case missingCall(eventID: String)

    /// An attribution to an attempt that is not running, or of another task.
    case attemptNotRunning(attemptID: String)

    /// A withdrawal of an argument the call does not have.
    case missingArgument(eventID: String, name: String, position: Int)

    public enum Invalidity: Sendable, Equatable {
        case emptyText(field: String)
        case substituteMismatch
        case reasonWithGesture
        case notAVerification
        case duplicateSample
        case duplicateCondition
        case otherEvent
        case notTerminal
        /// A part declared unsaved is also offered, or declared twice.
        case unsavedPartKept
    }
}
