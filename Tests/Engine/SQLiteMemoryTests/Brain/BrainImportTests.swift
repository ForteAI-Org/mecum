//
//  BrainImportTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The manual import of an earlier JSON Knowledge directory: a Brain the file holds becomes the
/// application's projection, read back as it was, and an application the memory already knows is
/// left alone.
@Suite("Importing an earlier JSON Brain into the memory")
struct BrainImportTests {

    private func brain() -> UIBrain {
        var brain = UIBrain()
        let elements = ["Open", "Save", "Export"].enumerated().map { index, label in
            SceneElement(id: "control|\(label)", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.1 + Double(index) * 0.2, y: 0.1, width: 0.08, height: 0.04),
                         role: "AXButton")
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = BrainUpdater.ingest(elements.map(BrainDetection.init), into: &brain, now: now, window: "document")
        _ = BrainUpdater.ingest(elements.map(BrainDetection.init), into: &brain, now: now.addingTimeInterval(60), window: "document")
        let save = brain.objects.first { $0.label == "Save" }!
        _ = BrainUpdater.recordTransition(anchorKey: save.anchorKey, trigger: .click,
                                          effect: SceneEffect.windowTitleChanged(title: "Save As").encoded,
                                          into: &brain, now: now.addingTimeInterval(61))
        return brain
    }

    @Test("a Brain from a JSON file becomes the projection and reads back with its anchors, groups and transitions")
    func importsOnce() async throws {
        let store   = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let brains  = SQLiteBrainRepository(store: store)
        let earlier = brain()
        let now     = Date(timeIntervalSince1970: 1_790_000_100)
        #expect(try await brains.importProjection(earlier, into: "com.example.Editor", now: now))
        let read = try #require(try await brains.brain(of: "com.example.Editor"))
        #expect(Set(read.objects.map(\.label)) == Set(earlier.objects.map(\.label)))
        #expect(read.objects.map(\.seenCount).sorted() == earlier.objects.map(\.seenCount).sorted())
        #expect(read.transitions.map(\.effect) == earlier.transitions.map(\.effect))
        #expect(read.groups.count == earlier.groups.count)
        #expect(try await brains.importProjection(UIBrain(), into: "com.example.Editor", now: now) == false,
                "an application the memory already knows keeps its Brain")
        #expect(try await store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await store.close()
    }
}
