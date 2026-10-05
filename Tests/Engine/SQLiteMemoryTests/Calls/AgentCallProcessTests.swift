//
//  AgentCallProcessTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The call contract across real processes: `memory-probe` records a call through
/// `SQLiteAgentCallRepository` in a process of its own, and this process offers the very same
/// record. Neither a crash after the commit nor two processes at once stores it twice. Only data is
/// retried here; no tool runs and no gesture is replayed.
@Suite("Agent calls across processes", .serialized)
struct AgentCallProcessTests {

    private typealias F = AgentCallFixtures

    /// The record `memory-probe call-record` builds.
    private func call(_ id: String, target: String) throws -> AgentCallRecord {
        try AgentCallRecord(
            event: MemoryEventRecord(eventID: id, source: .app, streamID: "worker", traceID: "trace-1", sessionID: F.session,
                                     kind: .action, app: F.app, occurredAtMS: F.t0),
            request: .act(target: target, verb: .click, value: nil, section: nil)
        )
    }

    @Test("a process that dies after committing a call and before answering: the same record answers alreadyApplied, with one row and one set of arguments")
    func diedAfterCommit() async throws {
        let memory = try await F.open()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(memory.url.path)").hasPrefix("opened "))
        probe.send("call-record-and-die e1 \(F.session) Send")
        #expect(try await probe.receive(waitingFor: "the end of the helper's output") == nil)
        #expect(try await probe.exit()?.reason == .uncaughtSignal)
        #expect(try await memory.calls.record(try call("e1", target: "Send")) == .alreadyApplied)
        #expect(try await memory.count("SELECT count(*) FROM memory_agent_actions") == 1)
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments WHERE event_id = 'e1'") == 2)
        #expect(try await memory.calls.call("e1")?.progress.status == .planned)
        await memory.store.close()
    }

    @Test("two processes recording one call at once store it once; other arguments under its event are a conflict in the other process too")
    func twoProcessesOneCall() async throws {
        let memory = try await F.open()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(memory.url.path)").hasPrefix("opened "))
        probe.send("call-record e1 \(F.session) Send")
        let local = try await memory.calls.record(try call("e1", target: "Send"))
        let remote = try #require(try await probe.receive(waitingFor: "the helper's record"))
        #expect([local == .committed ? "committed" : "alreadyApplied", remote].sorted() == ["alreadyApplied", "committed"])
        #expect(try await probe.ask("call-record e1 \(F.session) Send") == "alreadyApplied")
        #expect(try await probe.ask("call-record e1 \(F.session) Draft") == "error identity")
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments WHERE event_id = 'e1'") == 2)
        #expect(try await memory.calls.call("e1")?.request.isExactly(.act(target: "Send", verb: .click, value: nil, section: nil)) == true)
        await memory.store.close()
    }
}
