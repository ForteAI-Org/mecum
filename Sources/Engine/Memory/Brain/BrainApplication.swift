//
//  BrainApplication.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// BrainOperation is what an application does to a brain: ingest an observation, record what an
/// action taught, or name an anchor. Decay is not an operation of its own: it runs inside the
/// ingest that ticks the clock. The raw values are the ones `brain_applications.operation` stores.
public enum BrainOperation: String, Sendable, Equatable, Hashable, CaseIterable {
    case observe
    case record
    case setName = "set_name"
}

/// BrainApplicationKey names one decision of the brain about one fact: an observation by the
/// event, phase and ordinal of the real sample it comes from, a record or a naming by the event of
/// the call. Two samples of one event are two applications; the same key offered again is the same
/// application. Nothing in the key comes from content, a digest, a clock or an identifier drawn at
/// retry, and the algorithm's version is not part of it: a new version does not re-apply an event.
///
/// Two keys are one only when their event ids are the same bytes and their operation, phase and
/// ordinal match: the identity the file's binary TEXT keys hold. Swift's own `String` equality would
/// make two canonically equivalent ids, two rows in the file, one key here; the event id is never
/// normalized, so the key's equality and hashing read its UTF-8.
public struct BrainApplicationKey: Sendable, Equatable, Hashable {

    public let eventID: String
    public let operation: BrainOperation

    /// The sample of an observation; nil for a record or a naming.
    public let sample: CaptureSampleKey?

    private init(eventID: String, operation: BrainOperation, sample: CaptureSampleKey?) {
        self.eventID   = eventID
        self.operation = operation
        self.sample    = sample
    }

    public static func observe(_ sample: CaptureSampleKey) -> BrainApplicationKey {
        BrainApplicationKey(eventID: sample.eventID, operation: .observe, sample: sample)
    }

    public static func record(eventID: String) -> BrainApplicationKey {
        BrainApplicationKey(eventID: eventID, operation: .record, sample: nil)
    }

    public static func setName(eventID: String) -> BrainApplicationKey {
        BrainApplicationKey(eventID: eventID, operation: .setName, sample: nil)
    }

    public static func == (lhs: BrainApplicationKey, rhs: BrainApplicationKey) -> Bool {
        lhs.operation == rhs.operation && lhs.sample?.phase == rhs.sample?.phase && lhs.sample?.ordinal == rhs.sample?.ordinal
            && lhs.eventID.utf8.elementsEqual(rhs.eventID.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(operation)
        hasher.combine(sample?.phase)
        hasher.combine(sample?.ordinal)
        hasher.combine(eventID.utf8.count)
        for byte in eventID.utf8 { hasher.combine(byte) }
    }

    /// A readable name of the key for reports: event, operation, and phase and ordinal when present.
    public var identity: String {
        var parts = ["brain", eventID, operation.rawValue]
        if let sample { parts += [sample.phase.rawValue, String(sample.ordinal)] }
        return parts.joined(separator: ":")
    }
}

/// BrainApplicationCommand is an application as the brain is asked for it, normalized once: the
/// key, the application's bundle id, the requested instant as a canonical millisecond, and every
/// input the current algorithm reads, in its order and type. It is what is stored and what a retry
/// is compared against, exactly; building it is the one place values are derived (the detections
/// of a scene, its title's letter family, the effect's typed columns), and nothing is derived again
/// on the way back.
public struct BrainApplicationCommand: Sendable {

    /// Input is what the algorithm reads for each operation.
    public enum Input: Sendable {

        /// Every detection of the scene, pixel-only and unlabeled included, in scene order, and the
        /// window family the ingest is scoped to (nil for no scope).
        case observe(window: String?, detections: [BrainDetection])

        /// The action's verb, the detection of its target and its typed effect, nil for none.
        case record(verb: ActionVerb, target: BrainDetection, effect: TransitionEffectRecord?)

        /// The anchor named and the name as given; the algorithm trims it.
        case setName(anchorKey: String, name: String)
    }

