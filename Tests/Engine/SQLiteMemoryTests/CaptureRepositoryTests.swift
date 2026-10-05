//
//  CaptureRepositoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The capture repository: events and samples written whole, read back column for column, applied
/// once by identity, refused on other content under the same identity, and rolled back entirely
/// when the file refuses part of them.
@Suite("The capture repository")
struct CaptureRepositoryTests {

    @Test("an event is recorded once: the same identity and content is already applied, other content is a conflict, and so is a reused source key")
    func eventIdempotency() async throws {
        let memory = try await SceneFixtures.open()
        let event  = SceneFixtures.event("e1")
        #expect(try await memory.captures.record(event) == .committed)
        #expect(try await memory.captures.record(event) == .alreadyApplied)
        var other = event
        other.occurredAtMS += 1
        let conflict = await storeError { _ = try await memory.captures.record(other) }
        guard case .identity(let report)? = conflict else {
            Issue.record("expected an identity conflict, got \(String(describing: conflict))")
            return
        }
        #expect(report.identity == "e1")
        #expect(report.storedFingerprint != report.offeredFingerprint)
        var reused = SceneFixtures.event("e2")
        reused.sourceKey = "e1"
        let keyConflict = await storeError { _ = try await memory.captures.record(reused) }
        guard case .identity(let keyReport)? = keyConflict else {
            Issue.record("expected an identity conflict on the source key, got \(String(describing: keyConflict))")
            return
        }
        #expect(keyReport.identity == "cli:fixtures:e1")
        #expect(try await count("SELECT count(*) FROM memory_events", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_app_contexts", in: memory.store) == 1)
        let back = try await memory.captures.event("e1")
        #expect(back?.app == SceneFixtures.app)
        #expect(back?.source == .cli)
        #expect(back?.kind == .observation)
        #expect(back?.captureStatus == .unknown)
        await memory.store.close()
    }

