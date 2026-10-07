//
//  AgentCallBatchSummaryTests.swift
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

/// A concluded batch's summary is the one its steps allow under the current producer
/// (`AutomationTools.call`, batch): a step is accepted when it found and acted, or when `set_toggle`
/// was already in the asked state (`acted_noop`); the first other outcome or error stops the batch,
/// and the steps after it are skipped. The summary says whether it ran to its end, how many steps it
/// attempted and how many it accepted; a summary its steps contradict is refused on the way in and
/// on the way out. It certifies nothing about a step's or a task's result.
@Suite("A batch summary agrees with its steps", .serialized)
struct AgentCallBatchSummaryTests {

    private typealias F = AgentCallFixtures

    private static let click  = AgentCallRequest.act(target: "A", verb: .click, value: nil, section: nil)
    private static let toggle = AgentCallRequest.act(target: "Enabled", verb: .setToggle, value: .on, section: nil)

    /// Records a batch of the requests, starts it, and moves each step to its end: an outcome kind,
    /// `nil` for an error, or skipped when the list runs out.
    private func run(_ memory: F.Memory, _ requests: [AgentCallRequest], _ ends: [ActOutcomeKind?]) async throws {
        let (batch, steps) = try F.batch("b", requests)
        _ = try await memory.calls.record(batch: batch, steps: steps)
        var moves = [AgentCallTransition("b", .started)]
        for (position, _) in requests.enumerated() {
            let id = "b.\(position)"
            if position < ends.count {
                moves.append(AgentCallTransition(id, .started))
                if let kind = ends[position] {
                    moves.append(AgentCallTransition(id, F.outcome(kind)))
                } else {
                    moves.append(AgentCallTransition(id, F.ended(.failed, .error(message: "Transport failed"))))
                }
            } else {
                moves.append(AgentCallTransition(id, F.ended(.skipped)))
            }
        }
        _ = try await memory.calls.advance(moves)
    }

    private func summary(_ stopped: Bool, _ attempted: Int, _ verified: Int) -> AgentCallTransition {
        AgentCallTransition("b", F.ended(.completed, .batch(stopped: stopped, attempted: attempted, verified: verified)))
    }

    @Test("the producer's own summaries are accepted: found_acted, a toggle's noop, a click's noop that stops, a stop on the last step, an executed prefix and a skipped suffix", arguments: [
        ("found", [click], [ActOutcomeKind.foundActed], false, 1, 1),
        ("toggle noop", [toggle], [.actedNoop], false, 1, 1),
        ("click noop stops", [click], [.actedNoop], true, 1, 0),
        ("stop on the last", [click, toggle, click], [.foundActed, .actedNoop, .honestMiss], true, 3, 2),
        ("prefix and skipped suffix", [click, click, click, click], [.foundActed, .ambiguous], true, 2, 1),
        ("all accepted", [toggle, click, toggle], [.actedNoop, .foundActed, .foundActed], false, 3, 3),
    ] as [(String, [AgentCallRequest], [ActOutcomeKind], Bool, Int, Int)])
    func producerSummaries(_ name: String, _ requests: [AgentCallRequest], _ kinds: [ActOutcomeKind], _ stopped: Bool,
                           _ attempted: Int, _ verified: Int) async throws {
        let memory = try await F.open()
        try await run(memory, requests, kinds)
        #expect(try await memory.calls.advance([summary(stopped, attempted, verified)]) == .committed, Comment(rawValue: name))
        #expect(try await memory.calls.advance([summary(stopped, attempted, verified)]) == .alreadyApplied, "the identical terminal retry")
        let other = await callError { _ = try await memory.calls.advance([summary(!stopped, attempted, verified)]) }
        #expect(other == .conflictingEnd(eventID: "b", stored: .completed, offered: .completed), "another summary after the end is a conflict")
        #expect(try await memory.calls.call("b")?.progress.result?.isExactly(.batch(stopped: stopped, attempted: attempted, verified: verified)) == true)
        await memory.store.close()
    }

