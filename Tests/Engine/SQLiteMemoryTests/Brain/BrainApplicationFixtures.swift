//
//  BrainApplicationFixtures.swift
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

/// BrainApplicationFixtures opens a store with the capture repository that holds the events and
/// samples an application names, the application repository on deterministic identities, and the
/// raw projection on random ones, so the two never draw the same key. Events and samples are
/// recorded explicitly: no application can name a fact the store does not hold.
enum BrainApplicationFixtures {

    static let bundle = "test.fixture.applications"
    static let other  = "test.fixture.elsewhere"
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let captures: SQLiteCaptureRepository
        let applications: SQLiteBrainApplicationRepository
        let raw: SQLiteBrainRepository

        /// Records an event of the application (an action unless said otherwise).
        func event(_ id: String, kind: MemoryEventKind = .action, bundle: String = BrainApplicationFixtures.bundle,
                   occurredAtMS: Int64 = 1_700_000_000_000) async throws {
            _ = try await captures.record(MemoryEventRecord(
                eventID: id, source: .app, streamID: "worker", sourceKey: id, kind: kind,
                app: AppContextIdentity(bundleID: bundle), occurredAtMS: occurredAtMS
            ))
        }

        /// Records a real sample of the event: a capture row, without elements, quality unknown.
        func sample(_ eventID: String, _ phase: CapturePhase = .after, ordinal: Int = 0) async throws -> CaptureSampleKey {
            let key = CaptureSampleKey(eventID: eventID, phase: phase, ordinal: ordinal)
            _ = try await captures.record(CaptureSample(key: key, windowTitle: "Inbox", sessionRevision: nil, surface: .window,
                                                        quality: .unknown, elements: []))
            return key
        }

        func brain(_ bundle: String = BrainApplicationFixtures.bundle) async throws -> UIBrain? {
            try await raw.brain(of: bundle)
        }

        func count(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> Int64 {
            try await store.read { try $0.query(sql, bindings) { $0.integer(0) ?? -1 }.first ?? -1 }
        }

        func texts(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> [String] {
            try await store.read { try $0.query(sql, bindings) { try $0.text(0) ?? "<null>" } }
        }

        func integers(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> [Int64?] {
            try await store.read { try $0.query(sql, bindings) { $0.integer(0) } }
        }
    }

    static func open(at url: URL? = nil, ids: BrainIdentities = BrainIdentities(),
                     algorithmVersion: String = BrainApplicationContract.algorithmVersion) async throws -> Memory {
        let url   = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(
            url         : url,
            store       : store,
            captures    : SQLiteCaptureRepository(store: store),
            applications: SQLiteBrainApplicationRepository(store: store, keys: ids.keys, makeTransitionID: ids.transitionID,
                                                           makeSceneID: ids.sceneID, algorithmVersion: algorithmVersion),
            raw         : SQLiteBrainRepository(store: store)
        )
    }

    /// The controls `memory-probe brain-observe` builds from labels: one under the other.
    static func controls(_ labels: [String]) -> [BrainDetection] {
        labels.enumerated().map { index, label in
            BrainDetection(kind: .control, label: label,
                           bounds: NormalizedRect(x: 0.5, y: 0.1 + 0.05 * Double(index), width: 0.03, height: 0.017))
        }
    }

    static func observe(_ sample: CaptureSampleKey, _ detections: [BrainDetection], window: String? = nil,
                        at: Date = t0, bundle: String = BrainApplicationFixtures.bundle) throws -> BrainApplicationCommand {
        try .observe(detections: detections, window: window, bundleID: bundle, sample: sample, requestedAt: at)
    }

    static func record(_ eventID: String, _ element: SceneElement, effect: SceneEffect?, verb: ActionVerb = .click,
                       at: Date = t0) throws -> BrainApplicationCommand {
        try .record(ActionRecord(bundleID: bundle, element: element, verb: verb, effect: effect, windowTitleAfter: nil),
                    eventID: eventID, requestedAt: at)
    }

    static func element(_ label: String, index: Int) -> SceneElement {
        SceneElement(id: "control|\(label)", kind: .control, label: label,
                     bounds: NormalizedRect(x: 0.5, y: 0.1 + 0.05 * Double(index), width: 0.03, height: 0.017))
    }

    static func milliseconds(_ date: Date) throws -> Int64 { try BrainClock.milliseconds(of: date) }
}
