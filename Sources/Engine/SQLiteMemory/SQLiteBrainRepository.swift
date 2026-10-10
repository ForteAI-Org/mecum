//
//  SQLiteBrainRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteBrainRepository is `BrainStoring` over `SQLiteMemoryStore`: the stored projection of one
/// `UIBrain` per application, mutated by the brain's own pure algorithms. Every mutation runs
/// inside one `BEGIN IMMEDIATE` transaction: the application row is found or created, the active
/// projection is loaded, `BrainUpdater` runs on it unchanged, and `SQLiteBrainRows` writes the
/// difference; no cache of a brain outlives the lock, no `await` sits between the load and the
/// commit, and the clock is the value the caller passed, quantized to its canonical millisecond
/// at the boundary (`BrainClock`). A body that refuses rolls everything back, and the store's
/// retry on a busy lock runs the body again on the rows it then reads.
///
/// `keys` names the anchors and groups the algorithm creates and the two generators name the
/// transition rows and the application's scope row; the defaults are random UUIDs, and a test
/// supplies deterministic sequences to compare a projection with a pure brain field by field.
/// Each call applies its mutation: the serialized load keeps two writers from losing an update, it
/// does not recognize the retry of one event. This is the raw projection, for tests and low-level
/// tools: a producer applies through `SQLiteBrainApplicationRepository`, which records each
/// application once, and the S3 path will not call `ingest`, `observe`, `record`, `setName` or
/// `decay` here; `brain(of:)` is the one read both share.
public struct SQLiteBrainRepository: BrainStoring {

    private let store: SQLiteMemoryStore
    private let keys: BrainKeys
    private let makeTransitionID: @Sendable () -> String
    private let makeSceneID: @Sendable () -> String

    public init(
        store           : SQLiteMemoryStore,
        keys            : BrainKeys = .random,
        makeTransitionID: @escaping @Sendable () -> String = { UUID().uuidString },
        makeSceneID     : @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.store            = store
        self.keys             = keys
        self.makeTransitionID = makeTransitionID
        self.makeSceneID      = makeSceneID
    }

