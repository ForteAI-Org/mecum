//
//  CaptureIdentityBytesTests.swift
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

/// Events and samples are identified and compared as the file holds them: texts byte for byte. Two
/// canonically equivalent ids are two events with two samples, each answered by its own key, and a
/// stored event's text that differs only in its bytes is other content, never the same fact.
@Suite("Capture identities byte for byte")
struct CaptureIdentityBytesTests {

    private let composed   = "café"
    private let decomposed = "cafe\u{301}"

    private func sample(_ eventID: String) -> CaptureSample {
        CaptureSample(key: CaptureSampleKey(eventID: eventID, phase: .after), windowTitle: "Inbox", sessionRevision: nil,
                      surface: .window, quality: .unknown, elements: [])
    }

    @Test("two events whose ids are canonically equivalent but different bytes keep two samples, each retried by its own key and read back with its bytes")
    func twoUnicodeEventsTwoSamples() async throws {
        let memory = try await SceneFixtures.open()
        for id in [composed, decomposed] {
            #expect(try await memory.captures.record(SceneFixtures.event(id)) == .committed)
            #expect(try await memory.captures.record(sample(id)) == .committed)
        }
        for id in [composed, decomposed] {
            #expect(try await memory.captures.record(SceneFixtures.event(id)) == .alreadyApplied)
            #expect(try await memory.captures.record(sample(id)) == .alreadyApplied)
        }
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'capture'", in: memory.store) == 2)
        var byKey: [CaptureSampleKey: String] = [:]
        for id in [composed, decomposed] {
            let back = try #require(try await memory.captures.sample(CaptureSampleKey(eventID: id, phase: .after)))
            #expect(Array(back.key.eventID.utf8) == Array(id.utf8))
            byKey[back.key] = id
        }
        #expect(byKey.count == 2, "the two stored keys are two keys in memory too")
        await memory.store.close()
    }

    @Test("a stored event offered again with a text that differs only in its bytes is a conflict, with nothing written")
    func eventTextsAreBytes() async throws {
        let memory = try await SceneFixtures.open()
        var event = SceneFixtures.event("e1", app: AppContextIdentity(bundleID: "test.\(composed)", version: "1.0", locale: "it"))
        event.streamID  = "worker-\(composed)"
        event.sourceKey = "key-\(composed)"
        event.traceID   = "trace-\(composed)"
        #expect(try await memory.captures.record(event) == .committed)
        var stream = event
        stream.streamID = "worker-\(decomposed)"
        var key = event
        key.sourceKey = "key-\(decomposed)"
        var trace = event
        trace.traceID = "trace-\(decomposed)"
        var bundle = event
        bundle.app = AppContextIdentity(bundleID: "test.\(decomposed)", version: "1.0", locale: "it")
        for (name, offered) in [("stream", stream), ("source key", key), ("trace", trace), ("bundle", bundle)] {
            let error = await storeError { _ = try await memory.captures.record(offered) }
            guard case .identity? = error else {
                Issue.record("\(name): expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        #expect(try await count("SELECT count(*) FROM memory_events", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: memory.store) == 1)
        let back = try #require(try await memory.captures.event("e1"))
        #expect(Array(back.streamID.utf8) == Array("worker-\(composed)".utf8))
        await memory.store.close()
    }
}
