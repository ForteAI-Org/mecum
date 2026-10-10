//
//  ConsumerReadBackTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 10/10/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// ConsumerReadBackTests prove what a consumer of plan D1's facts (D2's builder) can read back from the
/// repositories once the archive reopens, written by the real producers (the tools over a session double)
/// and not by SQL: the task with its revisions and attempt, the calls in order with a batch's parent and
/// children, the arguments as admitted, the withheld values, the checks, the observations and the source
/// of a transferred fact. It also proves that one adapter reads what the other taught after a reopen.
@MainActor
@Suite("What a consumer reads back after the archive reopens")
struct ConsumerReadBackTests {

    private func tools(
        _ session: FactSession,
        stream: String,
        source: MemoryEventSource,
        trace: String?
    ) -> AutomationTools {
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: source, streamID: stream, traceID: trace, messageRef: trace)
        return tools
    }

    @Test("task, revisions, attempt, ordered calls with a batch's parent and children, admitted arguments, gaps, checks, observations and a transferred fact's source, all read back from the repositories")
    func everythingReadsBack() async throws {
        let place = try UnificationTests.place()
        try await UnificationTests.legacyArchive(in: place.profile("A"), stream: "mcp-A", elements: [W.format])
        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let session = FactSession(directory: place.shared)
        session.plans["Format"] = FactSession.Plan(outcome: ActOutcome(.honestMiss, "no Format"))
        let tools = tools(session, stream: "worker-1", source: .app, trace: "message-1")
        let id = JSONValue.string(session.id!.uuidString)
        let begun = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Sign in and save"),
            "inputs": .array([.object(["name": .string("file"), "value": .string("report.pdf")])]),
        ])).payload
        _ = try await tools.call("memory_task", .object([
            "operation": .string("update"), "goal": .string("Sign in, save and close"),
        ]))
        _ = try await tools.call("observe", .object(["session": id]))
        _ = try await tools.call("batch", .object(["session": id, "steps": .array([
            .object([
                "operation": .string("type_text"), "target": .string("Password"),
                "text": .string("Canary-Pass-7419")
            ]),
            .object(["operation": .string("act"), "target": .string("Format")]),
            .object(["operation": .string("act"), "target": .string("Save")]),
        ])]))
        let memory = MemoryService.shared(for: place.shared)
        await memory.unificationFinished()
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()

        let reopened = MemoryService(directory: place.shared)
        let producer = try TaskProducer(source: .app, streamID: "worker-1")
        let taskID   = try #require(begun["task"].string), attemptID = try #require(begun["attempt"].string)
        let task     = try #require(try await reopened.perform { try await $0.tasks.task(taskID, for: producer) })
        #expect(task.status == .open && task.currentRevision == 2)
        let first = try await reopened.perform { try await $0.tasks.revision(1, of: taskID, for: producer) }
        #expect(first?.content.goal == "Sign in and save" && first?.content.inputs.map(\.name) == ["file"])
        #expect(try await reopened.perform { try await $0.tasks.attempts(of: taskID, for: producer) }.count == 1)
        let attributed = try await reopened.perform { try await $0.tasks.calls(of: attemptID, for: producer) }
        #expect(attributed.count == 4, "the observation, the batch and its two started steps")

        let calls = try await reopened.calls(inTrace: "message-1")
        let batch = try #require(calls.first { $0.request.tool == .batch })
        let steps = calls.filter { $0.event.parentEventID == batch.event.eventID }
            .sorted { ($0.event.parentPosition ?? 0) < ($1.event.parentPosition ?? 0) }
        #expect(steps.map(\.progress.status) == [.completed, .completed, .skipped])
        #expect(steps.map(\.request.tool) == [.typeText, .act, .act])
        guard case .typeText(_, let typed, _, _) = steps[0].request else {
            Issue.record("the first step is not the typing")
            return
        }
        #expect(typed == ValueMinimization.marker, "the argument as admitted")
        let gaps = try await reopened.perform { try await $0.facts.redactions(of: steps[0].event.eventID) }
        #expect(gaps.contains { $0.reason == .secretTarget })
        let checks = try await reopened.perform { try await $0.facts.verifications(of: steps[0].event.eventID) }
        #expect(checks.map(\.check.condition) == [.valueReadBack])
        #expect(try await reopened.perform { try await $0.facts.recordingGaps(of: steps[0].event.eventID) }.isEmpty)
        let observation = try #require(calls.first { $0.request.tool == .observe })
        guard case .observation(let observed)? = observation.progress.result else {
            Issue.record("the observation has no sample")
            return
        }
        #expect(try await reopened.sample(observed.sample) != nil)

        let legacy = try rawRows("SELECT event_id FROM memory_events WHERE source = 'mcp' ORDER BY local_order",
                                 at: reopened.url)
        let transferred = try #require(legacy.first)
        let origin = try #require(try await reopened.origins(of: transferred).first)
        #expect(origin.originID == "mcp-profile:A" && origin.location == "MCP/Knowledge/A"
                    && origin.disposition == .added)
        #expect(try await reopened.origins(of: steps[0].event.eventID).isEmpty, "a fact written here has no origin")
        await reopened.close()
    }

    enum Direction: String, CaseIterable, Sendable {
        case appToMCP, mcpToApp
    }

    @Test("what one adapter's calls taught the Brain, the other adapter's observation reads after the archive reopens, both ways",
          arguments: Direction.allCases)
    func adaptersReadEachOther(direction: Direction) async throws {
        let directory = try W.directory()
        let (writer, reader): (MemoryEventSource, MemoryEventSource) =
            direction == .appToMCP ? (.app, .mcp) : (.mcp, .app)
        let taught = FactSession(directory: directory)
        // Open is in the window the reader's session observes.
        taught.plans["Open"] = FactSession.Plan(outcome: ActOutcome(.foundActed, "opened"),
                                               effect: .menuOpened(labels: ["Bold", "Italic"]))
        let teacher = tools(taught, stream: "teacher", source: writer, trace: nil)
        _ = try await teacher.call("act", .object([
            "session": .string(taught.id!.uuidString), "target": .string("Open")
        ]))
        let memory = MemoryService.shared(for: directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(directory)

        let reading = FactSession(directory: directory)
        reading.plans = [:]
        let learner = tools(reading, stream: "learner", source: reader, trace: nil)
        let answer = try await learner.call("observe", .object(["session": .string(reading.id!.uuidString)]))
        let text = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(text.contains("Bold") && text.contains("Italic"),
                "the reader's scene tells what Open opens: \(text.prefix(400))")
        await MemoryService.shared(for: directory).close()
    }
}