    public func brain(of bundleID: String) async throws -> UIBrain? {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return nil }
            return try SQLiteBrainRows.load(snapshot, appID: appID).brain
        }
    }

    public func ingest(
        _ detections: [BrainDetection],
        into bundleID: String,
        now         : Date,
        window      : String?
    ) async throws -> BrainUpdater.IngestStats {
        let keys = self.keys
        return try await mutate(bundleID, now: now) { brain, now in
            let stats = BrainUpdater.ingest(detections, into: &brain, now: now, window: window, keys: keys)
            return (stats, stats.decay ?? DecayReport())
        }
    }

    public func observe(_ scene: SceneSnapshot, now: Date) async throws -> BrainUpdater.IngestStats {
        let window = LabelText.letters(scene.windowTitle)
        return try await ingest(
            scene.elements.map(BrainDetection.init), into: scene.bundleID, now: now, window: window.isEmpty ? nil : window
        )
    }

    public func record(_ record: ActionRecord, now: Date) async throws -> BrainRecordOutcome {
        guard let effect = record.effect else { return .noEffect }
        let keys      = self.keys
        let detection = BrainDetection(record.element)
        let trigger   = TransitionTrigger(record.verb)
        return try await mutate(record.bundleID, now: now) { brain, now in
            var key: String?
            var retired = DecayReport()
            if case .found(let found) = BrainMatcher.match(detection, in: brain) { key = found }
            if key == nil, case .menuOpened = effect {
                retired = BrainUpdater.ingest([detection], into: &brain, now: now, keys: keys).decay ?? DecayReport()
                if case .found(let found) = BrainMatcher.match(detection, in: brain) { key = found }
            }
            guard let key else { return (BrainRecordOutcome.noAnchor, retired) }
            let evidence = BrainUpdater.recordTransition(
                anchorKey: key, trigger: trigger, effect: effect.encoded, into: &brain, now: now
            )
            return (.recorded(anchorKey: key, evidence: evidence), retired)
        }
    }

    public func setName(_ name: String, anchorKey: String, in bundleID: String, now: Date) async throws -> Bool {
        try await mutate(bundleID, now: now) { brain, now in
            (BrainUpdater.setName(name, anchorKey: anchorKey, into: &brain, now: now), DecayReport())
        }
    }

    public func decay(
        in bundleID: String,
        now        : Date,
        maxObjects : Int = 3000,
        retention  : BrainRetention = .standard
    ) async throws -> DecayReport {
        try await mutate(bundleID, now: now) { brain, now in
            let report = BrainUpdater.decay(&brain, now: now, maxObjects: maxObjects, retention: retention)
            return (report, report)
        }
    }

    /// Writes a whole Brain as the application's projection, for the manual import of an earlier JSON
    /// Knowledge directory: false, changing nothing, when the application already has anchors, groups
    /// or transitions. No application or evidence row is written: the imported counts are the file's.
    ///
    /// The rows are written at the Brain's own last instant, never later: a row the import stamps
    /// is then no newer than what the file says it saw. `now` is used only for a Brain that saw
    /// nothing. The Brain is admitted first (`importAdmitted`).
    public func importProjection(_ imported: UIBrain, into bundleID: String, now: Date) async throws -> Bool {
        try await importAdmitted(imported, into: bundleID, now: now).imported
    }

    /// Imports a Brain as `importProjection` does, once admitted as a live Brain would have learned it:
    /// credential shapes withheld from its labels, aliases, window families and group names, and the
    /// transitions whose effect held one left out (`ValueMinimization.minimize(brain:)`). The archive
    /// never keeps what the file had to withhold; the file itself is only read. Answers whether it
    /// imported, and what it withheld.
    public func importAdmitted(
        _ imported: UIBrain,
        into bundleID: String,
        now: Date
    ) async throws -> (imported: Bool, withheld: ValueMinimization.BrainWithholding) {
        let (admitted, withheld) = ValueMinimization().minimize(brain: imported)
        let latest = (admitted.objects.map(\.lastSeen) + admitted.groups.map(\.lastSeen)
            + admitted.transitions.map(\.lastObserved)).max() ?? now
        let done = try await mutate(bundleID, now: latest) { brain, _ in
            guard brain.objects.isEmpty, brain.groups.isEmpty, brain.transitions.isEmpty else { return (false, DecayReport()) }
            brain = admitted
            return (true, DecayReport())
        }
        return (done, withheld)
    }

    /// Merges an earlier origin's Brain into the application's projection (`BrainMerge`), at the Brain's
    /// own last instant as an import is, and journals every element under `originID` in the same
    /// transaction; the origin must be journaled already. Merged again, nothing is added twice: what this
    /// origin added is then present, and its first journal row is the one kept. The Brain is admitted
    /// first, as `importAdmitted` admits one, and the journal says what was withheld.
    public func merge(_ origin: UIBrain, into bundleID: String, origin originID: String,
                      now: Date) async throws -> BrainMerge {
        let (imported, withheld) = ValueMinimization().minimize(brain: origin)
        let latest = (imported.objects.map(\.lastSeen) + imported.groups.map(\.lastSeen)
            + imported.transitions.map(\.lastObserved)).max() ?? now
        let canonical: Date
        do {
            canonical = try BrainClock.canonical(latest)
        } catch let problem as BrainClock.Problem {
            throw BrainProjectionError.clock(problem)
        }
        let nowMS            = try SQLiteBrainRows.milliseconds(of: canonical)
        let makeTransitionID = self.makeTransitionID
        let makeSceneID      = self.makeSceneID
        return try await store.write { transaction in
            let appID = try SQLiteIdentityRows.ensureApp(transaction, bundleID: bundleID)
            func holders(_ table: String, _ column: String, _ keys: [String]) throws -> [String: Int64] {
                var held: [String: Int64] = [:]
                for key in keys {
                    let app = try transaction.query(
                        "SELECT app_id FROM \(table) WHERE \(column) = ?",
                        [.text(key)]
                    ) { $0.integer(0) }.first
                    if let app = app ?? nil { held[key] = app }
                }
                return held
            }
            let heldAnchors = try holders("brain_anchors", "anchor_id", imported.objects.map(\.anchorKey))
            let heldGroups  = try holders("brain_groups", "group_id", imported.groups.map(\.id.uuidString))
            let loaded = try SQLiteBrainRows.load(transaction, appID: appID)
            let merge = try SQLiteBrainRows.mutate(
                transaction, appID: appID, loaded: loaded, now: canonical, nowMS: nowMS,
                makeTransitionID: makeTransitionID, makeSceneID: makeSceneID
            ) { brain, _ in
                let merge = BrainMerge.merge(imported, into: &brain, appID: appID, heldAnchors: heldAnchors,
                                             heldGroups: heldGroups, withheld: withheld)
                return (merge, DecayReport())
            }.result
            for contribution in merge.contributions {
                try transaction.execute(
                    """
                    INSERT OR IGNORE INTO memory_origin_brain_contributions
                        (origin_id, bundle_id, element_kind, element_key, disposition, withheld)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [.text(originID), .text(bundleID), .text(contribution.kind.rawValue), .text(contribution.key),
                     .text(contribution.disposition.rawValue), .integer(contribution.withheld ? 1 : 0)]
                )
            }
            return merge
        }
    }

    /// Loads the projection, applies the body at the canonical clock and writes the difference, in
    /// one write transaction. The body answers its result and what it retired.
    private func mutate<T: Sendable>(
        _ bundleID: String,
        now       : Date,
        _ body    : @Sendable (inout UIBrain, Date) throws -> (T, DecayReport)
    ) async throws -> T {
        let canonical: Date
        do {
            canonical = try BrainClock.canonical(now)
        } catch let problem as BrainClock.Problem {
            throw BrainProjectionError.clock(problem)
        }
        let nowMS            = try SQLiteBrainRows.milliseconds(of: canonical)
        let makeTransitionID = self.makeTransitionID
        let makeSceneID      = self.makeSceneID
        return try await store.write { transaction in
            let appID  = try SQLiteIdentityRows.ensureApp(transaction, bundleID: bundleID)
            let loaded = try SQLiteBrainRows.load(transaction, appID: appID)
            return try SQLiteBrainRows.mutate(
                transaction, appID: appID, loaded: loaded, now: canonical, nowMS: nowMS,
                makeTransitionID: makeTransitionID, makeSceneID: makeSceneID, body
            ).result
        }
    }
}
