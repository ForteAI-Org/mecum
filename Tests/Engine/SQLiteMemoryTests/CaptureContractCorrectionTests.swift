//
//  CaptureContractCorrectionTests.swift
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

/// The correction R1 to R3 of the first S2 increment, as the supervision reproduced it: content
/// compared exactly and typed (R1), a complete capture only from a found window and a finished,
/// untruncated walk, with contradictory facts refused on both ways (R2), and finite geometry only
/// (R3). Every case runs through the producer and the store on a temporary file; a refusal is the
/// contract's or the file's, never a failure of the store.
@Suite("Correction R1 to R3 of the capture contract")
struct CaptureContractCorrectionTests {

    private typealias F = SceneFixtures

    private func sample(_ id: String = "review") -> CaptureSample {
        F.sample(id, of: F.perceive(F.window("W", [F.button("OK", y: 300)])))
    }

    /// Whether the operation was refused by the contract or by the file; any other error is a defect.
    private func isRefused(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch is ObservationContractError {
            return true
        } catch let error as MemoryStoreError {
            if case .contract = error { return true }
            Issue.record("a store error where a contract refusal was expected: \(error)")
            return false
        } catch {
            Issue.record("an error outside both taxonomies: \(error)")
            return false
        }
    }

    private func conflict(_ operation: () async throws -> Void) async -> MemoryIdentityConflict? {
        let error = await storeError { try await operation() }
        guard case .identity(let report)? = error else {
            Issue.record("expected an identity conflict, got \(String(describing: error))")
            return nil
        }
        return report
    }

    private func rows(in memory: F.Memory) async throws -> Int64 {
        try await count("SELECT count(*) FROM memory_event_observations", in: memory.store)
    }

    // MARK: Positive case

    @Test("two collections in one produced capture keep two groups and round-trip equal")
    func twoCollections() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let window = F.perceive(F.window("W", [
            F.table("People", rows: ["Alice Rossi"], y: 200),
            F.table("Tracks", rows: ["Synthetic track"], y: 400),
            F.button("Compose", y: 700),
        ]))
        let offered = F.sample("review", of: window)
        #expect(Set(offered.elements.filter(\.isUnderCollection).map(\.containerPath)).count == 2)
        #expect(try await memory.captures.record(offered) == .committed)
        #expect(try await memory.captures.sample(offered.key) == offered)
        #expect(try await count("SELECT count(DISTINCT observation_group) FROM memory_event_observations WHERE observation_group IS NOT NULL", in: memory.store) == 2)
        await memory.store.close()
    }

    // MARK: R1

    @Test("R1: a NULL window title and an empty one are different payloads under one sample key")
    func sampleNullVersusEmpty() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        var first = sample()
        first.windowTitle = nil
        _ = try await memory.captures.record(first)
        let before = try await rows(in: memory)
        var second = first
        second.windowTitle = ""
        #expect(first != second)
        let report = await conflict { _ = try await memory.captures.record(second) }
        #expect(report?.identity == "review:current:0")
        #expect(try await memory.captures.sample(first.key) == first)
        #expect(try await rows(in: memory) == before)
        await memory.store.close()
    }

    @Test("R1: bounds that differ below the sixth decimal conflict, and the stored REAL stays exact")
    func sampleBoundsPrecision() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let first = sample()
        _ = try await memory.captures.record(first)
        var second = first
        let rect = second.elements[0].bounds
        second.elements[0].bounds = NormalizedRect(x: rect.x + 0.00000001, y: rect.y, width: rect.width, height: rect.height)
        #expect(first != second)
        #expect(await conflict { _ = try await memory.captures.record(second) } != nil)
        let stored = try await memory.captures.sample(first.key)
        #expect(stored == first)
        #expect(stored?.elements[0].bounds.x == rect.x)
        await memory.store.close()
    }

    @Test("R1: a NULL trace id and an empty one are different immutable event payloads")
    func eventNullVersusEmpty() async throws {
        let memory = try await F.open()
        let first = F.event("review")
        _ = try await memory.captures.record(first)
        var second = first
        second.traceID = ""
        #expect(first != second)
        let report = await conflict { _ = try await memory.captures.record(second) }
        #expect(report?.identity == "review")
        #expect(try await memory.captures.event("review") == first)
        await memory.store.close()
    }

    @Test("R1: a separator moving between two event fields is a conflict, not the same event")
    func eventDelimiterAmbiguity() async throws {
        let memory = try await F.open()
        var first = F.event("review")
        first.traceID = "a\u{1F}b"
        first.sessionID = "c"
        _ = try await memory.captures.record(first)
        var second = first
        second.traceID = "a"
        second.sessionID = "b\u{1F}c"
        #expect(first != second)
        #expect(await conflict { _ = try await memory.captures.record(second) } != nil)
        #expect(try await memory.captures.event("review") == first)
        await memory.store.close()
    }

    // MARK: R2

    @Test("R2: a walk that says both finished and stopped by the deadline is refused, with no row")
    func contradictoryQuality() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        var offered = sample()
        offered.quality.stoppedBy = .deadline
        #expect(offered.quality.walkCompleted == true)
        #expect(await isRefused { _ = try await memory.captures.record(offered) })
        #expect(try await rows(in: memory) == 0)
        #expect(try await memory.captures.event("review")?.captureStatus == .unknown)
        await memory.store.close()
    }

    @Test("R2: an unknown window never certifies a complete read")
    func unknownWindowCompleteness() {
        let quality = CaptureQuality(walkCompleted: true, windowFound: nil)
        #expect(!quality.isComplete)
        #expect(quality.completeness != .complete)
    }

    // MARK: R3

    @Test("R3: a NaN coordinate is refused before the commit instead of being saved as a missing field")
    func nonfiniteBounds() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        var offered = sample()
        offered.elements[0].bounds = NormalizedRect(x: .nan, y: 0.2, width: 0.1, height: 0.1)
        #expect(await isRefused { _ = try await memory.captures.record(offered) })
        #expect(try await rows(in: memory) == 0)
        #expect(try await memory.captures.sample(offered.key) == nil)
        await memory.store.close()
    }
}