    public let key: BrainApplicationKey
    public let bundleID: String
    public let requestedAtMS: Int64
    public let input: Input

    /// A command from its parts, validated: an identity, a bundle id, a non-negative ordinal, an
    /// instant inside `BrainClock.range` and finite bounds; the input must be the key's operation's.
    public init(key: BrainApplicationKey, bundleID: String, requestedAtMS: Int64, input: Input) throws {
        guard !key.eventID.isEmpty else { throw BrainApplicationError.invalidCommand(.emptyEventID) }
        guard !bundleID.isEmpty else { throw BrainApplicationError.invalidCommand(.emptyBundleID) }
        if let sample = key.sample, sample.ordinal < 0 { throw BrainApplicationError.invalidCommand(.negativeOrdinal) }
        guard BrainClock.range.contains(requestedAtMS) else {
            throw BrainProjectionError.clock(.millisecondsOutOfRange(requestedAtMS))
        }
        switch (key.operation, input) {
            case (.observe, .observe(_, let detections)):
                for (position, detection) in detections.enumerated() {
                    try Self.requireFinite(detection, prefix: "detection", position: position)
                }
            case (.record, .record(_, let target, _)):
                try Self.requireFinite(target, prefix: "target", position: 0)
            case (.setName, .setName):
                break
            default:
                throw BrainApplicationError.invalidCommand(.inputDoesNotMatchOperation)
        }
        self.key           = key
        self.bundleID      = bundleID
        self.requestedAtMS = requestedAtMS
        self.input         = input
    }

    private static func requireFinite(_ detection: BrainDetection, prefix: String, position: Int) throws {
        let bounds = detection.bounds
        for (name, value) in [("x", bounds.x), ("y", bounds.y), ("width", bounds.width), ("height", bounds.height)]
        where !value.isFinite {
            throw BrainApplicationError.invalidCommand(.nonFiniteBounds(argument: "\(prefix)_\(name)", position: position))
        }
    }

    // MARK: Normalizing a call

    /// The observation of a scene as `BrainMemory.observe` ingests it: every element as a
    /// `BrainDetection`, scoped to `LabelText.letters(windowTitle)`, the empty family being no
    /// scope. `sample` names the real sample the scene was captured as.
    public static func observe(_ scene: SceneSnapshot, sample: CaptureSampleKey, requestedAt: Date) throws -> BrainApplicationCommand {
        let window = LabelText.letters(scene.windowTitle)
        return try observe(
            detections: scene.elements.map(BrainDetection.init), window: window.isEmpty ? nil : window,
            bundleID: scene.bundleID, sample: sample, requestedAt: requestedAt
        )
    }

    /// An observation of detections already made, with the window family the ingest uses.
    public static func observe(
        detections : [BrainDetection],
        window     : String?,
        bundleID   : String,
        sample     : CaptureSampleKey,
        requestedAt: Date
    ) throws -> BrainApplicationCommand {
        try BrainApplicationCommand(
            key: .observe(sample), bundleID: bundleID, requestedAtMS: try canonical(requestedAt),
            input: .observe(window: window, detections: detections)
        )
    }

    /// What an action taught, as `BrainMemory.record` reads it: the verb, the target element's
    /// detection and the effect, which must be one the projection can store and rebuild.
    public static func record(_ record: ActionRecord, eventID: String, requestedAt: Date) throws -> BrainApplicationCommand {
        try BrainApplicationCommand(
            key: .record(eventID: eventID), bundleID: record.bundleID, requestedAtMS: try canonical(requestedAt),
            input: .record(verb: record.verb, target: BrainDetection(record.element),
                           effect: try record.effect.map { try TransitionEffectRecord(effect: $0.encoded) })
        )
    }

    /// A deliberate naming, as `BrainUpdater.setName` takes it.
    public static func setName(
        _ name     : String,
        anchorKey  : String,
        in bundleID: String,
        eventID    : String,
        requestedAt: Date
    ) throws -> BrainApplicationCommand {
        try BrainApplicationCommand(
            key: .setName(eventID: eventID), bundleID: bundleID, requestedAtMS: try canonical(requestedAt),
            input: .setName(anchorKey: anchorKey, name: name)
        )
    }

