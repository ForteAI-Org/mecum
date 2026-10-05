//
//  BrainApplicationCorrectionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// Correction C1 and C2 of the application register: a declared detection count is checked against
/// the rows before anything is sized by it, also when the SQL reader rebuilds a stored command; and
/// keys and algorithm versions are compared byte for byte, as the file's binary TEXT keys are. A
/// count that could end a process is decoded in `memory-probe`, never in this runner.
@Suite("Correction C1 and C2 of the brain applications", .serialized)
struct BrainApplicationCorrectionTests {

    private typealias A = BrainApplicationFixtures

    private let composed   = "café"
    private let decomposed = "cafe\u{301}"

    /// The helper's line for a count no row supports, as `memory-probe` prints the refusal.
    private func countRefusal(_ declared: Int64, found: Int, id: Int64 = 1) -> String {
        "error brain malformedApplication(applicationID: \(id), malformation: "
            + "Memory.BrainApplicationError.Malformation.detectionCount(declared: \(declared), found: \(found)))"
    }

    @Test("C1: a declared detection count is checked against the rows received before anything is sized by it, in a helper a trap would end alone, which then decodes on")
    func declaredCounts() async throws {
        let cases: [(count: Int64, rows: Int, answer: String)] = [
            (-1, 0, countRefusal(-1, found: 0)),
            (.min, 0, countRefusal(.min, found: 0)),
            (0, 0, "accepted detections=0"),
            (2, 2, "accepted detections=2"),
            (1, 0, countRefusal(1, found: 0)),
            (1_000_000, 2, countRefusal(1_000_000, found: 2)),
            (1 << 40, 2, countRefusal(1 << 40, found: 2)),
            (.max, 0, countRefusal(.max, found: 0)),
            (.max, 2, countRefusal(.max, found: 2)),
        ]
        // One helper decodes every case and goes on after each refusal; only a case that ended or
        // hung it costs a new one, so a regression is reported per case without touching this runner.
        var probe = try ProbeProcess()
        defer { probe.end() }
        for item in cases {
            probe.send("brain-decode \(item.count) \(item.rows)")
            let answer: String?
            do {
                answer = try await probe.receive(timeout: .seconds(10), waitingFor: "the decoder's answer to \(item.count)")
            } catch is ProbeProcess.Timeout {
                Issue.record("decoding count \(item.count) with \(item.rows) rows did not answer within 10 s; the helper was killed")
                probe.end()
                probe = try ProbeProcess()
                continue
            }
            guard let answer else {
                Issue.record("decoding count \(item.count) with \(item.rows) rows ended the helper: \(String(describing: try await probe.exit()))")
                probe.end()
                probe = try ProbeProcess()
                continue
            }
            #expect(answer == item.answer, Comment(rawValue: "count \(item.count), rows \(item.rows)"))
            #expect(try await probe.ask("brain-decode 1 1") == "accepted detections=1", "the same process decodes on")
        }
    }