/// The same correction, case by case: every immutable field, every bound, every status and every
/// malformation the file could hold, with the stored data intact and no count moved.
@Suite("Correction R1 to R3, case by case")
struct CaptureContractCorrectionDetailTests {

    private typealias F = SceneFixtures

    private func sample(_ id: String = "review", y: CGFloat = 300) -> CaptureSample {
        F.sample(id, of: F.perceive(F.window("W", [F.button("OK", y: y)])))
    }

    private func conflict(_ operation: () async throws -> Void) async -> MemoryIdentityConflict? {
        let error = await storeError { try await operation() }
        guard case .identity(let report)? = error else {
            Issue.record("expected an identity conflict, got \(String(describing: error))")
            return nil
        }
        return report
    }

    private func readError(_ memory: F.Memory, _ key: CaptureSampleKey) async -> ObservationContractError? {
        do {
            _ = try await memory.captures.sample(key)
            return nil
        } catch let error as ObservationContractError {
            return error
        } catch {
            Issue.record("another error: \(error)")
            return nil
        }
    }

    // MARK: R1

    @Test("R1: every immutable field of an event decides a conflict on its own; the mutable summary does not")
    func eventFields() async throws {
        let memory = try await F.open()
        var base = F.event("review")
        base.traceID = "trace"
        base.sessionID = "session"
        base.monotonicNS = 5
        base.parentEventID = nil
        _ = try await memory.captures.record(base)
        let variants: [(String, (inout MemoryEventRecord) -> Void)] = [
            ("source",        { $0.source = .app }),
            ("streamID",      { $0.streamID = "other" }),
            ("sourceKey",     { $0.sourceKey = "other-key" }),
            ("sourceKey nil", { $0.sourceKey = nil }),
            ("traceID",       { $0.traceID = "trace2" }),
            ("sessionID nil", { $0.sessionID = nil }),
            ("kind",          { $0.kind = .action }),
            ("app bundle",    { $0.app = AppContextIdentity(bundleID: "other.app", version: "1.0", locale: "it") }),
            ("app version",   { $0.app = AppContextIdentity(bundleID: F.app.bundleID, version: "2.0", locale: "it") }),
            ("app nil",       { $0.app = nil }),
            ("occurredAt",    { $0.occurredAtMS += 1 }),
            ("monotonicNS",   { $0.monotonicNS = nil }),
        ]
        for (name, mutate) in variants {
            var other = base
            mutate(&other)
            #expect(!base.hasSameImmutableContent(as: other), Comment(rawValue: name))
            let report = await conflict { _ = try await memory.captures.record(other) }
            #expect(report?.identity == "review", Comment(rawValue: name))
        }
        var summary = base
        summary.captureStatus = .complete
        #expect(base.hasSameImmutableContent(as: summary))
        #expect(try await memory.captures.record(summary) == .alreadyApplied, "the one mutable column is not content")
        #expect(try await memory.captures.event("review") == base)
        #expect(try await count("SELECT count(*) FROM memory_events", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: memory.store) == 1)
        await memory.store.close()
    }