    private static func canonical(_ date: Date) throws -> Int64 {
        do { return try BrainClock.milliseconds(of: date) } catch let problem as BrainClock.Problem {
            throw BrainProjectionError.clock(problem)
        }
    }

    // MARK: Exact comparison

    /// Whether the other command is this one exactly: the same key (its event id byte for byte),
    /// bundle id, requested instant and arguments, texts compared byte for byte (no Unicode
    /// equivalence, a NUL or a separator is content, empty text is not absence), numbers as IEEE
    /// values (so `-0.0` and `0.0` are one number, as SQLite reads them back), lists in order.
    /// This, never a digest, decides `alreadyApplied` apart from a conflict.
    public func hasSameInput(as other: BrainApplicationCommand) -> Bool {
        key == other.key && Array(bundleID.utf8) == Array(other.bundleID.utf8) && requestedAtMS == other.requestedAtMS
            && BrainArgument.exactlyEqual(arguments, other.arguments)
    }

    /// A digest of the command for diagnostics and conflict reports, never the decision.
    public var inputDigest: String {
        var parts = [key.identity, CanonicalText.field(bundleID), String(requestedAtMS)]
        for argument in arguments { parts.append(argument.canonical) }
        return StructuralDigest.fnv1a(parts.joined(separator: "\u{1E}"))
    }
}

/// BrainApplicationOutcome is what a concluded application decided, as it is stored and answered
/// again at every retry: an observation's essential counts; a record that taught nothing because
/// it carried no effect, or because its element had no unique anchor; a recorded transition with
/// its anchor, row and the evidence it reached; a naming that took or did not. The decay an ingest
/// ran is not part of it: its report belongs to the raw projection and its tests.
public enum BrainApplicationOutcome: Sendable, Equatable {
    case observed(created: Int, updated: Int, skippedAmbiguous: Int)
    case noEffect
    case noAnchor
    case recorded(anchorKey: String, transitionID: String, evidence: Int)
    case named(anchorKey: String)
    case notNamed

    /// The code `brain_applications.outcome` stores.
    public var code: String {
        switch self {
            case .observed : "observed"
            case .noEffect : "no_effect"
            case .noAnchor : "no_anchor"
            case .recorded : "recorded"
            case .named    : "named"
            case .notNamed : "not_named"
        }
    }

    /// Whether the outcome is one the operation can have.
    public func belongs(to operation: BrainOperation) -> Bool {
        switch (operation, self) {
            case (.observe, .observed), (.record, .noEffect), (.record, .noAnchor), (.record, .recorded),
                 (.setName, .named), (.setName, .notNamed): true
            default: false
        }
    }
}

/// BrainApplicationResult is the answer to an application, given only after its commit: whether it
/// was applied now or already, the stored outcome, and the two instants it was asked for and run at.
public struct BrainApplicationResult: Sendable, Equatable {

    public let receipt: MemoryReceipt
    public let applicationID: Int64
    public let outcome: BrainApplicationOutcome
    public let requestedAtMS: Int64

    /// The instant the algorithm ran at: never earlier than the application's own clock already was.
    public let effectiveAtMS: Int64

    public init(receipt: MemoryReceipt, applicationID: Int64, outcome: BrainApplicationOutcome,
                requestedAtMS: Int64, effectiveAtMS: Int64) {
        self.receipt       = receipt
        self.applicationID = applicationID
        self.outcome       = outcome
        self.requestedAtMS = requestedAtMS
        self.effectiveAtMS = effectiveAtMS
    }
}

/// BrainApplication is a concluded application read back: its command, rebuilt from the stored
/// arguments, the versions it was decided under, the instant it ran at and its outcome.
public struct BrainApplication: Sendable {

    public let applicationID: Int64
    public let command: BrainApplicationCommand
    public let contractVersion: Int
    public let algorithmVersion: String
    public let effectiveAtMS: Int64
    public let outcome: BrainApplicationOutcome