    @Test("C1: a stored observation whose count no row supports is refused by the SQL reader, in a helper and then here, and the reader and both stores go on")
    func storedCounts() async throws {
        let memory = try await A.open()
        for event in ["e1", "e2", "e3", "e4"] { try await memory.event(event) }
        for event in ["e1", "e2", "e3", "e4"] { _ = try await memory.sample(event) }
        try await memory.store.write { transaction in
            func header(_ id: Int64, _ event: String) throws {
                try transaction.execute(
                    """
                    INSERT INTO brain_applications (application_id, app_id, event_id, operation, phase, sample_ordinal,
                        sample_observation_id, sample_kind, contract_version, algorithm_version, requested_at_ms, effective_at_ms,
                        outcome, created_count, updated_count, skipped_ambiguous_count)
                    SELECT ?, 1, ?, 'observe', 'after', 0, observation_id, 'capture', 1, 'brain-updater-1', 0, 0, 'observed', 0, 0, 0
                    FROM memory_event_observations
                    WHERE event_id = ? AND phase = 'after' AND sample_ordinal = 0 AND observation_kind = 'capture'
                    """,
                    [.integer(id), .text(event), .text(event)]
                )
            }
            func argument(_ id: Int64, _ name: String, _ position: Int, _ value: SQLiteValue) throws {
                let column = if case .text = value { "text_value" } else if case .real = value { "real_value" } else { "integer_value" }
                let kind   = if case .text = value { "text" } else if case .real = value { "real" } else { "integer" }
                try transaction.execute(
                    "INSERT INTO memory_operation_arguments (brain_application_id, app_id, argument_name, position, value_kind, \(column)) VALUES (?, 1, ?, ?, '\(kind)', ?)",
                    [.integer(id), .text(name), .integer(Int64(position)), value]
                )
            }
            try argument(1, "detection_count", 0, .integer(.max))
            try header(1, "e1")
            try argument(2, "detection_count", 0, .integer(5))
            for position in 0..<2 {
                try argument(2, "detection_kind", position, .text("control"))
                try argument(2, "detection_label", position, .text("D\(position)"))
                for name in ["detection_x", "detection_y", "detection_width", "detection_height"] {
                    try argument(2, name, position, .real(0.1))
                }
            }
            try header(2, "e2")
        }

        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(memory.url.path)").hasPrefix("opened "))
        probe.send("brain-application e1 after 0")
        guard let answer = try await probe.receive(timeout: .seconds(10), waitingFor: "the stored count's refusal") else {
            Issue.record("reading the stored count ended the helper: \(String(describing: try await probe.exit())); reading it here would end this runner")
            await memory.store.close()
            return
        }
        #expect(answer == countRefusal(.max, found: 0))
        #expect(try await probe.ask("brain-application e2 after 0") == countRefusal(5, found: 2, id: 2))
        #expect(try await probe.ask("brain-observe \(A.bundle) e3 after 0 1700000000000 Send").hasPrefix("committed "), "the helper's store writes on")
        #expect(try await probe.ask("brain-application e3 after 0").hasPrefix("application id=3 detections=1"))
        #expect(try await probe.ask("brain-application e1 after 0") == countRefusal(.max, found: 0), "the reader refuses it again, the same way")

        let e1 = BrainApplicationKey.observe(CaptureSampleKey(eventID: "e1", phase: .after))
        await #expect(throws: BrainApplicationError.malformedApplication(applicationID: 1, malformation: .detectionCount(declared: .max, found: 0))) {
            _ = try await memory.applications.application(e1)
        }
        await #expect(throws: BrainApplicationError.malformedApplication(applicationID: 2, malformation: .detectionCount(declared: 5, found: 2))) {
            _ = try await memory.applications.apply(try A.observe(CaptureSampleKey(eventID: "e2", phase: .after), A.controls(["Send"])))
        }
        let fresh = try await memory.applications.apply(try A.observe(CaptureSampleKey(eventID: "e4", phase: .after), A.controls(["Send"])))
        #expect(fresh.receipt == .committed && fresh.applicationID == 4, "this store writes on after both refusals")
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 4)
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [2])
        await memory.store.close()
    }

    @Test("C2: under one concluded key the same algorithm version answers alreadyApplied, and a version that differs only in its bytes is a conflict that adds no row and moves no counter")
    func algorithmVersionBytes() async throws {
        let first = try await A.open(algorithmVersion: "brain.\(composed)")
        try await first.event("e1")
        let sample  = try await first.sample("e1")
        let command = try A.observe(sample, A.controls(["Send", "Draft"]))
        #expect(try await first.applications.apply(command).receipt == .committed)
        func ledger() async throws -> [Int64] {
            [try await first.count("SELECT count(*) FROM brain_applications"),
             try await first.count("SELECT count(*) FROM memory_operation_arguments"),
             try await first.count("SELECT count(*) FROM brain_evidence"),
             try await first.count("SELECT count(*) FROM brain_anchors"),
             try await first.count("SELECT coalesce(sum(seen_count), 0) FROM brain_anchors")]
        }
        let before = try await ledger()

        let same = try await A.open(at: first.url, algorithmVersion: "brain.caf" + "é")
        let retried = try await same.applications.apply(command)
        #expect(retried.receipt == .alreadyApplied && retried.outcome == .observed(created: 2, updated: 0, skippedAmbiguous: 0))

        let other = try await A.open(at: first.url, algorithmVersion: "brain.\(decomposed)")
        #expect("brain.\(composed)" == "brain.\(decomposed)", "Swift's String equality would call this the same version")
        let error = await storeError { _ = try await other.applications.apply(command) }
        guard case .identity(let conflict)? = error else {
            Issue.record("expected a version conflict, got \(String(describing: error))")
            return
        }
        #expect(conflict.storedFingerprint.utf8.starts(with: "v1/brain.\(composed)/".utf8))
        #expect(conflict.offeredFingerprint.utf8.starts(with: "v1/brain.\(decomposed)/".utf8))
        #expect(try await ledger() == before)
        #expect(try await first.texts("SELECT algorithm_version FROM brain_applications").map { Array($0.utf8) } == [Array("brain.\(composed)".utf8)])
        for memory in [other, same, first] { await memory.store.close() }
    }

    @Test("C2: two events whose ids are canonically equivalent but different bytes are two keys end to end: two applications, each answered by its own key")
    func unicodeEventsStayApart() async throws {
        let memory = try await A.open()
        try await memory.event(composed)
        try await memory.event(decomposed)
        let one = try A.observe(try await memory.sample(composed), A.controls(["Send"]))
        let two = try A.observe(try await memory.sample(decomposed), A.controls(["Send"]))
        #expect(one.key != two.key && !one.hasSameInput(as: two))
        #expect(try await memory.applications.apply(one).receipt == .committed)
        #expect(try await memory.applications.apply(two).receipt == .committed, "other bytes are another key, not a retry")
        #expect(try await memory.applications.apply(one).receipt == .alreadyApplied)
        #expect(try await memory.applications.apply(two).receipt == .alreadyApplied)
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 2)
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [2], "the second event saw the same control again")
        let stored = try #require(try await memory.applications.application(two.key))
        #expect(Array(stored.command.key.eventID.utf8) == Array(decomposed.utf8))
        await memory.store.close()
    }
}