    @Test("a summary its steps contradict is refused with nothing written: an honest miss counted as verified, a failure reported as run to its end, verified too high or too low, attempted wrong, an accepted run reported as stopped", arguments: [
        ("honest miss verified", [click], [ActOutcomeKind?.some(.honestMiss)], true, 1, 1),
        ("failed then skipped as completed", [click, click], [nil], false, 1, 0),
        ("verified too high", [click, click], [.foundActed, .actedUnverified], true, 2, 2),
        ("verified too low", [click, toggle], [.foundActed, .actedNoop], false, 2, 1),
        ("attempted counts a skipped step", [click, click], [.honestMiss], true, 2, 0),
        ("accepted run reported stopped", [click], [.foundActed], true, 1, 1),
        ("click noop as run to its end", [click], [.actedNoop], false, 1, 1),
    ] as [(String, [AgentCallRequest], [ActOutcomeKind?], Bool, Int, Int)])
    func contradictedSummaries(_ name: String, _ requests: [AgentCallRequest], _ ends: [ActOutcomeKind?], _ stopped: Bool,
                               _ attempted: Int, _ verified: Int) async throws {
        let memory = try await F.open()
        try await run(memory, requests, ends)
        let error = await callError { _ = try await memory.calls.advance([summary(stopped, attempted, verified)]) }
        #expect(error == .batchNotSettled(eventID: "b"), Comment(rawValue: name))
        #expect(try await memory.calls.call("b")?.progress.status == .started, "the refused summary wrote nothing")
        #expect(try await memory.calls.record(try F.call("after", .observe(full: false))) == .committed, "the store goes on")
        await memory.store.close()
    }

    @Test("a composite advance that ends a step and then states a contradicted summary is rolled back whole")
    func compositeRollback() async throws {
        let memory = try await F.open()
        let (batch, steps) = try F.batch("b", [Self.click, Self.click])
        _ = try await memory.calls.record(batch: batch, steps: steps)
        _ = try await memory.calls.advance([AgentCallTransition("b", .started), AgentCallTransition("b.0", .started),
                                            AgentCallTransition("b.0", F.outcome(.honestMiss))])
        let error = await callError {
            _ = try await memory.calls.advance([AgentCallTransition("b.1", F.ended(.skipped)), summary(true, 1, 1)])
        }
        #expect(error == .batchNotSettled(eventID: "b"))
        #expect(try await memory.calls.call("b.1")?.progress.status == .planned, "the skipped step of the refused group is not kept")
        #expect(try await memory.calls.advance([AgentCallTransition("b.1", F.ended(.skipped)), summary(true, 1, 0)]) == .committed)
        await memory.store.close()
    }

    @Test("a stored summary its steps contradict is refused by the reader, in a call, a trace and a batch's steps, and the store goes on")
    func storedContradiction() async throws {
        let memory = try await F.open()
        try await run(memory, [Self.click], [.honestMiss])
        #expect(try await memory.calls.advance([summary(true, 1, 0)]) == .committed)
        try await memory.store.write { transaction in
            try transaction.execute("UPDATE memory_agent_actions SET verified_count = 1 WHERE event_id = 'b'")
        }
        let refusal = AgentCallError.malformedCall(eventID: "b", malformation: .resultShape("batch summary"))
        #expect(await callError { _ = try await memory.calls.call("b") } == refusal)
        #expect(await callError { _ = try await memory.calls.calls(inTrace: "trace-1", after: nil, limit: 10) } == refusal)
        #expect(try await memory.calls.steps(ofBatch: "b").count == 1, "the steps themselves are well formed")
        try await memory.store.write { transaction in
            try transaction.execute("UPDATE memory_agent_actions SET verified_count = 0, result_kind = 'completed' WHERE event_id = 'b'")
        }
        #expect(await callError { _ = try await memory.calls.call("b") } == refusal)
        #expect(try await memory.calls.record(try F.call("after", .observe(full: false))) == .committed, "the store goes on")
        await memory.store.close()
    }

    @Test("cancellation and interruption keep their states and carry no summary")
    func cancelledAndInterrupted() async throws {
        let memory = try await F.open()
        try await run(memory, [Self.click, Self.click], [.foundActed])
        #expect(try await memory.calls.advance([AgentCallTransition("b", F.ended(.cancelled))]) == .committed)
        #expect(try await memory.calls.call("b")?.progress.result == nil)
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", F.ended(.cancelled, .batch(stopped: true, attempted: 1, verified: 1)))]) }
                == .invalidProgress(.resultForbidden))
        await memory.store.close()
    }
}
