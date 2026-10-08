//
//  ObservedInputRepositoryTests.swift
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

/// The observed inputs and the stated correlations: every kind written with its event and read back
/// after reopening, the columns checked on their own, applied once, completed beside a capture
/// without rewriting it, refused on rows the contract does not admit; correlations stated, never
/// inferred, with roles and applications checked.
@Suite("Observed Watcher inputs and stated correlations", .serialized)
struct ObservedInputRepositoryTests {

    private typealias F = AttributionFixtures

    @Test("every kind is kept with its event and read back exactly after reopening; the stored columns are what was given, absent as NULL, never zero")
    func kindsRoundTrip() async throws {
        let memory = try await F.open()
        let inputs: [(String, MemoryEventRecord, ObservedInput)] = [
            ("i-click", F.watcherEvent("i-click", key: "seq-1", monotonicNS: 5_000), try F.click("Café\u{0}|")),
            ("i-scroll", F.watcherEvent("i-scroll", at: F.t0 + 1), try ObservedInput(kind: .scroll, sequenceNumber: 2, point: ScreenPoint(x: -0.0, y: 10),
                                                                                       scrollDelta: .init(dx: 0, dy: -3.5))),
            ("i-hover", F.watcherEvent("i-hover", at: F.t0 + 2, stream: "watcher-2"), try ObservedInput(kind: .hover, point: ScreenPoint(x: 1, y: 2))),
            ("i-focus", F.watcherEvent("i-focus", at: F.t0 + 3, app: nil), try ObservedInput(kind: .focus, targetPID: 412, windowTitle: "")),
            ("i-gap", F.watcherEvent("i-gap", at: F.t0 + 4), try ObservedInput(kind: .gap, gap: .init(first: 3, last: .max),
                                                                                  lostCritical: .max, lostCoalescible: 0)),
        ]
        for (_, event, input) in inputs {
            #expect(try await memory.inputs.record(try ObservedInputRecord(event: event, input: input)) == .committed)
        }
        let raw = try await memory.store.read { snapshot in
            try snapshot.query(
                """
                SELECT event_id, input_kind, typeof(sequence_number), point_x, window_title IS NULL, gap_last_sequence, lost_critical,
                       typeof(lost_coalescible), typeof(delta_x), before_status
                FROM memory_input_events ORDER BY event_id
                """, []) { row in
                [try row.text(0) ?? "", try row.text(1) ?? "", try row.text(2) ?? "", row.real(3).map { "\($0)" } ?? "NULL",
                 "\(row.integer(4) ?? -1)", row.integer(5).map(String.init) ?? "NULL", row.integer(6).map(String.init) ?? "NULL",
                 try row.text(7) ?? "", try row.text(8) ?? "", try row.text(9) ?? "NULL"].joined(separator: " ")
            }
        }
        #expect(raw == [
            "i-click click integer 812.5 0 NULL NULL null null complete",
            "i-focus focus null NULL 0 NULL NULL null null NULL",
            "i-gap gap null NULL 1 9223372036854775807 9223372036854775807 integer null NULL",
            "i-hover hover null 1.0 1 NULL NULL null null NULL",
            "i-scroll scroll integer 0.0 1 NULL NULL null real NULL",
        ])
        await memory.store.close()
        let reopened = try await F.open(at: memory.url)
        for (id, event, input) in inputs {
            let back = try #require(try await reopened.inputs.input(id))
            #expect(back.input.isExactly(input), Comment(rawValue: id))
            #expect(back.event.hasSameImmutableContent(as: event), Comment(rawValue: id))
        }
        #expect(try await reopened.inputs.input("i-focus")?.event.app == nil, "an unknown application stays unknown")
        #expect(try await reopened.inputs.input("nothing") == nil)
        await reopened.store.close()
    }

    @Test("the same input is already applied; other detail or other event content under its id is a conflict with nothing written, and a reused source key too")
    func idempotency() async throws {
        let memory = try await F.open()
        let record = try ObservedInputRecord(event: F.watcherEvent("i1", key: "seq-1"), input: try F.click("Café"))
        #expect(try await memory.inputs.record(record) == .committed)
        #expect(try await memory.inputs.record(record) == .alreadyApplied)
        let before = try await memory.ledger()
        var moved = record.event
        moved.occurredAtMS += 1
        let others = [
            try ObservedInputRecord(event: record.event, input: try F.click("Cafe\u{301}")),
            try ObservedInputRecord(event: record.event, input: try F.click("Café", sequence: nil)),
            try ObservedInputRecord(event: record.event, input: try F.click("Café", sequence: 0)),
            try ObservedInputRecord(event: record.event, input: try ObservedInput(kind: .hover, point: ScreenPoint(x: 812.5, y: 433))),
            try ObservedInputRecord(event: moved, input: try F.click("Café")),
            try ObservedInputRecord(event: F.watcherEvent("i2", key: "seq-1"), input: try F.click("Café")),
        ]
        for other in others {
            let error = await storeError { _ = try await memory.inputs.record(other) }
            guard case .identity? = error else {
                Issue.record("expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        #expect(try await memory.ledger() == before)
        #expect(try await memory.inputs.input("i1")?.input.isExactly(try F.click("Café")) == true)
        await memory.store.close()
    }

    @Test("an input whose event a capture stored first is completed with its detail: the samples, their quality and the event's summary stay as they were")
    func besideCaptures() async throws {
        let memory = try await F.open()
        let event = F.watcherEvent("i1")
        #expect(try await memory.captures.record(event) == .committed)
        let before = CaptureSample(key: CaptureSampleKey(eventID: "i1", phase: .before), windowTitle: "Inbox", sessionRevision: 3,
                                   surface: .window, quality: .unknown, elements: [])
        #expect(try await memory.captures.record(before) == .committed)
        let summary = try await memory.captures.event("i1")?.captureStatus
        var offered = event
        offered.captureStatus = .complete
        #expect(try await memory.inputs.record(try ObservedInputRecord(event: offered, input: try F.click())) == .committed)
        #expect(try await memory.captures.sample(before.key) == before)
        #expect(try await memory.captures.sample(CaptureSampleKey(eventID: "i1", phase: .after)) == nil, "no after sample is made up")
        #expect(try await memory.captures.event("i1")?.captureStatus == summary)
        await memory.store.close()
    }

    @Test("rows the contract does not admit are refused by the reader with a typed error: an unknown kind or status, a click without its point, an infinite coordinate, half a frame, a reversed gap, a process id out of range; the store goes on")
    func malformedRows() async throws {
        let memory = try await F.open()
        let cases: [(String, String, EventFactError.Malformation)] = [
            ("kind", "input_kind, point_x, point_y) VALUES (?, 'drag', 1, 1)", .unknownCode(column: "input_kind", code: "drag")),
            ("pointless", "input_kind) VALUES (?, 'click')", .invalid(.shape(field: "point"))),
            ("infinite", "input_kind, point_x, point_y) VALUES (?, 'hover', 9e999, 1)", .invalid(.notFinite)),
            ("frame", "input_kind, window_x, window_y) VALUES (?, 'focus', 0, 0)", .invalid(.shape(field: "window_frame"))),
            ("gap", "input_kind, gap_first_sequence, gap_last_sequence) VALUES (?, 'gap', 9, 3)", .invalid(.outOfOrder(field: "gap_last_sequence"))),
            ("half-gap", "input_kind, gap_first_sequence) VALUES (?, 'gap', 9)", .invalid(.shape(field: "gap"))),
            ("status", "input_kind, point_x, point_y, before_status) VALUES (?, 'hover', 1, 1, 'fine')", .unknownCode(column: "before_status", code: "fine")),
            ("pid", "input_kind, target_pid) VALUES (?, 'focus', 0)", .invalid(.outOfRange(field: "target_pid"))),
        ]
        for (id, columns, _) in cases {
            _ = try await memory.captures.record(F.watcherEvent(id, at: F.t0 + Int64(id.count)))
            try await memory.plant([("INSERT INTO memory_input_events (event_id, \(columns)", [.text(id)])])
        }
        for (id, _, malformation) in cases {
            #expect(await factError { _ = try await memory.inputs.input(id) }
                    == .malformedRow(table: "memory_input_events", id: id, malformation: malformation), Comment(rawValue: id))
        }
        #expect(try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("after"), input: try F.click())) == .committed)
        await memory.store.close()
    }

    @Test("a correlation is stated once per Watcher input: retried it is already applied, another attribution is a conflict; roles, existence and applications are checked; it moves nothing in the brain")
    func correlations() async throws {
        let memory = try await F.open()
        _ = try await memory.calls.record(try F.agentCall("a1"))
        _ = try await memory.calls.record(try F.agentCall("a2", at: F.t0 + 5))
        _ = try await memory.calls.record(try F.agentCall("a-elsewhere", app: AppContextIdentity(bundleID: "test.other")))
        _ = try await memory.calls.record(try F.agentCall("a-unknown", app: nil))
        for (id, ms) in [("w1", F.t0 + 40), ("w2", F.t0 + 10), ("w3", F.t0 + 50)] {
            _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent(id, at: ms), input: try F.click()))
        }
        _ = try await memory.verifications.record(try VerificationRecord(event: F.verificationEvent("v1"), scope: .call, method: .sceneText, verdict: .unknown))
        let brain = try await memory.brainRows()
        let link = try ActionCorrelation(watcherEventID: "w1", agentEventID: "a1", basis: .reported, timeOffsetMS: 40, explanation: "carried the call's id")
        #expect(try await memory.inputs.record(link) == .committed)
        #expect(try await memory.inputs.record(link) == .alreadyApplied)
        let other = await storeError { _ = try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w1", agentEventID: "a2", basis: .reported, timeOffsetMS: 40,
                                                                                              explanation: "carried the call's id")) }
        guard case .identity? = other else {
            Issue.record("another attribution must be a conflict, got \(String(describing: other))")
            return
        }
        #expect(await factError { _ = try await memory.inputs.record(try ActionCorrelation(watcherEventID: "a1", agentEventID: "w2", basis: .assigned)) }
                == .wrongEvent(eventID: "a1", expected: "a watcher input"))
        #expect(await factError { _ = try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w2", agentEventID: "v1", basis: .assigned)) }
                == .wrongEvent(eventID: "v1", expected: "an app or cli action"))
        #expect(await factError { _ = try await memory.inputs.record(try ActionCorrelation(watcherEventID: "nobody", agentEventID: "a1", basis: .assigned)) }
                == .missingEvent(eventID: "nobody"))
        #expect(await factError { _ = try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w2", agentEventID: "a-elsewhere", basis: .assigned)) }
                == .appMismatch(watcherEventID: "w2", agentEventID: "a-elsewhere"))
        #expect(try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w2", agentEventID: "a-unknown", basis: .assigned)) == .committed,
                "an unknown application is no contradiction, and nothing is adjusted to match")
        #expect(try await memory.inputs.record(try ActionCorrelation(watcherEventID: "w3", agentEventID: "a1", basis: .assigned, timeOffsetMS: nil)) == .committed)
        #expect(try await memory.inputs.correlations(ofAgentEvent: "a1").map(\.watcherEventID) == ["w1", "w3"], "in the Watcher events' local order")
        #expect(try await memory.inputs.correlation(ofWatcherEvent: "w3")?.timeOffsetMS == nil, "an unknown offset stays unknown")
        #expect(try await memory.inputs.correlation(ofWatcherEvent: "w1")?.isExactly(link) == true)
        #expect(try await memory.brainRows() == brain, "a correlation moves no count, evidence or application")

        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w4", at: F.t0 + 60), input: try F.click()))
        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w5", at: F.t0 + 61), input: try F.click()))
        try await memory.plant([("INSERT INTO memory_action_correlations (watcher_event_id, agent_event_id, basis_kind) VALUES ('w4', 'a2', 'proximity')", []),
                                ("INSERT INTO memory_action_correlations (watcher_event_id, agent_event_id, basis_kind, time_offset_ms) VALUES ('w5', 'a2', 'assigned', 9e999)", [])])
        #expect(await factError { _ = try await memory.inputs.correlation(ofWatcherEvent: "w4") }
                == .malformedRow(table: "memory_action_correlations", id: "w4", malformation: .unknownCode(column: "basis_kind", code: "proximity")))
        #expect(await factError { _ = try await memory.inputs.correlation(ofWatcherEvent: "w5") }
                == .malformedRow(table: "memory_action_correlations", id: "w5", malformation: .invalid(.notFinite)))
        await memory.store.close()
    }
}