    @Test("an unknown version or locale stays unknown through the store, and two contexts of one app are two rows")
    func contexts() async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("a", app: AppContextIdentity(bundleID: "x.app")))
        _ = try await memory.captures.record(SceneFixtures.event("b", app: AppContextIdentity(bundleID: "x.app", version: "2")))
        #expect(try await memory.captures.event("a")?.app == AppContextIdentity(bundleID: "x.app"))
        #expect(try await memory.captures.event("b")?.app == AppContextIdentity(bundleID: "x.app", version: "2"))
        #expect(try await count("SELECT count(*) FROM brain_apps", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_app_contexts", in: memory.store) == 2)
        #expect(try await count("SELECT count(*) FROM brain_app_contexts WHERE app_version = '' AND app_locale = ''", in: memory.store) == 1)
        await memory.store.close()
    }

    @Test("a sample needs its event, is written with its eight fields and its elements, and reads back equal after the file is closed and reopened")
    func sampleRoundTrip() async throws {
        let memory = try await SceneFixtures.open()
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [
            SceneFixtures.table("People", rows: ["Alice", "Bruno"]),
            SceneFixtures.button("Compose", y: 700),
            SceneFixtures.checkbox("Unread only", on: true, y: 650),
            SceneFixtures.textField(value: "Mario", y: 620),
        ]))
        let sample = SceneFixtures.sample("e1", of: window)
        await #expect(throws: ObservationContractError.missingEvent(eventID: "e1")) {
            _ = try await memory.captures.record(sample)
        }
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        #expect(try await memory.captures.record(sample) == .committed)
        #expect(sample.elements.count == 7, "two rows, two reply buttons, a button, a checkbox, a field")
        #expect(sample.elements.filter(\.isUnderCollection).count == 4)
        #expect(sample.quality.completeness == .complete)
        #expect(sample.surface == .window)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'capture'", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'capture_field'", in: memory.store) == 8)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'element'", in: memory.store) == 7)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'element' AND observation_group = 1", in: memory.store) == 4)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'element' AND container_path LIKE '%Alice%'", in: memory.store) == 0,
                "a row's name never enters a structural path")
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE field_name = 'grant_available' AND status = 'not_observed'", in: memory.store) == 1,
                "a fixture cannot know the grant, and says so")
        #expect(try await memory.captures.event("e1")?.captureStatus == .complete)
        await memory.store.close()

        let reopened = try await SceneFixtures.open(at: memory.url)
        let back = try await reopened.captures.sample(sample.key)
        #expect(back == sample)
        #expect(back?.fingerprint == sample.fingerprint)
        #expect(back.map(SceneSkeleton.init(sample:)) == SceneSkeleton(sample: sample))
        #expect(try await reopened.captures.sample(CaptureSampleKey(eventID: "e1", phase: .before)) == nil)
        await reopened.store.close()
    }

    @Test("the same sample again is already applied and moves nothing; a different payload under the same key is a conflict and the stored one stays")
    func sampleIdempotency() async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        let first  = SceneFixtures.sample("e1", of: SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("OK", y: 300)])))
        let second = SceneFixtures.sample("e1", of: SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("Cancel", y: 300)])))
        #expect(try await memory.captures.record(first) == .committed)
        let rows = try await count("SELECT count(*) FROM memory_event_observations", in: memory.store)
        #expect(try await memory.captures.record(first) == .alreadyApplied)
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == rows)
        let conflict = await storeError { _ = try await memory.captures.record(second) }
        guard case .identity(let report)? = conflict else {
            Issue.record("expected an identity conflict, got \(String(describing: conflict))")
            return
        }
        #expect(report.identity == "e1:current:0")
        #expect(report.storedFingerprint == first.fingerprint)
        #expect(report.offeredFingerprint == second.fingerprint)
        #expect(try await memory.captures.sample(first.key) == first)
        let next = CaptureSample(key: CaptureSampleKey(eventID: "e1", phase: .current, ordinal: 1), of: SceneFixtures.perceive(
            SceneFixtures.window("W", [SceneFixtures.button("Cancel", y: 300)])))
        #expect(try await memory.captures.record(next) == .committed, "a re-capture in the same phase is the next ordinal")
        await memory.store.close()
    }

    @Test("the event's capture summary is the worst of its samples and moves only when they do")
    func captureSummary() async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        let complete = SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("OK", y: 300)]))
        let partial  = SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("OK", y: 300)]),
                                              limits: .init(isPastDeadline: CountedDeadline(after: 1).isPast))
        #expect(partial.capture.completeness == .partial)
        _ = try await memory.captures.record(SceneFixtures.sample("e1", phase: .before, of: complete))
        #expect(try await memory.captures.event("e1")?.captureStatus == .complete)
        _ = try await memory.captures.record(SceneFixtures.sample("e1", phase: .after, of: partial))
        #expect(try await memory.captures.event("e1")?.captureStatus == .partial)
        _ = try await memory.captures.record(SceneFixtures.sample("e1", phase: .menu, of: SceneFixtures.pixelsOnly(["7"])))
        #expect(try await memory.captures.event("e1")?.captureStatus == .partial, "unknown does not outrank partial")
        await memory.store.close()
    }

    @Test("a sample the file refuses part way is rolled back whole: no capture, no field, no element, the event unchanged, the store usable")
    func rollback() async throws {
        let memory = try await SceneFixtures.open()
        _ = try await memory.captures.record(SceneFixtures.event("e1"))
        let pages = try await memory.store.read { try $0.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0 }
        _ = try await memory.store.write { transaction in
            // A pragma takes no bound value; the number is the file's own page count plus two.
            try transaction.execute("PRAGMA max_page_count = \(pages + 2)")
        }
        let padding = String(repeating: "x", count: 30)
        let big = SceneFixtures.window("W", (0..<300).map { index in
            SceneFixtures.button("Button \(index) \(padding)", y: 120 + CGFloat(index) * 2)
        })
        let sample = SceneFixtures.sample("e1", of: SceneFixtures.perceive(big, limits: .init(maxElements: 400)))
        #expect(sample.elements.count == 300)
        let error = await storeError { _ = try await memory.captures.record(sample) }
        guard case .failed(let fault)? = error else {
            Issue.record("expected the file to refuse, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 13)
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == 0)
        #expect(try await memory.captures.event("e1")?.captureStatus == .unknown)
        #expect(try await memory.captures.sample(sample.key) == nil)
        _ = try await memory.store.write { try $0.execute("PRAGMA max_page_count = 1073741823") }
        #expect(try await memory.captures.record(sample) == .committed)
        #expect(try await memory.captures.sample(sample.key)?.elements.count == 300)
        await memory.store.close()
    }

    @Test("a record is refused before any transaction when it has no identity or an element has no label")
    func validation() async throws {
        let memory = try await SceneFixtures.open()
        await #expect(throws: ObservationContractError.invalidRecord(.emptyEventID)) {
            _ = try await memory.captures.record(SceneFixtures.event(""))
        }
        let sample = CaptureSample(
            key: CaptureSampleKey(eventID: "e1", phase: .current), windowTitle: nil, sessionRevision: nil,
            surface: .window, quality: .unknown,
            elements: [CaptureElement(kind: .control, role: "AXButton", label: "", labelOrigin: .title, containerPath: "",
                                      isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))]
        )
        await #expect(throws: ObservationContractError.invalidRecord(.emptyLabel)) {
            _ = try await memory.captures.record(sample)
        }
        await memory.store.close()
    }
}
