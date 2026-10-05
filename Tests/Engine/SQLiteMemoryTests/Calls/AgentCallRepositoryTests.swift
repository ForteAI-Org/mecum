//
//  AgentCallRepositoryTests.swift
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

/// The call repository: a call's event, row and arguments written whole, read back exactly after
/// reopening, applied once by identity, moved through its states without an invented success, and
/// a batch with its steps created and concluded as one group.
@Suite("The agent call repository", .serialized)
struct AgentCallRepositoryTests {

    private typealias F = AgentCallFixtures

    /// One request of every tool and the variants the tools decode, as `AgentCallContractTests` has them.
    private static let requests: [AgentCallRequest] = [
        .status, .windows(app: nil), .windows(app: "Mail"), .apps(query: nil), .apps(query: "com.apple"),
        .openSession(app: "Calculator", window: nil), .openSession(app: "Mail", window: "Inbox – 3"), .observe,
        .act(target: "Send", verb: .click, value: nil, section: nil), .act(target: "row 3", verb: .doubleClick, value: nil, section: "Sidebar"),
        .act(target: "Body", verb: .tripleClick, value: nil, section: nil), .act(target: "File", verb: .rightClick, value: nil, section: nil),
        .act(target: "Wi-Fi", verb: .setToggle, value: .on, section: nil), .act(target: "Wi-Fi", verb: .setToggle, value: .off, section: "Network"),
        .select(control: "Format", item: "H.264"),
        .typeText(target: "To", text: "Zoë ☕️ 東京 cafe\u{301}", section: nil, replace: true),
        .typeText(target: "Body", text: "a\u{0}b", section: "Compose", replace: false),
        .pressKey(key: .return, modifiers: [], count: 1), .pressKey(key: .character("n"), modifiers: [.shift, .cmd], count: 3),
        .scroll(direction: .down, lines: 3, target: nil, section: nil), .scroll(direction: .up, lines: 50, target: "List", section: "Main"),
        .drag(from: "A", to: .target("B"), section: nil), .drag(from: "Slider", to: .offset(dx: -0.0, dy: 12.5), section: "Panel"),
        .contextMenu(target: "Paragraph", item: "Copia", section: nil), .closeSession,
    ]