    public init(applicationID: Int64, command: BrainApplicationCommand, contractVersion: Int, algorithmVersion: String,
                effectiveAtMS: Int64, outcome: BrainApplicationOutcome) {
        self.applicationID    = applicationID
        self.command          = command
        self.contractVersion  = contractVersion
        self.algorithmVersion = algorithmVersion
        self.effectiveAtMS    = effectiveAtMS
        self.outcome          = outcome
    }
}

/// BrainApplicationError is what the application contract refuses: a command no store should be
/// asked to apply, a reference the store does not hold or that names another application, and a
/// stored application whose header or arguments break the contract. Every case is a refusal; the
/// cases carry identifiers and argument names, never a label or a name.
public enum BrainApplicationError: Error, Sendable, Equatable {

    case invalidCommand(Invalidity)

    /// The event the key names is not stored.
    case missingEvent(eventID: String)

    /// The event names no application.
    case eventWithoutApp(eventID: String)

    /// The event belongs to another application than the command's.
    case eventOfAnotherApplication(eventID: String)

    /// A record or a naming names an event that is not an action.
    case eventIsNotAnAction(eventID: String)

    /// An observation names a sample the store does not hold.
    case missingSample(CaptureSampleKey)

    /// A stored application's contract version this build has no decoder for.
    case unsupportedContractVersion(Int)

    /// A stored application breaks the contract.
    case malformedApplication(applicationID: Int64, malformation: Malformation)

    /// Invalidity says why a command was refused before any transaction.
    public enum Invalidity: Sendable, Equatable {
        case emptyEventID
        case emptyBundleID
        case negativeOrdinal
        case inputDoesNotMatchOperation
        case nonFiniteBounds(argument: String, position: Int)

        /// A record whose target named no element: there is nothing to anchor an effect to.
        case noTarget
    }

    /// Malformation says which rule a stored application breaks.
    public enum Malformation: Sendable, Equatable {
        case unknownOperation(String)
        case unknownOutcome(String)
        case unknownPhase(String)
        case outcomeShape(String)
        case missingArgument(String)
        case forbiddenArgument(String)
        case duplicateArgument(String, position: Int)
        case argumentKindMismatch(String)
        case positionsNotContiguous(String)
        case unknownCode(argument: String, code: String)
        case nonFiniteArgument(String, position: Int)
        case forbiddenColumn(String)

        /// An observation's `detection_count` that the detections received do not match: the
        /// count is checked against the rows before anything is sized by it.
        case detectionCount(declared: Int64, found: Int)
    }
}

/// BrainApplicationContract is the versioned contract of an application's stored arguments: the
/// names each operation admits, the type and cardinality of each, and the versions an application
/// is decided under. Version 1:
///
/// - observe: `detection_count` (integer, one); `window` (text, at most one; absent is nil); per
///   detection at positions 0 ..< count: `detection_kind`, `detection_label` (text, one each; the
///   empty label is a label), `detection_x`, `detection_y`, `detection_width`, `detection_height`
///   (real, one each), `detection_state` (text, at most one; absent is nil).
/// - record: `verb` (text, one); `target_kind`, `target_label`, `target_x`, `target_y`,
///   `target_width`, `target_height` (one each), `target_state` (at most one); `effect_kind` (at
///   most one; absent is no effect), `effect_text`, `effect_required_state`,
///   `effect_resulting_state` (at most one each, only with a kind), `effect_item` (text, a list at
///   positions 0, 1, ...).
/// - set_name: `anchor_key` (text, one; a literal: it need not name a stored anchor), `name`
///   (text, one).
///
/// Every scalar sits at position 0. Any other name, a value of another type, a duplicate, a gap in
/// a list or a value outside a vocabulary is refused on the way in and on the way out.
public enum BrainApplicationContract {

    /// The contract version of the arguments.
    public static let version = 1

    /// The algorithm the applications of this build are decided by: `BrainUpdater` as it is.
    public static let algorithmVersion = "brain-updater-1"

