//
//  CaptureSampleContentBytesTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// A stored sample is the fact it was: offered again under its key with any persisted text that
/// differs only in its bytes, or any other field changed, it is a conflict that writes nothing, and
/// the original content stays readable, after reopening too.
@Suite("Capture sample content byte for byte", .serialized)
struct CaptureSampleContentBytesTests {

    private static func base(_ id: String) -> CaptureSample {
        var sample = SceneFixtures.sample(id, of: SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("OK", y: 300)])))
        sample.windowTitle = "café"
        sample.elements[0].label = "café"
        sample.elements[0].role = "AXcafé"
        sample.elements[0].containerPath = "café"
        sample.quality.windowRole = "café"
        sample.quality.windowSubrole = "café"
        return sample
    }

    private static func with(_ field: String, _ text: String, in sample: CaptureSample) -> CaptureSample {
        var sample = sample
        switch field {
            case "windowTitle"  : sample.windowTitle = text
            case "label"        : sample.elements[0].label = text
            case "role"         : sample.elements[0].role = "AX\(text)"
            case "containerPath": sample.elements[0].containerPath = text
            case "windowRole"   : sample.quality.windowRole = text
            case "windowSubrole": sample.quality.windowSubrole = text
            default             : Issue.record("unknown field \(field)")
        }
        return sample
    }

    @Test("a text that differs only in its bytes under the same key is a conflict, nothing is written, and the stored content stays, also after reopening", arguments: ["windowTitle", "label", "role", "containerPath", "windowRole", "windowSubrole"])
    func sixTexts(field: String) async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        let stored = Self.base("e1")
        #expect(try await memory.captures.record(stored) == .committed)
        let offered = Self.with(field, "cafe\u{301}", in: stored)
        #expect(offered.fingerprint != stored.fingerprint)
        let rows = try await count("SELECT count(*) FROM memory_event_observations", in: memory.store)
        let error = await storeError { _ = try await memory.captures.record(offered) }
        guard case .identity? = error else {
            Issue.record("\(field): different bytes accepted as a retry: \(String(describing: error))")
            await memory.store.close()
            return
        }
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == rows)
        #expect(try await memory.captures.sample(stored.key) == stored)
        await memory.store.close()
        let reopened = try await SceneFixtures.open(at: memory.url)
        #expect(try await reopened.captures.record(stored) == .alreadyApplied, "the identical retry after reopening")
        let back = try #require(try await reopened.captures.sample(stored.key))
        #expect(Array((back.windowTitle ?? "").utf8) == Array("café".utf8) && Array(back.elements[0].label.utf8) == Array("café".utf8))
        await reopened.store.close()
    }

    @Test("NUL, separators, NULL against empty text, order and every non-text field decide too; −0.0 and +0.0 are one bound; the store goes on after each refusal")
    func otherFields() async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        var stored = SceneFixtures.sample("e1", of: SceneFixtures.perceive(SceneFixtures.window("W", [
            SceneFixtures.button("OK", y: 300), SceneFixtures.button("Cancel", y: 340)])))
        stored.elements[0].bounds.x = -0.0
        #expect(try await memory.captures.record(stored) == .committed)
        var zero = stored
        zero.elements[0].bounds.x = 0.0
        #expect(try await memory.captures.record(zero) == .alreadyApplied, "−0.0 and +0.0 are one number")
        func variant(_ change: (inout CaptureSample) -> Void) -> CaptureSample {
            var sample = stored
            change(&sample)
            return sample
        }
        let variants: [(String, CaptureSample)] = [
            ("NUL in label", variant { $0.elements[0].label += "\u{0}" }),
            ("separator in label", variant { $0.elements[0].label += "|" }),
            ("title empty", variant { $0.windowTitle = "" }),
            ("title absent", variant { $0.windowTitle = nil }),
            ("order", variant { $0.elements.reverse() }),
            ("one element fewer", variant { $0.elements.removeLast() }),
            ("session revision", variant { $0.sessionRevision = 9 }),
            ("label origin", variant { $0.elements[0].labelOrigin = .description }),
            ("collection", variant { $0.elements[0].isUnderCollection = true }),
            ("state", variant { $0.elements[0].state = .on }),
            ("next bound", variant { $0.elements[1].bounds.y = $0.elements[1].bounds.y.nextUp }),
            ("nodes visited", variant { $0.quality.nodesVisited = ($0.quality.nodesVisited ?? 0) + 1 }),
        ]
        let rows = try await count("SELECT count(*) FROM memory_event_observations", in: memory.store)
        for (name, offered) in variants {
            let error = await storeError { _ = try await memory.captures.record(offered) }
            guard case .identity? = error else {
                Issue.record("\(name): expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == rows)
        #expect(try await memory.captures.sample(stored.key) == zero)
        _ = try await memory.captures.record(SceneFixtures.event("e2"))
        var untitled = SceneFixtures.sample("e2", of: SceneFixtures.perceive(SceneFixtures.window("W", [])))
        untitled.windowTitle = nil
        #expect(try await memory.captures.record(untitled) == .committed, "the store goes on")
        var empty = untitled
        empty.windowTitle = ""
        let error = await storeError { _ = try await memory.captures.record(empty) }
        guard case .identity? = error else {
            Issue.record("an empty title accepted as the stored NULL: \(String(describing: error))")
            await memory.store.close()
            return
        }
        #expect(try await memory.captures.sample(untitled.key)?.windowTitle == nil)
        await memory.store.close()
    }
}
