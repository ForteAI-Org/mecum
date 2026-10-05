//
//  BrainFixtures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// BrainIdentities hands out one deterministic sequence of anchor keys, group ids, transition ids
/// and scene ids. Two instances produce the same sequence, so a pure reference brain and a stored
/// projection fed the same detections name the same objects and compare with `==`.
final class BrainIdentities: @unchecked Sendable {

    private let lock = NSLock()
    private var anchors = 0, groups = 0, transitions = 0, scenes = 0

    private func next(_ counter: inout Int) -> Int {
        counter += 1
        return counter
    }

    var keys: BrainKeys {
        BrainKeys(
            anchorKey: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return "anchor-\(next(&anchors))"
            },
            groupID: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return BrainIdentities.uuid(next(&groups))
            }
        )
    }

    func transitionID() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "transition-\(next(&transitions))"
    }

    func sceneID() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "scope-\(next(&scenes))"
    }

    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }
}

/// BrainFixtures builds the detections of the brain suites (the switch column of the Premiere
/// export dialog, lone controls, texts) and opens a store with its brain repository. Every clock
/// value is canonical (`BrainClock.canonical`), so the reference and the projection run on the
/// same instant.
enum BrainFixtures {

    static let bundle = "test.fixture.brain"
    static let other  = "test.fixture.other"
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_000_100)
    static let destinations = ["Media File", "Behance", "Facebook", "TikTok", "Vimeo", "X", "YouTube", "FTP"]

    /// A canonical instant `seconds` after `t0`.
    static func clock(_ seconds: Double) throws -> Date {
        try BrainClock.canonical(t0.addingTimeInterval(seconds))
    }

    /// The instant of observation block `n`: `n` times 600 s after `t0`.
    static func block(_ n: Int) throws -> Date {
        try clock(Double(n) * UIBrain.observationBlock)
    }

    static func rect(_ x: Double, _ y: Double, _ width: Double = 0.03, _ height: Double = 0.017) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }

    static func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                    w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        BrainDetection(kind: kind, label: label, bounds: rect(x, y, w, h), state: state)
    }

    static func switchColumn(states: [ControlState]) -> [BrainDetection] {
        states.enumerated().map { i, state in
            det(.control, destinations[i], x: 0.236, y: 0.18 + Double(i) * 0.036, state: state)
        }
    }

    static func scene(_ labels: [String], x: Double = 0.5) -> [BrainDetection] {
        labels.enumerated().map { det(.control, $0.element, x: x, y: 0.1 + 0.05 * Double($0.offset)) }
    }

    static func element(_ id: String, _ label: String, x: Double, y: Double, kind: ElementKind = .control,
                        state: ControlState? = nil, unlabeled: Bool = false) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, bounds: rect(x, y, 0.05, 0.02), state: state, isUnlabeled: unlabeled)
    }

    /// A store with its brain repository on deterministic identities.
    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let brain: SQLiteBrainRepository
        let ids: BrainIdentities

        func load(_ bundle: String = BrainFixtures.bundle) async throws -> UIBrain? {
            try await brain.brain(of: bundle)
        }

        func query<T: Sendable>(_ sql: String, _ bindings: [SQLiteValue] = [],
                                _ row: @Sendable @escaping (SQLiteStatement.Row) throws -> T) async throws -> [T] {
            try await store.read { try $0.query(sql, bindings, row) }
        }

        func texts(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> [String] {
            try await query(sql, bindings) { try $0.text(0) ?? "<null>" }
        }

        func integers(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> [Int64?] {
            try await query(sql, bindings) { $0.integer(0) }
        }

        func foreignKeyCheck() async throws -> Int {
            try await query("PRAGMA foreign_key_check") { _ in () }.count
        }
    }

    static func open(at url: URL? = nil, ids: BrainIdentities = BrainIdentities()) async throws -> Memory {
        let url   = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(
            url  : url,
            store: store,
            brain: SQLiteBrainRepository(store: store, keys: ids.keys, makeTransitionID: ids.transitionID, makeSceneID: ids.sceneID),
            ids  : ids
        )
    }

    /// Twin runs one sequence of mutations on a pure reference brain and on a stored projection,
    /// with two identity sequences that coincide, and compares the projection with the reference
    /// after every step: the round trip of each step (P1) and the equivalence of the algorithms
    /// under controlled keys (P2a) in one.
    final class Twin {

        var reference = UIBrain()
        let memory: Memory
        let bundle: String
        private let referenceKeys: BrainKeys

        init(bundle: String = BrainFixtures.bundle) async throws {
            self.bundle = bundle
            self.memory = try await BrainFixtures.open()
            self.referenceKeys = BrainIdentities().keys
        }

        func check(_ sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let loaded = try await memory.load(bundle)
            #expect(loaded == reference, "the stored projection differs from the reference brain", sourceLocation: sourceLocation)
        }

        @discardableResult
        func ingest(
            _ detections: [BrainDetection],
            at now      : Date,
            window      : String? = nil,
            _ sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> BrainUpdater.IngestStats {
            let expected = BrainUpdater.ingest(detections, into: &reference, now: now, window: window, keys: referenceKeys)
            let stats = try await memory.brain.ingest(detections, into: bundle, now: now, window: window)
            #expect(stats == expected, "the ingest counted differently", sourceLocation: sourceLocation)
            try await check(sourceLocation)
            return stats
        }

        @discardableResult
        func setName(_ name: String, anchorKey: String, at now: Date, _ sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
            let expected = BrainUpdater.setName(name, anchorKey: anchorKey, into: &reference, now: now)
            let named = try await memory.brain.setName(name, anchorKey: anchorKey, in: bundle, now: now)
            #expect(named == expected, sourceLocation: sourceLocation)
            try await check(sourceLocation)
            return named
        }

        @discardableResult
        func decay(
            at now         : Date,
            maxObjects     : Int = 3000,
            retention      : BrainRetention = .standard,
            _ sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> DecayReport {
            let expected = BrainUpdater.decay(&reference, now: now, maxObjects: maxObjects, retention: retention)
            let report = try await memory.brain.decay(in: bundle, now: now, maxObjects: maxObjects, retention: retention)
            #expect(report == expected, "the decay retired differently", sourceLocation: sourceLocation)
            try await check(sourceLocation)
            return report
        }

        func anchor(labeled label: String) -> ObjectAnchor? {
            reference.objects.first { $0.label == label }
        }

        func close() async { await memory.store.close() }
    }
}