    /// Cardinality is how many rows an argument has.
    public enum Cardinality: Sendable, Equatable {
        case one, optional, perDetection, optionalPerDetection, list
    }

    /// ArgumentSpec is one admitted argument.
    public struct ArgumentSpec: Sendable, Equatable {
        public let name: String
        public let kind: BrainArgument.Kind
        public let cardinality: Cardinality
    }

    /// The admitted arguments of an operation, in their stored order.
    public static func arguments(of operation: BrainOperation) -> [ArgumentSpec] {
        func spec(_ name: String, _ kind: BrainArgument.Kind, _ cardinality: Cardinality) -> ArgumentSpec {
            ArgumentSpec(name: name, kind: kind, cardinality: cardinality)
        }
        switch operation {
            case .observe:
                return [
                    spec("detection_count", .integer, .one), spec("window", .text, .optional),
                    spec("detection_kind", .text, .perDetection), spec("detection_label", .text, .perDetection),
                    spec("detection_x", .real, .perDetection), spec("detection_y", .real, .perDetection),
                    spec("detection_width", .real, .perDetection), spec("detection_height", .real, .perDetection),
                    spec("detection_state", .text, .optionalPerDetection),
                ]
            case .record:
                return [
                    spec("verb", .text, .one), spec("target_kind", .text, .one), spec("target_label", .text, .one),
                    spec("target_x", .real, .one), spec("target_y", .real, .one), spec("target_width", .real, .one),
                    spec("target_height", .real, .one), spec("target_state", .text, .optional),
                    spec("effect_kind", .text, .optional), spec("effect_text", .text, .optional),
                    spec("effect_required_state", .text, .optional), spec("effect_resulting_state", .text, .optional),
                    spec("effect_item", .text, .list),
                ]
            case .setName:
                return [spec("anchor_key", .text, .one), spec("name", .text, .one)]
        }
    }
}

/// BrainArgument is one stored argument of an application: a name, a position and one typed value.
public struct BrainArgument: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable { case text, integer, real, boolean }

    public enum Value: Sendable, Equatable {
        case text(String), integer(Int64), real(Double), boolean(Bool)

        public var kind: Kind {
            switch self {
                case .text   : .text
                case .integer: .integer
                case .real   : .real
                case .boolean: .boolean
            }
        }
    }

    public let name: String
    public let position: Int
    public let value: Value

    public init(name: String, position: Int, value: Value) {
        self.name     = name
        self.position = position
        self.value    = value
    }

    /// Two argument lists are the same exactly: same length, and pairwise the same name and
    /// position and the same value, a text byte for byte and a number as an IEEE value.
    static func exactlyEqual(_ lhs: [BrainArgument], _ rhs: [BrainArgument]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.name == right.name, left.position == right.position else { return false }
            switch (left.value, right.value) {
                case (.text(let a), .text(let b))      : guard Array(a.utf8) == Array(b.utf8) else { return false }
                case (.integer(let a), .integer(let b)): guard a == b else { return false }
                case (.real(let a), .real(let b))      : guard a == b else { return false }
                case (.boolean(let a), .boolean(let b)): guard a == b else { return false }
                default                                : return false
            }
        }
        return true
    }

    /// The argument as one canonical text for a digest: name, position, kind and the value with its
    /// length, or a number as its exact bits.
    var canonical: String {
        let rendered: String
        switch value {
            case .text(let text)    : rendered = CanonicalText.field(text)
            case .integer(let value): rendered = String(value)
            case .real(let value)   : rendered = String(value.bitPattern, radix: 16)
            case .boolean(let flag) : rendered = flag ? "1" : "0"
        }
        return "\(name)@\(position)=\(value.kind.rawValue):\(rendered)"
    }
}

extension BrainApplicationCommand {

    // MARK: Arguments

