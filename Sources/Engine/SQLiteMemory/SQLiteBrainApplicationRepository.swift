//
//  SQLiteBrainApplicationRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteBrainApplicationRepository is `BrainApplicationStoring` over `SQLiteMemoryStore`: the
/// path a producer applies an observation, a record or a naming through, once per key. Everything
/// happens inside one `store.write`, one `BEGIN IMMEDIATE`, with no `await` inside:
///
/// 1. the event the key names is read: it must exist, belong to the command's application and, for
///    a record or a naming, be an action;
/// 2. the key is looked up in `brain_applications`; a concluded application answers its stored
///    outcome when the offered command is exactly the stored one (key, bundle id, requested
///    instant, contract and algorithm versions, every argument byte for byte), and is a
///    `MemoryStoreError.identity` conflict otherwise, with nothing changed;
/// 3. a new application: the sample of an observation must be a stored capture row; the projection
///    is loaded under the same lock; the effective instant is fixed as the latest of the requested
///    one, the application's last effective instant and every instant the active projection holds;
///    the current algorithm runs at it through `SQLiteBrainRows.mutate`, the body the raw
///    repository uses; the difference, the `brain_evidence` links the algorithm's own counters
///    justify, the arguments and, last, the application row that seals them are written.
///
/// An application that changed nothing (no effect, no anchor, an empty ingest, an unknown anchor
/// named) is concluded and answered like any other. A failure rolls the transaction back whole: no
/// application, argument, evidence or difference is left, and offering the same command again
/// applies it once. A busy lock re-runs the body on the rows it then reads: SQL and pure work only,
/// never an action of the interface.
public struct SQLiteBrainApplicationRepository: BrainApplicationStoring {

    private let store: SQLiteMemoryStore
    private let keys: BrainKeys
    private let makeTransitionID: @Sendable () -> String
    private let makeSceneID: @Sendable () -> String
    private let algorithmVersion: String

    /// `algorithmVersion` is the version this build decides under, recorded with each application;
    /// a test supplies another to prove that a new version does not re-apply a concluded key.
    public init(
        store           : SQLiteMemoryStore,
        keys            : BrainKeys = .random,
        makeTransitionID: @escaping @Sendable () -> String = { UUID().uuidString },
        makeSceneID     : @escaping @Sendable () -> String = { UUID().uuidString },
        algorithmVersion: String = BrainApplicationContract.algorithmVersion
    ) {
        self.store            = store
        self.keys             = keys
        self.makeTransitionID = makeTransitionID
        self.makeSceneID      = makeSceneID
        self.algorithmVersion = algorithmVersion
    }