    @Test("R1: the app context's unknown marker is the one declared exception: an empty version is the stored NULL")
    func appUnknownMarker() async throws {
        let memory = try await F.open()
        let first = F.event("review", app: AppContextIdentity(bundleID: "x.app", version: nil, locale: "it"))
        _ = try await memory.captures.record(first)
        let marker = F.event("review", app: AppContextIdentity(bundleID: "x.app", version: "", locale: "it"))
        #expect(first != marker)
        #expect(first.hasSameImmutableContent(as: marker))
        #expect(try await memory.captures.record(marker) == .alreadyApplied)
        #expect(try await memory.captures.event("review")?.app == AppContextIdentity(bundleID: "x.app", version: nil, locale: "it"))
        var trace = first
        trace.traceID = ""
        #expect(!first.hasSameImmutableContent(as: trace), "the marker is the app context's alone")
        await memory.store.close()
    }

    @Test("R1: every persisted field of a sample decides a conflict on its own, and the digests are diagnostics")
    func sampleFields() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let base = sample()
        _ = try await memory.captures.record(base)
        let rows = try await count("SELECT count(*) FROM memory_event_observations", in: memory.store)
        let variants: [(String, (inout CaptureSample) -> Void)] = [
            ("title",           { $0.windowTitle = "Other" }),
            ("revision",        { $0.sessionRevision = 3 }),
            ("surface",         { $0.surface = .dialog }),
            ("quality",         { $0.quality.nodesVisited = ($0.quality.nodesVisited ?? 0) + 1 }),
            ("quality nil",     { $0.quality.windowSubrole = nil }),
            ("element label",   { $0.elements[0].label = "Cancel" }),
            ("element origin",  { $0.elements[0].labelOrigin = .description }),
            ("element path",    { $0.elements[0].containerPath = "Panel" }),
            ("element state",   { $0.elements[0].state = .on }),
            ("element kind",    { $0.elements[0].kind = .text }),
            ("element group",   { $0.elements[0].isUnderCollection = true }),
            ("element height",  { $0.elements[0].bounds.height += 1e-12 }),
            ("element count",   { $0.elements.append($0.elements[0]) }),
            ("no elements",     { $0.elements = [] }),
        ]
        for (name, mutate) in variants {
            var other = base
            mutate(&other)
            #expect(other != base, Comment(rawValue: name))
            let report = await conflict { _ = try await memory.captures.record(other) }
            #expect(report?.identity == "review:current:0", Comment(rawValue: name))
            #expect(report?.storedFingerprint == base.fingerprint, Comment(rawValue: name))
        }
        #expect(try await memory.captures.record(base) == .alreadyApplied)
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == rows)
        #expect(try await memory.captures.sample(base.key) == base)
        #expect(try await memory.captures.event("review")?.captureStatus == .complete)
        await memory.store.close()
    }

    @Test("R1: a text with a NUL, a separator or only a difference of case is content and round-trips exactly")
    func textsAreContent() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        var base = sample()
        base.windowTitle = "a\u{1F}b\u{0}c"
        _ = try await memory.captures.record(base)
        var other = base
        other.windowTitle = "a\u{1F}B\u{0}c"
        #expect(await conflict { _ = try await memory.captures.record(other) } != nil)
        #expect(try await memory.captures.sample(base.key)?.windowTitle == "a\u{1F}b\u{0}c")
        await memory.store.close()
    }

    // MARK: R2

    @Test("R2: the four completeness values from facts the producers already make, and the facts that stay unknown")
    func completenessTable() {
        let complete = CaptureQuality(walkCompleted: true, windowFound: true, nodesVisited: 3, elementsEmitted: 1)
        #expect(complete.completeness == .complete && complete.inconsistency == nil)
        let completeWithGrant = CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true)
        #expect(completeWithGrant.completeness == .complete, "a known grant adds nothing a found window did not")
        let partial = CaptureQuality(walkCompleted: false, stoppedBy: .deadline, windowFound: true)
        #expect(partial.completeness == .partial && partial.inconsistency == nil)
        let degenerate = CaptureQuality(walkCompleted: false, windowFound: false, nodesVisited: 0, elementsEmitted: 0)
        #expect(degenerate.completeness == .failed && degenerate.inconsistency == nil, "the producer's degenerate frame stays failed and valid")
        let noWindow = CaptureQuality(windowFound: false, isGrantAvailable: true)
        #expect(noWindow.completeness == .failed && noWindow.inconsistency == nil)
        let noGrant = CaptureQuality(windowFound: false, isGrantAvailable: false)
        #expect(noGrant.completeness == .failed)
        #expect(CaptureQuality.unknown.completeness == .unknown)
        #expect(CaptureQuality(walkCompleted: true).completeness == .unknown, "an unknown window is never complete")
        #expect(CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: nil).completeness == .complete,
                "nil is not false: a synthetic producer that read the window need not know the grant")
        #expect(CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: false).completeness == .failed)
        #expect(CaptureQuality(walkCompleted: true, stoppedBy: .deadline, windowFound: true).inconsistency == .completedWalkWasStopped)
        #expect(CaptureQuality(walkCompleted: true, windowFound: true, nodesVisited: -1).inconsistency == .negativeCount)
        #expect(CaptureQuality(walkCompleted: true, windowFound: true, elementsEmitted: -3).inconsistency == .negativeCount)
        #expect(CaptureQuality(walkCompleted: false, windowFound: true).inconsistency == nil, "a stopped walk without a named reason is not a contradiction")
    }

    @Test("R2: an inconsistent quality is refused before the transaction, with its reason, and the event's summary stays")
    func inconsistentQualityRefused() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        var stopped = sample()
        stopped.quality.stoppedBy = .elementLimit
        await #expect(throws: ObservationContractError.invalidRecord(.inconsistentQuality(.completedWalkWasStopped))) {
            _ = try await memory.captures.record(stopped)
        }
        var negative = sample()
        negative.quality.elementsEmitted = -1
        await #expect(throws: ObservationContractError.invalidRecord(.inconsistentQuality(.negativeCount))) {
            _ = try await memory.captures.record(negative)
        }
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == 0)
        #expect(try await memory.captures.event("review")?.captureStatus == .unknown)
        #expect(try await memory.captures.record(sample()) == .committed, "the store is usable and the same key still free")
        await memory.store.close()
    }

    @Test("R2: a stored sample whose fields were edited into a contradiction, or past its status, is refused on the way out")
    func inconsistentRowsRefused() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let offered = sample()
        _ = try await memory.captures.record(offered)
        let captureID = try await memory.store.read { snapshot in
            try snapshot.query("SELECT observation_id FROM memory_event_observations WHERE observation_kind = 'capture'", []) { $0.integer(0) ?? 0 }.first ?? 0
        }
        func set(_ field: String, _ assignment: String) async throws {
            _ = try await memory.store.write { transaction in
                try transaction.execute(
                    "UPDATE memory_event_observations SET \(assignment) WHERE parent_observation_id = ? AND field_name = ?",
                    [.integer(captureID), .text(field)]
                )
            }
        }
        try await set("stopped_by", "status = 'observed', text_value = 'deadline'")
        #expect(await readError(memory, offered.key) == .malformedObservation(observationID: captureID, malformation: .inconsistentQuality(.completedWalkWasStopped)))
        try await set("stopped_by", "status = 'not_observed', text_value = NULL")
        try await set("window_found", "status = 'not_observed', boolean_value = NULL")
        #expect(await readError(memory, offered.key) == .malformedObservation(observationID: captureID, malformation: .statusContradictsFields),
                "complete on the sample, unknown window in the fields")
        try await set("window_found", "status = 'observed', boolean_value = 1")
        try await set("nodes_visited", "integer_value = -4")
        #expect(await readError(memory, offered.key) == .malformedObservation(observationID: captureID, malformation: .inconsistentQuality(.negativeCount)))
        try await set("nodes_visited", "integer_value = 3")
        #expect(await readError(memory, offered.key) == nil)
        await memory.store.close()
    }

    @Test("R2: a sample that is not complete never confirms a scene, through the repository or past it")
    func noConfirmationWithoutCompleteness() async throws {
        let memory = try await F.open()
        let window = F.perceive(F.window("Inbox", [F.table("People", rows: ["Alice"]), F.button("Compose", y: 700)]))
        _ = try await F.observe(memory, "e1", window)
        var unknownWindow = F.sample("e2", of: window)
        unknownWindow.quality.windowFound = nil
        #expect(unknownWindow.quality.completeness == .unknown)
        _ = try await memory.captures.record(F.event("e2"))
        _ = try await memory.captures.record(unknownWindow)
        let outcome = try await memory.scenes.associate(unknownWindow.key, at: F.t0)
        #expect(outcome.decision == .candidates(["scene-1"]))
        #expect(outcome.associations.allSatisfy { $0.status == .candidate })
        let refused = await refusal(
            of: """
                INSERT INTO memory_event_scenes (event_id, app_id, phase, sample_ordinal, scene_id, match_status, matched_by, matcher_version)
                VALUES ('e2', 1, 'current', 1, 'scene-1', 'confirmed', 'structure', 'v3')
                """,
            in: memory.store
        )
        #expect(refused != nil, "no sample at that ordinal, no association at all")
        let promoted = await refusal(of: "UPDATE memory_event_scenes SET match_status = 'confirmed' WHERE event_id = 'e2'", in: memory.store)
        #expect(promoted?.message.contains("only a complete capture can confirm") == true)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE match_status = 'confirmed'", in: memory.store) == 1)
        await memory.store.close()
    }

    // MARK: R3

    @Test("R3: NaN and either infinity in any of the four bounds are refused before the commit; the event, its summary and the rows stay")
    func nonFiniteRefused() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let values: [Double] = [.nan, .infinity, -.infinity]
        for value in values {
            for coordinate in 0..<4 {
                var offered = sample()
                var array = offered.elements[0].bounds.array
                array[coordinate] = value
                offered.elements[0].bounds = NormalizedRect(x: array[0], y: array[1], width: array[2], height: array[3])
                #expect(!offered.elements[0].bounds.isFinite)
                await #expect(throws: ObservationContractError.invalidRecord(.nonFiniteBounds), Comment(rawValue: "\(value) at \(coordinate)")) {
                    _ = try await memory.captures.record(offered)
                }
            }
        }
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: memory.store) == 0)
        #expect(try await memory.captures.event("review")?.captureStatus == .unknown)
        var exact = sample()
        exact.elements[0].bounds = NormalizedRect(x: 0.1234567890123456, y: 1e-300, width: 0.30000000000000004, height: 5e-324)
        #expect(try await memory.captures.record(exact) == .committed, "the store is usable and finite geometry is not bounded further")
        let stored = try await memory.captures.sample(exact.key)
        #expect(stored?.elements[0].bounds == exact.elements[0].bounds)
        #expect(stored?.elements[0].bounds.height == 5e-324)
        await memory.store.close()
    }

    @Test("R3: an infinity written into the file by another hand is refused on the way out")
    func infiniteRowRefused() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("review"))
        let offered = sample()
        _ = try await memory.captures.record(offered)
        let elementID = try await memory.store.read { snapshot in
            try snapshot.query("SELECT observation_id FROM memory_event_observations WHERE observation_kind = 'element'", []) { $0.integer(0) ?? 0 }.first ?? 0
        }
        _ = try await memory.store.write { transaction in
            // 1e999 overflows a double: the file keeps +Inf as a REAL.
            try transaction.execute("UPDATE memory_event_observations SET bounds_width = 1e999 WHERE observation_id = ?", [.integer(elementID)])
        }
        #expect(await readError(memory, offered.key) == .malformedObservation(observationID: elementID, malformation: .nonFiniteBounds))
        _ = try await memory.store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET bounds_width = -1e999 WHERE observation_id = ?", [.integer(elementID)])
        }
        #expect(await readError(memory, offered.key) == .malformedObservation(observationID: elementID, malformation: .nonFiniteBounds))
        await memory.store.close()
    }
}