    /// The command's input as the contract's arguments, in the contract's order: by spec, then by
    /// position. What the store writes and what a retry is compared on.
    public var arguments: [BrainArgument] {
        var rows: [BrainArgument] = []
        func add(_ name: String, _ position: Int, _ value: BrainArgument.Value) {
            rows.append(BrainArgument(name: name, position: position, value: value))
        }
        func detection(_ prefix: String, _ detection: BrainDetection, at position: Int, into sink: inout [String: [BrainArgument]]) {
            func put(_ suffix: String, _ value: BrainArgument.Value) {
                sink["\(prefix)_\(suffix)", default: []].append(BrainArgument(name: "\(prefix)_\(suffix)", position: position, value: value))
            }
            put("kind", .text(detection.kind.rawValue))
            put("label", .text(detection.label))
            put("x", .real(detection.bounds.x))
            put("y", .real(detection.bounds.y))
            put("width", .real(detection.bounds.width))
            put("height", .real(detection.bounds.height))
            if let state = detection.state { put("state", .text(state.rawValue)) }
        }
        var byName: [String: [BrainArgument]] = [:]
        switch input {
            case .observe(let window, let detections):
                add("detection_count", 0, .integer(Int64(detections.count)))
                if let window { add("window", 0, .text(window)) }
                for (position, item) in detections.enumerated() { detection("detection", item, at: position, into: &byName) }
            case .record(let verb, let target, let effect):
                add("verb", 0, .text(verb.rawValue))
                detection("target", target, at: 0, into: &byName)
                if let effect {
                    add("effect_kind", 0, .text(effect.kind))
                    if let text = effect.text { add("effect_text", 0, .text(text)) }
                    if let state = effect.requiredState { add("effect_required_state", 0, .text(state.rawValue)) }
                    if let state = effect.resultingState { add("effect_resulting_state", 0, .text(state.rawValue)) }
                    for (position, item) in effect.items.enumerated() { add("effect_item", position, .text(item)) }
                }
            case .setName(let anchorKey, let name):
                add("anchor_key", 0, .text(anchorKey))
                add("name", 0, .text(name))
        }
        for argument in rows { byName[argument.name, default: []].append(argument) }
        return BrainApplicationContract.arguments(of: key.operation).flatMap { byName[$0.name] ?? [] }
    }