    public func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        let keys             = self.keys
        let makeTransitionID = self.makeTransitionID
        let makeSceneID      = self.makeSceneID
        let algorithmVersion = self.algorithmVersion
        return try await store.write { transaction in
            let appID = try SQLiteBrainApplicationRows.resolveApp(transaction, command: command)
            if let stored = try SQLiteBrainApplicationRows.header(transaction, key: command.key) {
                return try SQLiteBrainApplicationRows.retry(
                    transaction, stored: stored, offered: command, algorithmVersion: algorithmVersion
                )
            }
            var sampleObservationID: Int64?
            if let sample = command.key.sample {
                guard let id = try SQLiteBrainApplicationRows.captureRow(transaction, sample: sample) else {
                    throw BrainApplicationError.missingSample(sample)
                }
                sampleObservationID = id
            }
            let loaded      = try SQLiteBrainRows.load(transaction, appID: appID)
            let effectiveMS = try SQLiteBrainApplicationRows.effectiveInstant(
                transaction, appID: appID, requestedMS: command.requestedAtMS, projection: loaded.brain
            )
            let effective   = try SQLiteBrainRows.date(effectiveMS)
            func mutate<T>(_ body: (inout UIBrain, Date) throws -> (T, DecayReport)) throws -> SQLiteBrainRows.Mutation<T> {
                try SQLiteBrainRows.mutate(
                    transaction, appID: appID, loaded: loaded, now: effective, nowMS: effectiveMS,
                    makeTransitionID: makeTransitionID, makeSceneID: makeSceneID, body
                )
            }
            let outcome: BrainApplicationOutcome
            var supported = SQLiteBrainApplicationRows.Supported()
            switch command.input {
                case .observe(let window, let detections):
                    let mutation = try mutate { brain, now in
                        let stats = BrainUpdater.ingest(detections, into: &brain, now: now, window: window, keys: keys)
                        return (stats, stats.decay ?? DecayReport())
                    }
                    outcome = .observed(created: mutation.result.created, updated: mutation.result.updated,
                                        skippedAmbiguous: mutation.result.skippedAmbiguous)
                    supported = .observed(by: mutation)
                case .record(let verb, let target, let effect):
                    guard let effect else {
                        outcome = .noEffect
                        break
                    }
                    let trigger = TransitionTrigger(verb)
                    let mutation = try mutate { brain, now -> (BrainRecordOutcome, DecayReport) in
                        // BrainMemory.record, unchanged: a unique anchor, or a menu reveal anchored first.
                        var key: String?
                        var retired = DecayReport()
                        if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                        if key == nil, effect.kind == "menuOpened" {
                            retired = BrainUpdater.ingest([target], into: &brain, now: now, keys: keys).decay ?? DecayReport()
                            if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                        }
                        guard let key else { return (.noAnchor, retired) }
                        let evidence = BrainUpdater.recordTransition(
                            anchorKey: key, trigger: trigger, effect: effect.effect, into: &brain, now: now
                        )
                        return (.recorded(anchorKey: key, evidence: evidence), retired)
                    }
                    switch mutation.result {
                        case .recorded(let anchorKey, let evidence):
                            let transitionKey = LearnedTransition.Key(anchorKey: anchorKey, trigger: trigger, effect: effect.effect)
                            guard let transitionID = mutation.transitionIDs[transitionKey] else {
                                throw BrainProjectionError.malformedRow(
                                    table: "brain_transitions", id: anchorKey, malformation: .missingColumn("transition_id"))
                            }
                            outcome = .recorded(anchorKey: anchorKey, transitionID: transitionID, evidence: evidence)
                        case .noAnchor, .noEffect:
                            outcome = .noAnchor
                    }
                    supported = .recorded(by: mutation)
                case .setName(let anchorKey, let name):
                    let mutation = try mutate { brain, now in
                        (BrainUpdater.setName(name, anchorKey: anchorKey, into: &brain, now: now), DecayReport())
                    }
                    outcome = mutation.result ? .named(anchorKey: anchorKey) : .notNamed
            }
            try SQLiteBrainApplicationRows.writeEvidence(
                transaction, appID: appID, eventID: command.key.eventID, supported: supported,
                assessedBy: "brain.\(command.key.operation.rawValue)", version: algorithmVersion, atMS: effectiveMS
            )
            let applicationID = try SQLiteBrainApplicationRows.insert(
                transaction, appID: appID, command: command, sampleObservationID: sampleObservationID,
                algorithmVersion: algorithmVersion, effectiveMS: effectiveMS, outcome: outcome
            )
            return BrainApplicationResult(
                receipt: .committed, applicationID: applicationID, outcome: outcome,
                requestedAtMS: command.requestedAtMS, effectiveAtMS: effectiveMS
            )
        }
    }

    public func application(_ key: BrainApplicationKey) async throws -> BrainApplication? {
        try await store.read { snapshot in
            guard let stored = try SQLiteBrainApplicationRows.header(snapshot, key: key) else { return nil }
            return try SQLiteBrainApplicationRows.application(snapshot, stored: stored)
        }
    }
}

/// SQLiteBrainApplicationRows is the codec of `brain_applications` and of the arguments it owns in
/// `memory_operation_arguments`, and the writer of the evidence an application justifies. Always
/// inside the caller's transaction or snapshot.
enum SQLiteBrainApplicationRows {

    /// Header is one stored application row, every column by name.
    struct Header {
        let applicationID: Int64
        let appID: Int64
        let bundleID: String
        let key: BrainApplicationKey
        let sampleObservationID: Int64?
        let contractVersion: Int
        let algorithmVersion: String
        let requestedAtMS: Int64
        let effectiveAtMS: Int64
        let outcome: BrainApplicationOutcome
    }

    // MARK: References

    /// The application the command's event belongs to, refusing a missing event, an event with no
    /// application or another application's, and a record or a naming of an event that is no action.
    static func resolveApp(_ transaction: SQLiteTransaction, command: BrainApplicationCommand) throws -> Int64 {
        let eventID = command.key.eventID
        guard let event = try SQLiteEventRows.read(transaction, eventID: eventID) else {
            throw BrainApplicationError.missingEvent(eventID: eventID)
        }
        guard let app = event.app else { throw BrainApplicationError.eventWithoutApp(eventID: eventID) }
        guard Array(app.bundleID.utf8) == Array(command.bundleID.utf8) else {
            throw BrainApplicationError.eventOfAnotherApplication(eventID: eventID)
        }
        if command.key.operation != .observe, event.kind != .action {
            throw BrainApplicationError.eventIsNotAnAction(eventID: eventID)
        }
        guard let appID = try SQLiteIdentityRows.appID(transaction, bundleID: app.bundleID) else {
            throw BrainApplicationError.eventWithoutApp(eventID: eventID)
        }
        return appID
    }