    @Test("the fourteen signatures and their variants, and a batch of the seven step variants, are read back exactly after reopening, in local order, with typed rows only")
    func signaturesRoundTrip() async throws {
        let memory = try await F.open()
        for (index, request) in Self.requests.enumerated() {
            #expect(try await memory.calls.record(try F.call("c\(index)", request, at: F.t0 + Int64(index))) == .committed)
        }
        let (batch, steps) = try F.batch("b", F.sevenSteps, at: F.t0 + 100)
        #expect(try await memory.calls.record(batch: batch, steps: steps) == .committed)
        let rows = Self.requests.map(\.arguments.count).reduce(0, +) + F.sevenSteps.map(\.arguments.count).reduce(0, +)
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments") == Int64(rows))
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments WHERE value_kind NOT IN ('text', 'integer', 'real', 'boolean')") == 0)
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments WHERE event_id = 'b'") == 0, "a batch's steps are child calls, not arguments")
        await memory.store.close()

        let reopened = try await F.open(at: memory.url)
        for (index, request) in Self.requests.enumerated() {
            let call = try #require(try await reopened.calls.call("c\(index)"))
            #expect(call.request.isExactly(request), Comment(rawValue: "c\(index) \(request.tool.rawValue)"))
            #expect(call.event.hasSameImmutableContent(as: F.event("c\(index)", at: F.t0 + Int64(index))))
            #expect(call.progress.status == .planned && call.progress.result == nil && call.progress.endedAtMS == nil)
            #expect(call.contractVersion == 1 && call.requestedSteps == nil)
        }
        let trace = try await reopened.calls.calls(inTrace: "trace-1", after: nil, limit: 100)
        #expect(trace.map(\.event.eventID) == Self.requests.indices.map { "c\($0)" } + ["b"] + (0..<7).map { "b.\($0)" })
        #expect(trace.map(\.localOrder) == trace.map(\.localOrder).sorted())
        let page = try await reopened.calls.calls(inTrace: "trace-1", after: trace[1].localOrder, limit: 3)
        #expect(page.map(\.event.eventID) == ["c2", "c3", "c4"])
        let stepsBack = try await reopened.calls.steps(ofBatch: "b")
        #expect(stepsBack.map(\.event.parentPosition) == (0..<7).map(Optional.some))
        for (step, request) in zip(stepsBack, F.sevenSteps) { #expect(step.request.isExactly(request)) }
        #expect(try await reopened.calls.call("b")?.requestedSteps == 7)
        #expect(try await reopened.calls.call("nobody") == nil)
        await reopened.store.close()
    }

    @Test("the same call offered again is already applied, even after it advanced; other arguments, other event content or a reused source key are conflicts that write nothing")
    func idempotency() async throws {
        let memory = try await F.open()
        var keyed = F.event("e1", key: "k1")
        let call = try AgentCallRecord(event: keyed, request: .act(target: "Send", verb: .click, value: nil, section: nil))
        #expect(try await memory.calls.record(call) == .committed)
        #expect(try await memory.calls.advance([AgentCallTransition("e1", .started),
                                                AgentCallTransition("e1", F.outcome(.actedUnverified))]) == .committed)
        #expect(try await memory.calls.record(call) == .alreadyApplied)
        let before = try await memory.ledger()
        let others: [AgentCallRecord] = [
            try AgentCallRecord(event: keyed, request: .act(target: "Send ", verb: .click, value: nil, section: nil)),
            try AgentCallRecord(event: keyed, request: .act(target: "Send", verb: .doubleClick, value: nil, section: nil)),
            try AgentCallRecord(event: keyed, request: .act(target: "Send", verb: .click, value: nil, section: "")),
            try AgentCallRecord(event: keyed, request: .contextMenu(target: "Send", item: "Copy", section: nil)),
        ]
        for other in others {
            let error = await storeError { _ = try await memory.calls.record(other) }
            guard case .identity(let report)? = error else {
                Issue.record("expected a conflict, got \(String(describing: error))")
                continue
            }
            #expect(report.identity == "e1" && report.storedFingerprint != report.offeredFingerprint)
        }
        keyed.occurredAtMS += 1
        let moved = await storeError { _ = try await memory.calls.record(try AgentCallRecord(event: keyed, request: call.request)) }
        guard case .identity? = moved else {
            Issue.record("expected a conflict on the event, got \(String(describing: moved))")
            return
        }
        let reused = try AgentCallRecord(event: F.event("e2", key: "k1"), request: call.request)
        let key = await storeError { _ = try await memory.calls.record(reused) }
        guard case .identity(let report)? = key else {
            Issue.record("expected a conflict on the source key, got \(String(describing: key))")
            return
        }
        #expect(report.identity == "app:worker-1:k1")
        #expect(try await memory.ledger() == before)
        let back = try #require(try await memory.calls.call("e1"))
        #expect(back.progress.isExactly(F.outcome(.actedUnverified)), "the stored state stays as it advanced")
        await memory.store.close()
    }

    @Test("an event a capture stored first is completed with the call and never rewritten: its summary and its sample stay; an event of another kind under the id is a conflict")
    func eventFromCaptures() async throws {
        let memory = try await F.open()
        let event = F.event("e1")
        #expect(try await memory.captures.record(event) == .committed)
        let sample = CaptureSample(key: CaptureSampleKey(eventID: "e1", phase: .before), windowTitle: "Inbox", sessionRevision: 4,
                                   surface: .window, quality: .unknown, elements: [])
        #expect(try await memory.captures.record(sample) == .committed)
        var offered = event
        offered.captureStatus = .notApplicable
        #expect(try await memory.calls.record(try AgentCallRecord(event: offered, request: .observe)) == .committed)
        let back = try #require(try await memory.calls.call("e1"))
        #expect(back.event.captureStatus == .unknown, "the summary its samples made is kept")
        #expect(try await memory.captures.sample(sample.key) == sample)
        #expect(try await memory.calls.record(try AgentCallRecord(event: offered, request: .observe)) == .alreadyApplied)

        var observation = F.event("o1")
        observation.kind = .observation
        #expect(try await memory.captures.record(observation) == .committed)
        let before = try await memory.ledger()
        let error = await storeError { _ = try await memory.calls.record(try F.call("o1", .observe)) }
        guard case .identity? = error else {
            Issue.record("expected a conflict on the event's kind, got \(String(describing: error))")
            return
        }
        #expect(try await memory.ledger() == before)
        await memory.store.close()
    }

    @Test("states move only forward: retries of the stored state, a regression or a skipped state refused, another end a conflict, an unknown call missing, and a group of moves all or nothing")
    func transitions() async throws {
        let memory = try await F.open()
        for id in ["a", "b", "c"] { _ = try await memory.calls.record(try F.call(id, .select(control: "Format", item: "H.264"))) }
        #expect(try await memory.calls.advance([AgentCallTransition("a", .started)]) == .committed)
        #expect(try await memory.calls.advance([AgentCallTransition("a", .started)]) == .alreadyApplied)
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("a", AgentCallProgress(.planned))]) }
                == .invalidTransition(eventID: "a", from: .started, to: .planned))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", F.outcome(.foundActed))]) }
                == .invalidTransition(eventID: "b", from: .planned, to: .completed))
        let done = F.outcome(.ambiguous, "Two Format controls.")
        #expect(try await memory.calls.advance([AgentCallTransition("a", done)]) == .committed)
        #expect(try await memory.calls.advance([AgentCallTransition("a", done)]) == .alreadyApplied)
        for other in [F.outcome(.ambiguous, "Two Format controls!"), F.ended(.failed, .error(message: "x")), F.ended(.interrupted)] {
            let error = await callError { _ = try await memory.calls.advance([AgentCallTransition("a", other)]) }
            guard case .conflictingEnd(eventID: "a", stored: .completed, _)? = error else {
                Issue.record("expected a conflicting end, got \(String(describing: error))")
                continue
            }
        }
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("a", .started)]) }
                == .invalidTransition(eventID: "a", from: .completed, to: .started))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("zz", .started)]) } == .missingCall(eventID: "zz"))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", AgentCallProgress(.completed, endedAtMS: 1))]) }
                == .invalidProgress(.resultMismatch))

        // The second move is refused, so the first is not kept either.
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", .started), AgentCallTransition("c", F.outcome(.foundActed))]) }
                == .invalidTransition(eventID: "c", from: .planned, to: .completed))
        #expect(try await memory.calls.call("b")?.progress.status == .planned)
        #expect(try await memory.calls.advance([AgentCallTransition("b", .started), AgentCallTransition("b", F.ended(.interrupted))]) == .committed)
        #expect(try await memory.calls.advance([AgentCallTransition("c", F.ended(.skipped))]) == .committed)
        let ends = try await memory.store.read { snapshot in
            try snapshot.query("SELECT event_id, execution_status, completed_at_ms IS NOT NULL, result_kind FROM memory_agent_actions ORDER BY event_id") { row in
                "\(try row.text(0) ?? "") \(try row.text(1) ?? "") \(row.integer(2) ?? -1) \(try row.text(3) ?? "NULL")"
            }
        }
        #expect(ends == ["a completed 1 ambiguous", "b interrupted 1 NULL", "c skipped 1 NULL"])
        #expect(try await memory.calls.record(try F.call("d", .closeSession)) == .committed, "the store goes on after every refusal")
        await memory.store.close()
    }

    @Test("a partial batch keeps the first outcome, the second failure and the third step skipped, concluded together as stopped with the counts its steps give; a step never runs before its batch, and a batch never concludes over an open step")
    func partialBatch() async throws {
        let memory = try await F.open()
        let (batch, steps) = try F.batch("b", [.act(target: "Send", verb: .click, value: nil, section: nil),
                                               .select(control: "Format", item: "H.264"),
                                               .typeText(target: "To", text: "x", section: nil, replace: true)])
        #expect(try await memory.calls.record(batch: batch, steps: steps) == .committed)
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b.0", .started)]) } == .stepBeforeBatch(eventID: "b.0"))
        #expect(try await memory.calls.advance([AgentCallTransition("b", .started), AgentCallTransition("b.0", .started),
                                                AgentCallTransition("b.0", F.outcome(.foundActed, "Clicked Send."))]) == .committed)
        #expect(try await memory.calls.advance([AgentCallTransition("b.1", .started),
                                                AgentCallTransition("b.1", F.ended(.failed, .error(message: "Format is not visible.")))]) == .committed)
        let stopped = F.ended(.completed, .batch(stopped: true, attempted: 2, verified: 1))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", stopped)]) } == .batchNotSettled(eventID: "b"),
                "the third step is still planned")
        for wrong in [AgentCallResult.batch(stopped: true, attempted: 3, verified: 1), .batch(stopped: true, attempted: 2, verified: 2)] {
            #expect(await callError {
                _ = try await memory.calls.advance([AgentCallTransition("b.2", F.ended(.skipped)), AgentCallTransition("b", F.ended(.completed, wrong))])
            } == .batchNotSettled(eventID: "b"))
        }
        #expect(try await memory.calls.call("b.2")?.progress.status == .planned, "the refused group left the third step as it was")
        #expect(try await memory.calls.advance([AgentCallTransition("b.2", F.ended(.skipped)), AgentCallTransition("b", stopped)]) == .committed)
        let back = try await memory.calls.steps(ofBatch: "b")
        #expect(back.map(\.progress.status) == [.completed, .failed, .skipped])
        #expect(back[0].progress.result?.isExactly(.outcome(.foundActed, message: "Clicked Send.")) == true)
        #expect(back[1].progress.result?.isExactly(.error(message: "Format is not visible.")) == true)
        #expect(back[2].progress.result == nil, "a skipped step is not presented as executed")
        let parent = try #require(try await memory.calls.call("b"))
        #expect(parent.progress.isExactly(stopped) && parent.requestedSteps == 3)
        let raw = try await memory.store.read { snapshot in
            try snapshot.query("SELECT execution_status, result_kind, requested_count, attempted_count, verified_count FROM memory_agent_actions WHERE event_id = 'b'") { row in
                "\(try row.text(0) ?? "") \(try row.text(1) ?? "") \(row.integer(2) ?? -1) \(row.integer(3) ?? -1) \(row.integer(4) ?? -1)"
            }
        }
        #expect(raw == ["completed stopped 3 2 1"], "the batch's stopped result is apart from the call's completed status")
        await memory.store.close()
    }

    @Test("a batch is checked whole before anything is written: a step that is no batch step, a step of another app, session or position, no steps, or a step offered alone are refused with nothing stored; offered again it is one batch, and other steps under it a conflict")
    func batchValidation() async throws {
        let memory = try await F.open()
        let (batch, steps) = try F.batch("b", F.sevenSteps)
        func refused(_ offered: [AgentCallRecord], _ invalidity: AgentCallError.Invalidity) async {
            #expect(await callError { _ = try await memory.calls.record(batch: batch, steps: offered) } == .invalidBatch(invalidity))
        }
        await refused([], .batchWithoutSteps)
        var foreign = steps
        foreign[2] = try AgentCallRecord(event: F.event("b.2", parent: "b", position: 2, app: AppContextIdentity(bundleID: "other.app")),
                                         request: F.sevenSteps[2])
        await refused(foreign, .stepContext(position: 2, field: "app"))
        var elsewhere = steps
        elsewhere[1] = try AgentCallRecord(event: F.event("b.1", session: "another-session", parent: "b", position: 1), request: F.sevenSteps[1])
        await refused(elsewhere, .stepContext(position: 1, field: "session"))
        var misplaced = steps
        misplaced[3] = try AgentCallRecord(event: F.event("b.3", parent: "b", position: 4), request: F.sevenSteps[3])
        await refused(misplaced, .stepParent(position: 3))
        var observing = steps
        observing[0] = try AgentCallRecord(event: F.event("b.0", parent: "b", position: 0), request: .observe)
        await refused(observing, .notABatchStep(position: 0, tool: .observe))
        #expect(await callError { _ = try await memory.calls.record(batch) } == .invalidRequest(.batchOutsideBatchRecord))
        #expect(await callError { _ = try await memory.calls.record(steps[0]) } == .invalidRequest(.stepOutsideBatch))
        #expect(try await memory.ledger() == [0, 0, 0, 0])

        #expect(try await memory.calls.record(batch: batch, steps: steps) == .committed)
        #expect(try await memory.calls.record(batch: batch, steps: steps) == .alreadyApplied)
        let before = try await memory.ledger()
        var changed = steps
        changed[6] = try AgentCallRecord(event: F.event("b.6", at: F.t0 + 7, parent: "b", position: 6),
                                         request: .contextMenu(target: "Paragraph", item: "Paste", section: nil))
        for other in [changed, Array(steps.prefix(6))] {
            let error = await storeError { _ = try await memory.calls.record(batch: batch, steps: other) }
            guard case .identity? = error else {
                Issue.record("expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        #expect(try await memory.ledger() == before)
        await memory.store.close()
    }

    @Test("a batch whose third step collides with a stored event of another kind is rolled back whole: no batch, no step, no argument")
    func rollback() async throws {
        let memory = try await F.open()
        var observation = F.event("b.2", parent: nil, position: nil)
        observation.kind = .observation
        _ = try await memory.captures.record(observation)
        let before = try await memory.ledger()
        let (batch, steps) = try F.batch("b", Array(F.sevenSteps.prefix(4)))
        let error = await storeError { _ = try await memory.calls.record(batch: batch, steps: steps) }
        guard case .identity? = error else {
            Issue.record("expected a conflict on the third step's event, got \(String(describing: error))")
            return
        }
        #expect(try await memory.ledger() == before)
        #expect(try await memory.calls.call("b") == nil)
        #expect(try await memory.calls.call("b.0") == nil)
        await memory.store.close()
    }

    @Test("stored rows the contract does not admit are refused by the reader with a typed error, and the store goes on")
    func malformedRows() async throws {
        let memory = try await F.open()
        _ = try await memory.calls.record(try F.call("seed", .status))
        func plant(_ id: String, tool: String = "act", version: Int64 = 1, status: String = "planned", extra: String = "",
                   arguments: [(String, Int64, String, SQLiteValue)]) async throws {
            try await memory.store.write { transaction in
                try transaction.execute(
                    "INSERT INTO memory_events (event_id, source, source_stream_id, event_kind, app_id, occurred_at_ms, capture_status, session_id) VALUES (?, 'app', 'w', 'action', 1, 0, 'unknown', 's')",
                    [.text(id)])
                try transaction.execute(
                    "INSERT INTO memory_agent_actions (event_id, app_id, tool_kind, contract_version, execution_status\(extra.isEmpty ? "" : ", " + extra.split(separator: "=")[0])) VALUES (?, 1, ?, ?, ?\(extra.isEmpty ? "" : ", " + extra.split(separator: "=")[1]))",
                    [.text(id), .text(tool), .integer(version), .text(status)])
                for (name, position, kind, value) in arguments {
                    let column = ["text": "text_value", "integer": "integer_value", "real": "real_value", "boolean": "boolean_value"][kind]!
                    try transaction.execute(
                        "INSERT INTO memory_operation_arguments (event_id, app_id, argument_name, position, value_kind, \(column)) VALUES (?, 1, ?, ?, ?, ?)",
                        [.text(id), .text(name), .integer(position), .text(kind), value])
                }
            }
        }
        let click: [(String, Int64, String, SQLiteValue)] = [("target", 0, "text", .text("Send")), ("verb", 0, "text", .text("click"))]
        try await plant("tool", tool: "run_menu", arguments: [])
        try await plant("version", version: 2, arguments: click)
        try await plant("code", arguments: [("target", 0, "text", .text("Send")), ("verb", 0, "text", .text("tap"))])
        try await plant("kind", arguments: [("target", 0, "integer", .integer(1)), ("verb", 0, "text", .text("click"))])
        try await plant("gap", tool: "press_key", arguments: [("key", 0, "text", .text("tab")), ("modifiers", 1, "text", .text("cmd")),
                                                               ("count", 0, "integer", .integer(1))])
        try await plant("result", status: "completed", extra: "completed_at_ms=5", arguments: click)
        try await plant("verdict", status: "completed", extra: "result_kind='great'", arguments: click)
        let expected: [(String, AgentCallError)] = [
            ("tool", .malformedCall(eventID: "tool", malformation: .unknownTool("run_menu"))),
            ("version", .unsupportedContractVersion(eventID: "version", version: 2)),
            ("code", .malformedCall(eventID: "code", malformation: .unknownCode(argument: "verb", code: "tap"))),
            ("kind", .malformedCall(eventID: "kind", malformation: .argumentKindMismatch("target"))),
            ("gap", .malformedCall(eventID: "gap", malformation: .positionsNotContiguous("modifiers"))),
            ("result", .malformedCall(eventID: "result", malformation: .resultShape("resultMismatch"))),
            ("verdict", .malformedCall(eventID: "verdict", malformation: .unknownCode(argument: "result_kind", code: "great"))),
        ]
        for (id, error) in expected {
            #expect(await callError { _ = try await memory.calls.call(id) } == error, Comment(rawValue: id))
        }
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("code", .started)]) } == nil,
                "a move reads the call's row, not its arguments")
        #expect(try await memory.calls.record(try F.call("after", .observe)) == .committed)
        #expect(try await memory.calls.call("after")?.progress.status == .planned)
        await memory.store.close()
    }

    @Test("two stores recording one call at once conclude it once: one commit, one already applied, one set of arguments")
    func twoWriters() async throws {
        let first  = try await F.open()
        let second = try await F.open(at: first.url)
        let call = try F.call("e1", .drag(from: "Clip", to: .offset(dx: 40, dy: -2.5), section: "Timeline"))
        async let a = first.calls.record(call)
        async let b = second.calls.record(call)
        let receipts = try await [a, b]
        #expect(receipts.filter { $0 == .committed }.count == 1 && receipts.filter { $0 == .alreadyApplied }.count == 1)
        #expect(try await first.count("SELECT count(*) FROM memory_operation_arguments WHERE event_id = 'e1'") == Int64(call.request.arguments.count))
        #expect(try await first.count("SELECT count(*) FROM memory_agent_actions") == 1)
        await second.store.close()
        await first.store.close()
    }
}