    /// The command rebuilt from stored arguments, refusing every argument the contract does not
    /// admit for the key's operation and every gap, duplicate, type or code it does not know.
    /// `applicationID` names the stored row in the refusal.
    public init(
        key          : BrainApplicationKey,
        bundleID     : String,
        requestedAtMS: Int64,
        arguments    : [BrainArgument],
        applicationID: Int64
    ) throws {
        func refuse(_ malformation: BrainApplicationError.Malformation) -> BrainApplicationError {
            .malformedApplication(applicationID: applicationID, malformation: malformation)
        }
        let specs = Dictionary(uniqueKeysWithValues: BrainApplicationContract.arguments(of: key.operation).map { ($0.name, $0) })
        var byName: [String: [Int: BrainArgument.Value]] = [:]
        for argument in arguments {
            guard let spec = specs[argument.name] else { throw refuse(.forbiddenArgument(argument.name)) }
            guard argument.value.kind == spec.kind else { throw refuse(.argumentKindMismatch(argument.name)) }
            guard byName[argument.name]?[argument.position] == nil else {
                throw refuse(.duplicateArgument(argument.name, position: argument.position))
            }
            if case .real(let value) = argument.value, !value.isFinite {
                throw refuse(.nonFiniteArgument(argument.name, position: argument.position))
            }
            byName[argument.name, default: [:]][argument.position] = argument.value
        }
        func scalar(_ name: String) throws -> BrainArgument.Value? {
            guard let values = byName[name] else { return nil }
            guard values.keys.sorted() == [0] else { throw refuse(.positionsNotContiguous(name)) }
            return values[0]
        }
        func text(_ name: String) throws -> String? {
            if case .text(let value)? = try scalar(name) { return value }
            return nil
        }
        func required(_ name: String) throws -> String {
            guard let value = try text(name) else { throw refuse(.missingArgument(name)) }
            return value
        }
        func real(_ name: String, _ position: Int) throws -> Double {
            guard case .real(let value)? = byName[name]?[position] else { throw refuse(.missingArgument(name)) }
            return value
        }
        func list(_ name: String) throws -> [String] {
            let values = byName[name] ?? [:]
            guard values.keys.sorted() == Array(0..<values.count) else { throw refuse(.positionsNotContiguous(name)) }
            return try (0..<values.count).map { position in
                guard case .text(let value)? = values[position] else { throw refuse(.argumentKindMismatch(name)) }
                return value
            }
        }
        func code<T: RawRepresentable>(_ type: T.Type, _ name: String, _ raw: String) throws -> T where T.RawValue == String {
            guard let known = T(rawValue: raw) else { throw refuse(.unknownCode(argument: name, code: raw)) }
            return known
        }
        func detection(_ prefix: String, at position: Int, single: Bool) throws -> BrainDetection {
            func textAt(_ suffix: String) -> String? {
                if case .text(let value)? = byName["\(prefix)_\(suffix)"]?[position] { return value }
                return nil
            }
            guard let kindCode = textAt("kind") else { throw refuse(.missingArgument("\(prefix)_kind")) }
            guard let label = textAt("label") else { throw refuse(.missingArgument("\(prefix)_label")) }
            let bounds = NormalizedRect(
                x: try real("\(prefix)_x", position), y: try real("\(prefix)_y", position),
                width: try real("\(prefix)_width", position), height: try real("\(prefix)_height", position)
            )
            let state = try textAt("state").map { try code(ControlState.self, "\(prefix)_state", $0) }
            return BrainDetection(kind: try code(ElementKind.self, "\(prefix)_kind", kindCode), label: label, bounds: bounds, state: state)
        }
        let input: Input
        switch key.operation {
            case .observe:
                // The declared count is a stored value, not a size: it must name the detections the
                // rows hold before anything is allocated or iterated for it, so a count no row
                // supports is refused whatever its magnitude, and only `found`, bounded by the rows,
                // sizes the rest.
                guard case .integer(let declared)? = try scalar("detection_count") else { throw refuse(.missingArgument("detection_count")) }
                let found = byName["detection_kind"]?.count ?? 0
                guard declared == Int64(found) else { throw refuse(.detectionCount(declared: declared, found: found)) }
                for spec in BrainApplicationContract.arguments(of: .observe) where spec.cardinality != .one && spec.cardinality != .optional {
                    let positions = (byName[spec.name] ?? [:]).keys
                    let inRange = positions.allSatisfy { (0..<found).contains($0) }
                    if spec.cardinality == .perDetection, !inRange || positions.count != found { throw refuse(.positionsNotContiguous(spec.name)) }
                    if spec.cardinality == .optionalPerDetection, !inRange { throw refuse(.positionsNotContiguous(spec.name)) }
                }
                input = .observe(
                    window: try text("window"),
                    detections: try (0..<found).map { try detection("detection", at: $0, single: false) }
                )
            case .record:
                for name in ["target_kind", "target_label", "target_x", "target_y", "target_width", "target_height", "target_state"] {
                    _ = try scalar(name)
                }
                let verb = try code(ActionVerb.self, "verb", try required("verb"))
                let target = try detection("target", at: 0, single: true)
                var effect: TransitionEffectRecord?
                if let kind = try text("effect_kind") {
                    effect = try TransitionEffectRecord(
                        kind: kind, text: try text("effect_text"), requiredState: try text("effect_required_state"),
                        resultingState: try text("effect_resulting_state"), items: try list("effect_item")
                    )
                } else {
                    for name in ["effect_text", "effect_required_state", "effect_resulting_state", "effect_item"] where byName[name] != nil {
                        throw refuse(.forbiddenArgument(name))
                    }
                }
                input = .record(verb: verb, target: target, effect: effect)
            case .setName:
                input = .setName(anchorKey: try required("anchor_key"), name: try required("name"))
        }
        try self.init(key: key, bundleID: bundleID, requestedAtMS: requestedAtMS, input: input)
    }
}
