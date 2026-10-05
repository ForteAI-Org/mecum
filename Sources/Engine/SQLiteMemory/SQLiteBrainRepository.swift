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
        guard let element = record.element else { return .noAnchor }
        let keys      = self.keys
        let detection = BrainDetection(element)
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