    /// The capture row of a sample, or nil when the store holds none.
    static func captureRow(_ transaction: SQLiteTransaction, sample: CaptureSampleKey) throws -> Int64? {
        try transaction.query(
            """
            SELECT observation_id FROM memory_event_observations
            WHERE event_id = ? AND phase = ? AND sample_ordinal = ? AND observation_kind = 'capture'
            """,
            [.text(sample.eventID), .text(sample.phase.rawValue), .integer(Int64(sample.ordinal))]
        ) { $0.integer(0) }.first ?? nil
    }

    // MARK: The application's clock

    /// The instant a new application runs at: the latest of the requested instant, the last
    /// effective instant of the application's concluded applications, and every instant the active
    /// projection holds (anchors' first and last sightings, groups' last sightings, transitions'
    /// last observations, the clock's last tick), so that nothing the algorithm writes can be
    /// earlier than a stored instant it sits beside. No millisecond is added: the same instant is
    /// the same instant.
    static func effectiveInstant(
        _ transaction: SQLiteTransaction,
        appID        : Int64,
        requestedMS  : Int64,
        projection   : UIBrain
    ) throws -> Int64 {
        let lastEffective = try transaction.query(
            "SELECT max(effective_at_ms) FROM brain_applications WHERE app_id = ?", [.integer(appID)]
        ) { $0.integer(0) }.first ?? nil
        var instants: [Date] = projection.objects.flatMap { [$0.firstSeen, $0.lastSeen] }
        instants += projection.groups.map(\.lastSeen)
        instants += projection.transitions.map(\.lastObserved)
        if let advance = projection.lastEpochAdvance { instants.append(advance) }
        var effective = max(requestedMS, lastEffective ?? requestedMS)
        for instant in instants { effective = max(effective, try SQLiteBrainRows.milliseconds(of: instant)) }
        return effective
    }

    // MARK: Evidence

    /// Supported is what an application's evidence names: the rows whose own counters the algorithm
    /// moved, or that it created and kept. A refresh of an ambiguous candidate (its date only), a
    /// menu revealer's epoch, a naming and a record without effect or anchor move no counter and
    /// name nothing; a row created and dropped in the same mutation has no row to name.
    struct Supported {
        var anchors: [String] = []
        var groups: [UUID] = []
        var transitions: [String] = []

        /// An observation supports the anchors it created or saw again and the groups it created or merged.
        static func observed(by mutation: SQLiteBrainRows.Mutation<BrainUpdater.IngestStats>) -> Supported {
            Supported(anchors: anchors(of: mutation.before.brain, mutation.after), groups: groups(of: mutation.before.brain, mutation.after))
        }

        /// A record supports the transition whose evidence it created or raised, and the anchor a
        /// menu reveal created for it.
        static func recorded(by mutation: SQLiteBrainRows.Mutation<BrainRecordOutcome>) -> Supported {
            let before = Dictionary(mutation.before.brain.transitions.map { ($0.key, $0.evidence) }, uniquingKeysWith: { first, _ in first })
            let raised = mutation.after.transitions.filter { (before[$0.key] ?? 0) < $0.evidence }.compactMap { mutation.transitionIDs[$0.key] }
            return Supported(anchors: anchors(of: mutation.before.brain, mutation.after), transitions: raised)
        }

        private static func anchors(of before: UIBrain, _ after: UIBrain) -> [String] {
            let counts = Dictionary(before.objects.map { ($0.anchorKey, $0.seenCount) }, uniquingKeysWith: { first, _ in first })
            return after.objects.filter { anchor in counts[anchor.anchorKey].map { $0 < anchor.seenCount } ?? true }.map(\.anchorKey)
        }

        private static func groups(of before: UIBrain, _ after: UIBrain) -> [UUID] {
            let counts = Dictionary(before.groups.map { ($0.id, $0.seenCount) }, uniquingKeysWith: { first, _ in first })
            return after.groups.filter { group in counts[group.id].map { $0 < group.seenCount } ?? true }.map(\.id)
        }
    }

    /// Writes one `supports` link per supported row for the event, unless the event already
    /// supports that row: two samples of one event are not two independent proofs.
    static func writeEvidence(
        _ transaction: SQLiteTransaction,
        appID        : Int64,
        eventID      : String,
        supported    : Supported,
        assessedBy   : String,
        version      : String,
        atMS         : Int64
    ) throws {
        let targets = supported.anchors.map { ("anchor_id", $0) } + supported.groups.map { ("group_id", $0.uuidString) }
            + supported.transitions.map { ("transition_id", $0) }
        for (column, target) in targets {
            // Column names are this module's own literals.
            let present = try transaction.query(
                "SELECT count(*) FROM brain_evidence WHERE \(column) = ? AND event_id = ? AND relation = 'supports'",
                [.text(target), .text(eventID)]
            ) { $0.integer(0) ?? 0 }.first ?? 0
            guard present == 0 else { continue }
            try transaction.execute(
                """
                INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, \(column))
                VALUES (?, ?, 'supports', ?, ?, ?, ?)
                """,
                [.integer(appID), .text(eventID), .text(assessedBy), .text(version), .integer(atMS), .text(target)]
            )
        }
    }

    // MARK: Writing

    /// Writes the arguments, then the row that seals them, and answers the row's id, the next after
    /// every application of the file.
    static func insert(
        _ transaction      : SQLiteTransaction,
        appID              : Int64,
        command            : BrainApplicationCommand,
        sampleObservationID: Int64?,
        algorithmVersion   : String,
        effectiveMS        : Int64,
        outcome            : BrainApplicationOutcome
    ) throws -> Int64 {
        let id = (try transaction.query("SELECT coalesce(max(application_id), 0) + 1 FROM brain_applications", []) {
            $0.integer(0) ?? 1
        }.first ?? 1)
        for argument in command.arguments {
            var text: SQLiteValue = .null, integer: SQLiteValue = .null, real: SQLiteValue = .null, boolean: SQLiteValue = .null
            switch argument.value {
                case .text(let value)   : text = .text(value)
                case .integer(let value): integer = .integer(value)
                case .real(let value)   : real = .real(value)
                case .boolean(let value): boolean = .integer(value ? 1 : 0)
            }
            try transaction.execute(
                """
                INSERT INTO memory_operation_arguments
                    (brain_application_id, app_id, argument_name, position, value_kind,
                     text_value, integer_value, real_value, boolean_value)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.integer(id), .integer(appID), .text(argument.name), .integer(Int64(argument.position)),
                 .text(argument.value.kind.rawValue), text, integer, real, boolean]
            )
        }
        var created: SQLiteValue = .null, updated: SQLiteValue = .null, skipped: SQLiteValue = .null
        var anchor: SQLiteValue = .null, transitionID: SQLiteValue = .null, evidence: SQLiteValue = .null
        switch outcome {
            case .observed(let c, let u, let s):
                created = .integer(Int64(c)); updated = .integer(Int64(u)); skipped = .integer(Int64(s))
            case .recorded(let anchorKey, let transition, let count):
                anchor = .text(anchorKey); transitionID = .text(transition); evidence = .integer(Int64(count))
            case .named(let anchorKey):
                anchor = .text(anchorKey)
            case .noEffect, .noAnchor, .notNamed:
                break
        }
        let sample = command.key.sample
        try transaction.execute(
            """
            INSERT INTO brain_applications
                (application_id, app_id, event_id, operation, phase, sample_ordinal, sample_observation_id, sample_kind,
                 contract_version, algorithm_version, requested_at_ms, effective_at_ms, outcome,
                 created_count, updated_count, skipped_ambiguous_count, anchor_id, transition_id, evidence_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(id), .integer(appID), .text(command.key.eventID), .text(command.key.operation.rawValue),
                sample.map { .text($0.phase.rawValue) } ?? .null, sample.map { .integer(Int64($0.ordinal)) } ?? .null,
                sampleObservationID.map(SQLiteValue.integer) ?? .null, sample == nil ? .null : .text("capture"),
                .integer(Int64(BrainApplicationContract.version)), .text(algorithmVersion),
                .integer(command.requestedAtMS), .integer(effectiveMS), .text(outcome.code),
                created, updated, skipped, anchor, transitionID, evidence,
            ]
        )
        return id
    }

    // MARK: Retry

    /// Answers a concluded application offered again: its stored outcome when the command is the
    /// stored one exactly and was decided under the same versions, a conflict otherwise. The
    /// algorithm version is a text compared byte for byte, like every other text of the contract.
    static func retry(
        _ transaction   : SQLiteTransaction,
        stored          : Header,
        offered         : BrainApplicationCommand,
        algorithmVersion: String
    ) throws -> BrainApplicationResult {
        var same = stored.contractVersion == BrainApplicationContract.version
            && stored.algorithmVersion.utf8.elementsEqual(algorithmVersion.utf8)
        var storedDigest = "undecoded"
        if stored.contractVersion == BrainApplicationContract.version {
            let command = try command(transaction, stored: stored)
            storedDigest = command.inputDigest
            same = same && command.hasSameInput(as: offered)
        }
        guard same else {
            throw MemoryStoreError.identity(MemoryIdentityConflict(
                identity          : offered.key.identity,
                storedFingerprint : "v\(stored.contractVersion)/\(stored.algorithmVersion)/\(storedDigest)",
                offeredFingerprint: "v\(BrainApplicationContract.version)/\(algorithmVersion)/\(offered.inputDigest)"
            ))
        }
        return BrainApplicationResult(
            receipt: .alreadyApplied, applicationID: stored.applicationID, outcome: stored.outcome,
            requestedAtMS: stored.requestedAtMS, effectiveAtMS: stored.effectiveAtMS
        )
    }

    // MARK: Reading

    private static let headerColumns = """
        a.application_id, a.app_id, p.bundle_id, a.event_id, a.operation, a.phase, a.sample_ordinal,
        a.sample_observation_id, a.sample_kind, a.contract_version, a.algorithm_version, a.requested_at_ms,
        a.effective_at_ms, a.outcome, a.created_count, a.updated_count, a.skipped_ambiguous_count, a.anchor_id,
        a.transition_id, a.evidence_count
        """

    /// The stored application under a key, or nil.
    static func header(_ handle: some SQLiteQuerying, key: BrainApplicationKey) throws -> Header? {
        let filter: String
        var bindings: [SQLiteValue] = [.text(key.eventID)]
        if let sample = key.sample {
            filter = "a.operation = 'observe' AND a.phase = ? AND a.sample_ordinal = ?"
            bindings += [.text(sample.phase.rawValue), .integer(Int64(sample.ordinal))]
        } else {
            filter = "a.operation = ?"
            bindings.append(.text(key.operation.rawValue))
        }
        let rows = try handle.query(
            "SELECT \(headerColumns) FROM brain_applications a JOIN brain_apps p ON p.app_id = a.app_id WHERE a.event_id = ? AND \(filter)",
            bindings
        ) { row in try header(row) }
        return rows.first
    }

    private static func header(_ row: SQLiteStatement.Row) throws -> Header {
        let id = row.integer(0) ?? 0
        func refuse(_ malformation: BrainApplicationError.Malformation) -> BrainApplicationError {
            .malformedApplication(applicationID: id, malformation: malformation)
        }
        let eventID = try row.text(3) ?? ""
        let operationCode = try row.text(4) ?? ""
        guard let operation = BrainOperation(rawValue: operationCode) else { throw refuse(.unknownOperation(operationCode)) }
        let key: BrainApplicationKey
        switch operation {
            case .observe:
                let phaseCode = try row.text(5) ?? ""
                guard let phase = CapturePhase(rawValue: phaseCode) else { throw refuse(.unknownPhase(phaseCode)) }
                guard let ordinal = row.integer(6), row.integer(7) != nil, try row.text(8) == "capture" else {
                    throw refuse(.forbiddenColumn("sample"))
                }
                key = .observe(CaptureSampleKey(eventID: eventID, phase: phase, ordinal: Int(ordinal)))
            case .record, .setName:
                guard row.isNull(5), row.isNull(6), row.isNull(7), row.isNull(8) else { throw refuse(.forbiddenColumn("sample")) }
                key = operation == .record ? .record(eventID: eventID) : .setName(eventID: eventID)
        }
        let outcomeCode = try row.text(13) ?? ""
        let counts = (row.integer(14), row.integer(15), row.integer(16))
        let anchor = try row.text(17), transition = try row.text(18), evidence = row.integer(19)
        func none(_ names: [(String, Bool)]) throws {
            for (name, isSet) in names where isSet { throw refuse(.outcomeShape(name)) }
        }
        let outcome: BrainApplicationOutcome
        switch outcomeCode {
            case "observed":
                guard let created = counts.0, let updated = counts.1, let skipped = counts.2 else { throw refuse(.outcomeShape("counts")) }
                try none([("anchor_id", anchor != nil), ("transition_id", transition != nil), ("evidence_count", evidence != nil)])
                outcome = .observed(created: Int(created), updated: Int(updated), skippedAmbiguous: Int(skipped))
            case "recorded":
                guard let anchor, let transition, let evidence else { throw refuse(.outcomeShape("recorded")) }
                try none([("counts", counts.0 != nil || counts.1 != nil || counts.2 != nil)])
                outcome = .recorded(anchorKey: anchor, transitionID: transition, evidence: Int(evidence))
            case "named":
                guard let anchor else { throw refuse(.outcomeShape("anchor_id")) }
                try none([("counts", counts.0 != nil || counts.1 != nil || counts.2 != nil), ("transition_id", transition != nil),
                          ("evidence_count", evidence != nil)])
                outcome = .named(anchorKey: anchor)
            case "no_effect", "no_anchor", "not_named":
                try none([("counts", counts.0 != nil || counts.1 != nil || counts.2 != nil), ("anchor_id", anchor != nil),
                          ("transition_id", transition != nil), ("evidence_count", evidence != nil)])
                outcome = outcomeCode == "no_effect" ? .noEffect : outcomeCode == "no_anchor" ? .noAnchor : .notNamed
            default:
                throw refuse(.unknownOutcome(outcomeCode))
        }
        guard outcome.belongs(to: operation) else { throw refuse(.outcomeShape(outcomeCode)) }
        return Header(
            applicationID      : id,
            appID              : row.integer(1) ?? 0,
            bundleID           : try row.text(2) ?? "",
            key                : key,
            sampleObservationID: row.integer(7),
            contractVersion    : Int(row.integer(9) ?? 0),
            algorithmVersion   : try row.text(10) ?? "",
            requestedAtMS      : row.integer(11) ?? 0,
            effectiveAtMS      : row.integer(12) ?? 0,
            outcome            : outcome
        )
    }

    /// The stored command of an application, rebuilt from its arguments under the contract.
    static func command(_ handle: some SQLiteQuerying, stored: Header) throws -> BrainApplicationCommand {
        guard stored.contractVersion == BrainApplicationContract.version else {
            throw BrainApplicationError.unsupportedContractVersion(stored.contractVersion)
        }
        let id = stored.applicationID
        let arguments = try handle.query(
            """
            SELECT argument_name, position, value_kind, text_value, integer_value, real_value, boolean_value,
                   operation_id, event_id, route_id, parameter_id, anchor_id, menu_command_id
            FROM memory_operation_arguments WHERE brain_application_id = ? ORDER BY argument_id
            """,
            [.integer(id)]
        ) { row -> BrainArgument in
            let name = try row.text(0) ?? ""
            for (index, column) in [(7, "operation_id"), (8, "event_id"), (9, "route_id"), (10, "parameter_id"),
                                    (11, "anchor_id"), (12, "menu_command_id")] where !row.isNull(index) {
                throw BrainApplicationError.malformedApplication(applicationID: id, malformation: .forbiddenColumn(column))
            }
            let kind = try row.text(2) ?? ""
            let set = [3, 4, 5, 6].filter { !row.isNull($0) }
            let value: BrainArgument.Value
            switch (kind, set) {
                case ("text", [3])   : value = .text(try row.text(3) ?? "")
                case ("integer", [4]): value = .integer(row.integer(4) ?? 0)
                case ("real", [5])   : value = .real(row.real(5) ?? 0)
                case ("boolean", [6]): value = .boolean(row.integer(6) == 1)
                default:
                    throw BrainApplicationError.malformedApplication(applicationID: id, malformation: .argumentKindMismatch(name))
            }
            return BrainArgument(name: name, position: Int(row.integer(1) ?? -1), value: value)
        }
        return try BrainApplicationCommand(
            key: stored.key, bundleID: stored.bundleID, requestedAtMS: stored.requestedAtMS,
            arguments: arguments, applicationID: id
        )
    }

    static func application(_ handle: some SQLiteQuerying, stored: Header) throws -> BrainApplication {
        BrainApplication(
            applicationID   : stored.applicationID,
            command         : try command(handle, stored: stored),
            contractVersion : stored.contractVersion,
            algorithmVersion: stored.algorithmVersion,
            effectiveAtMS   : stored.effectiveAtMS,
            outcome         : stored.outcome
        )
    }
}
