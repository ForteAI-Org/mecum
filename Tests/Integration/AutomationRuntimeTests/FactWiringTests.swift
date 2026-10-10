//
//  FactWiringTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// FactSession is a session with a memory whose operations answer what a test planned, with the check
/// the engine's oracle would have made, and report their perceptions to the call's recorder as the engine
/// does. It counts every gesture that reached the application, so a test proves what was never replayed.
@MainActor
final class FactSession: AutomationSessionOperating {

    struct Plan {
        var outcome: ActOutcome
        var attempt: ActionAttempt = .delivered
        var effect : SceneEffect?
        var fails  : Bool = false
    }

    let directory: URL
    var id: UUID? = UUID()
    /// Every gesture that reached the application, in order.
    private(set) var gestures: [String] = []
    var plans: [String: Plan] = [:]
    var typedLabel: String?

    init(directory: URL) { self.directory = directory }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { W.bundle }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        throw AutomationFailure("not here")
    }

    func observe() async throws -> SceneSnapshot {
        let window = W.window([W.open, W.save] + (typedLabel.map { [Self.field($0)] } ?? []))
        return await (CallRecorder.current?.observe(window) ?? window.scene)
    }

    static func field(_ value: String) -> SceneElement {
        SceneElement(
            id: "field|name",
            kind: .control,
            label: value,
            bounds: NormalizedRect(x: 0.6, y: 0.1, width: 0.2, height: 0.04),
            role: "AXTextField",
            labelOrigin: .value
        )
    }

    func act(
        target: String,
        verb: ActionVerb,
        section: String?,
        desiredState: ControlState?
    ) async throws -> ActOutcome {
        let plan = plans[target] ?? Plan(outcome: ActOutcome(.foundActed, "clicked '\(target)'", check: OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: .passed,
            observed: "elementsAppeared",
            limits: [.windowWide, .noExpectation],
            performed: .requested,
            target: OperationCheck.Target(
                elementID: "control|\(target.lowercased())",
                role: "AXButton",
                label: target,
                section: nil
            )
        )))
        if plan.fails { gestures.append(target); throw AutomationFailure("the seat stopped") }
        if plan.attempt == .delivered || plan.outcome.check?.performed == .substitute {
            gestures.append(plan.outcome.check?.substitute ?? target)
        }
        await CallRecorder.current?.record(ActionRecord(
            bundleID: W.bundle,
            element: W.button(target, x: 0.5),
            verb: verb,
            effect: plan.effect,
            windowTitleAfter: "Document",
            before: W.window([W.open, W.save]),
            after: W.window([W.open, W.save, W.format]),
            attempt: plan.attempt
        ))
        return plan.outcome
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        gestures.append("select \(item)")
        return ActOutcome(.foundActed, "selected '\(item)'")
    }

    /// A menu bar command as `MenuBarCommand` reports one: pressed, judged by the window signature.
    func menu(path: String) async throws -> ActOutcome {
        gestures.append("menu \(path)")
        return ActOutcome(.foundActed, "pressed '\(path)'", check: OperationCheck(
            condition: .windowSetChanged, method: .windowSignature, verdict: .unknown, observed: "unchanged",
            performed: .requested
        ))
    }

    /// A dialog button as `DialogButtonPress` reports one: pressed, judged by the window signature.
    func press(button: String) async throws -> ActOutcome {
        gestures.append("press \(button)")
        return ActOutcome(.foundActed, "pressed '\(button)'", check: OperationCheck(
            condition: .windowSetChanged, method: .windowSignature, verdict: .passed, observed: "closed",
            performed: .requested
        ))
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        guard case .typeText(let text, let field, _) = input else {
            gestures.append("input")
            return ActOutcome(.actedUnverified, "delivered")
        }
        gestures.append("type into \(field)")
        typedLabel = text
        await CallRecorder.current?.record(InputRecord(
            bundleID: W.bundle, input: input, target: Self.field(""), before: W.window([W.open, Self.field("")]),
            after: W.window([W.open, Self.field(text)]), attempt: .delivered
        ))
        return ActOutcome(.foundActed, "typed into '\(field)': the field reads '\(text)'", check: OperationCheck(
            condition: .valueReadBack, method: .controlValue, verdict: .passed, expected: text, observed: text,
            performed: .requested, target: OperationCheck.Target(Self.field(""))))
    }

    func close() async {}
}

/// RefusingSession acts as a FactSession, then makes the archive refuse the full end of its first call,
/// as the review of plan D1 did: a trigger on the effects (the contract's refusal), or a fact already
/// under the identity that call's verification takes (a conflict).
@MainActor
final class RefusingSession: AutomationSessionOperating {

    enum Fault: String, CaseIterable, Sendable {
        case refusal, conflict
    }

    let base: FactSession
    let fault: Fault
    /// The calls the session acted in, in order.
    private(set) var calls: [String] = []

    init(directory: URL, fault: Fault) {
        base       = FactSession(directory: directory)
        self.fault = fault
    }

    var id: UUID? { base.id }
    var memoryDirectory: URL? { base.memoryDirectory }
    var memoryApplication: String? { base.memoryApplication }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        try await base.open(application: application, window: window)
    }

    func observe() async throws -> SceneSnapshot { try await base.observe() }

    func act(
        target: String,
        verb: ActionVerb,
        section: String?,
        desiredState: ControlState?
    ) async throws -> ActOutcome {
        let outcome = try await base.act(target: target, verb: verb, section: section, desiredState: desiredState)
        guard let callID = CallRecorder.current?.eventID else { throw AutomationFailure("no call") }
        calls.append(callID)
        guard calls.count == 1 else { return outcome }
        let fault     = self.fault
        let condition = outcome.check?.condition ?? .none
        _ = try await MemoryService.shared(for: base.directory).perform { repositories in
            try await repositories.store.write { transaction in
                switch fault {
                    case .refusal:
                        try transaction.execute(
                            """
                            CREATE TRIGGER refuse_effects BEFORE INSERT ON memory_call_effects
                            BEGIN SELECT RAISE(ABORT, 'the contract refuses this effect'); END
                            """
                        )
                    case .conflict:
                        guard var event = try SQLiteEventRows.read(transaction, eventID: callID) else {
                            throw AutomationFailure("no call event")
                        }
                        event.eventID = OperationVerification.eventID(call: callID, condition: condition)
                        _ = try SQLiteEventRows.record(transaction, event)
                }
            }
        }
        return outcome
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        try await base.select(control: control, item: item)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await base.deliver(input, section: section)
    }

    func close() async { await base.close() }
}

@MainActor
@Suite("G76 D1: tasks, essential writes, verifications and withheld values through the tools")
struct FactWiringTests {

    static let canaryToken    = "sk-test-CANARY0123456789abcdefXYZ"
    static let canaryPassword = "Canary-Pass-7419"
    /// A declared secret of three characters, none of them a hexadecimal digit, so no identity or
    /// number of the archive can hold it by chance.
    static let canaryShort    = "Qz!"

    private func tools(_ session: FactSession, stream: String = "worker-1", source: MemoryEventSource = .app,
                       trace: String? = "message-1") -> AutomationTools {
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: source, streamID: stream, traceID: trace, messageRef: trace)
        return tools
    }

    private func task(_ tools: AutomationTools, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await tools.call("memory_task", .object(arguments)).payload
    }

    private func act(_ tools: AutomationTools, _ session: FactSession, _ target: String) async throws -> JSONValue {
        try await tools.call(
            "act",
            .object(["session": .string(session.id!.uuidString), "target": .string(target)])
        ).payload
    }

    private func service(_ session: FactSession) -> MemoryService { MemoryService.shared(for: session.directory) }

    // MARK: The task

    @Test("a task begun through memory_task attributes the calls of its attempt, revises against the revision read, checkpoints once, and ends")
    func taskLifecycle() async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session)
        let begun = try await task(
            tools,
            ["operation": .string("begin"), "goal": .string("Export foto_demo.png as JPEG"),
             "result": .string("foto_web.jpg"),
             "inputs": .array([.object(["name": .string("input_file"), "value": .string("foto_demo.png"),
                                        "kind": .string("file"), "source": .string("request")]),
                               .object(["name": .string("format")])])]
        )
        #expect(begun["status"].string == "begun" && begun["revision"] == .number(1))
        let taskID = try #require(begun["task"].string), attemptID = try #require(begun["attempt"].string)
        _ = try await act(tools, session, "Save")

        let stale = try await tools.call("memory_task", .object(["operation": .string("update"), "revision": .number(2),
                                                                 "goal": .string("x")]))
        #expect(stale["isError"] == .bool(true))
        let revised = try await task(
            tools,
            ["operation": .string("update"), "revision": .number(1),
             "inputs": .array([.object(["name": .string("format"), "value": .string("JPEG")])]),
             "reason": .string("the person chose JPEG")]
        )
        #expect(revised["revision"] == .number(2))
        let concurrent = try await tools.call(
            "memory_task",
            .object(["operation": .string("update"), "revision": .number(1),
                     "goal": .string("Export as GIF")])
        ).payload
        #expect(concurrent["error"].string == "stale_revision" && concurrent["current_revision"] == .number(2))
        _ = try await act(tools, session, "Open")

        let first  = try await task(tools, ["operation": .string("checkpoint"), "note": .string("exported")])
        let second = try await task(tools, ["operation": .string("checkpoint"), "note": .string("exported")])
        #expect(first["sequence"] == .number(1) && second["recorded"].string == "already recorded")
        let ended = try await task(
            tools,
            ["operation": .string("end"), "outcome": .string("completed"),
             "outputs": .array([.object(["name": .string("output_file"), "value": .string("foto_web.jpg"),
                                         "kind": .string("file")])])]
        )
        #expect(ended["status"].string == "ended" && ended["outcome"].string == "completed")
        _ = try await act(tools, session, "Save")
        let noTask = try await tools.call("memory_task", .object(["operation": .string("checkpoint")])).payload
        #expect(noTask["error"].string == "no_open_task")

        let memory   = service(session)
        let producer = try TaskProducer(source: .app, streamID: "worker-1")
        let calls    = try await memory.perform { try await $0.tasks.calls(of: attemptID, for: producer) }
        #expect(calls.count == 2, "the two calls made while the task was open, not the one after its end")
        let attributions = try await memory.perform { repositories in
            try await calls.asyncMap { try await repositories.facts.attribution(of: $0)?.revision }
        }
        #expect(attributions == [1, 2], "each call under the revision current when it began")
        let revision = try await memory.perform { try await $0.tasks.revision(2, of: taskID, for: producer) }
        #expect(revision?.content.inputs.first { $0.name == "format" }?.content == .text("JPEG"))
        #expect(revision?.content.messageRefs == ["message-1"])
        let record = try #require(try await memory.perform { try await $0.tasks.task(taskID, for: producer) })
        #expect(record.status == .completed)
        let traced = try await memory.calls(inTrace: "message-1")
        #expect(traced.count == 3 && traced.allSatisfy { $0.request.tool == .act },
                "memory_task is never recorded as a call")
        await memory.close()
    }

    @Test("a task cannot be begun twice, read or resumed by another producer; a resumption after a restart opens a linked attempt and replays nothing")
    func ownershipAndResumption() async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session)
        let begun   = try await task(tools, ["operation": .string("begin"), "goal": .string("Fill the form")])
        let taskID  = try #require(begun["task"].string)
        let again   = try await task(tools, ["operation": .string("begin"), "goal": .string("Another")])
        #expect(again["error"].string == "task_already_open")
        _ = try await act(tools, session, "Save")
        let gestures = session.gestures

        let other = self.tools(session, stream: "mcp-client", source: .mcp)
        let foreign = try await task(other, ["operation": .string("resume"), "task": .string(taskID)])
        #expect(foreign["error"].string == "foreign_task")

        // The same producer after a restart: a new tools instance, nothing open, nothing replayed.
        let restarted = self.tools(session)
        let resumed = try await task(restarted, ["operation": .string("resume"), "task": .string(taskID)])
        #expect(resumed["status"].string == "resumed" && resumed["attempt"].string != begun["attempt"].string)
        #expect(session.gestures == gestures, "no gesture of the earlier attempt went out again")
        let attempts = try await service(session).perform {
            try await $0.tasks.attempts(of: taskID, for: try TaskProducer(source: .app, streamID: "worker-1"))
        }
        #expect(attempts.map(\.status) == [.interrupted, .inProgress]
                    && attempts[1].attempt.resumes == begun["attempt"].string)
        await service(session).close()
    }

    // MARK: S03, S04, S08: what the checks say

    @Test("S03: a toggle already on is a verified no-op with no gesture; a click replaced by closing a pop-up verifies the closing, never the click")
    func twoNoOps() async throws {
        let session = FactSession(directory: try W.directory())
        let target  = OperationCheck.Target(
            elementID: "control|export",
            role: "AXButton",
            label: "Export",
            section: nil
        )
        session.plans["Wi-Fi"] = FactSession.Plan(
            outcome: ActOutcome(.actedNoop, "'Wi-Fi' is already on: nothing to do", check: OperationCheck(
                condition: .requestedStateAlreadyPresent,
                method: .controlState,
                verdict: .passed,
                expected: "on",
                observed: "on",
                performed: .none,
                target: target
            )),
            attempt: .notAttempted(reason: "requested_state_already_present"))
        session.plans["Export"] = FactSession.Plan(
            outcome: ActOutcome(.actedNoop, "closed the menu instead of clicking through it", check: OperationCheck(
                condition: .recoveryInsteadOfRequest,
                method: .windowCensus,
                verdict: .passed,
                expected: "pop-up closed",
                observed: "pop-up closed",
                performed: .substitute,
                substitute: "escape",
                target: target
            )),
            attempt: .notAttempted(reason: "recovery_instead_of_request"))
        let tools = tools(session)
        _ = try await tools.call("act", .object(["session": .string(session.id!.uuidString), "target": .string("Wi-Fi"),
                                                 "verb": .string("set_toggle"), "value": .string("on")]))
        _ = try await act(tools, session, "Export")
        #expect(session.gestures == ["escape"], "no click on Wi-Fi or Export went out; only the Escape did")

        let memory = service(session)
        let calls  = try await memory.calls(inTrace: "message-1")
        let toggle = try #require(calls.first), click = try #require(calls.last)
        let toggleEffect = try #require(try await memory.perform {
            try await $0.facts.effect(of: toggle.event.eventID)
        })
        #expect(toggleEffect.performed == .none && toggleEffect.notSentReason == "requested_state_already_present")
        let toggleCheck = try #require(try await memory.perform {
            try await $0.facts.verifications(of: toggle.event.eventID)
        }.first)
        #expect(toggleCheck.check.condition == .requestedStateAlreadyPresent && toggleCheck.check.verdict == .passed)
        let clickEffect = try #require(try await memory.perform { try await $0.facts.effect(of: click.event.eventID) })
        #expect(clickEffect.performed == .substitute && clickEffect.substitute == "escape")
        let clickChecks = try await memory.perform { try await $0.facts.verifications(of: click.event.eventID) }
        #expect(clickChecks.map(\.check.condition) == [.recoveryInsteadOfRequest],
                "the requested click has no verification of its own")
        await memory.close()
    }

    @Test("S04: a batch keeps its parent apart, one occurrence per started step with its own check, the failed step without a pass, the rest skipped")
    func partialBatch() async throws {
        let session = FactSession(directory: try W.directory())
        session.plans["B"] = FactSession.Plan(outcome: ActOutcome(.actedUnverified, "?"), fails: true)
        let tools = tools(session)
        let begun = try await task(tools, ["operation": .string("begin"), "goal": .string("Three clicks")])
        let steps: [JSONValue] = ["A", "B", "C"].map { .object(["operation": .string("act"), "target": .string($0)]) }
        let answer = try await tools.call(
            "batch",
            .object(["session": .string(session.id!.uuidString), "steps": .array(steps)])
        ).payload
        #expect(answer["status"].string == "stopped" && answer["attemptedSteps"] == .number(2))
        #expect(session.gestures == ["A", "B"], "C never went out")

        let memory = service(session)
        let batch  = try #require(try await memory.calls(inTrace: "message-1").first { $0.request.tool == .batch })
        let children = try await memory.ready().calls.steps(ofBatch: batch.event.eventID)
        #expect(children.map(\.progress.status) == [.completed, .failed, .skipped])
        let checks = try await memory.perform { repositories in
            try await children.asyncMap {
                try await repositories.facts.verifications(of: $0.event.eventID).map(\.check.verdict)
            }
        }
        #expect(checks == [[.passed], [], []], "the first step's own pass, none for the failed and the skipped one")
        #expect(try await memory.perform { try await $0.facts.verifications(of: batch.event.eventID) }.isEmpty,
                "the container proves nothing of its own")
        let effects = try await memory.perform { repositories in
            try await children.asyncMap { try await repositories.facts.effect(of: $0.event.eventID)?.performed }
        }
        #expect(effects == [.requested, .uncertain, nil])
        let memberships = try await memory.ready().attributions.memberships(of: try #require(begun["attempt"].string))
        #expect(memberships.map(\.role) == [.context, .action, .action],
                "the parent as a container, the two started steps as operations")
        await memory.close()
    }

    @Test("S08: a change no structural effect explains stays unknown; nothing positive is recorded for the requested command")
    func unrelatedChange() async throws {
        let session = FactSession(directory: try W.directory())
        session.plans["Sync"] = FactSession.Plan(outcome: ActOutcome(
            .actedUnverified,
            "pixels changed",
            check: OperationCheck.sceneDifference(.unattributable, expected: nil, target: nil, limits: [.windowWide])
        ))
        _ = try await act(tools(session), session, "Sync")
        let memory = service(session)
        let call   = try #require(try await memory.calls(inTrace: "message-1").first)
        let check  = try #require(try await memory.perform {
            try await $0.facts.verifications(of: call.event.eventID)
        }.first)
        #expect(check.check.verdict == .unknown && check.check.limits.contains(.unattributed))
        #expect(try await memory.ready().brains.brain(of: W.bundle)?.transitions.isEmpty ?? true,
                "no effect, nothing learned")
        await memory.close()
    }

    // MARK: S12, S14: producers

    @Test("S12/S14: the app's worker and an external client share one archive: each reads what the other's calls taught, tasks and attributions stay their own")
    func sharedKnowledgeSeparateTasks() async throws {
        let directory = try W.directory()
        let worker = FactSession(directory: directory), client = FactSession(directory: directory)
        let app = tools(worker), mcp = tools(client, stream: "mcp-client", source: .mcp, trace: nil)
        let appTask = try await task(app, ["operation": .string("begin"), "goal": .string("Open the document")])
        _ = try await act(app, worker, "Open")
        _ = try await act(mcp, client, "Save")
        let mcpTask = try await task(mcp, ["operation": .string("begin"), "goal": .string("Save the document")])
        _ = try await act(mcp, client, "Save")
        _ = try await act(app, worker, "Open")

        let memory = MemoryService.shared(for: directory)
        let workerProducer = try TaskProducer(source: .app, streamID: "worker-1")
        let clientProducer = try TaskProducer(source: .mcp, streamID: "mcp-client")
        let appCalls = try await memory.perform {
            try await $0.tasks.calls(of: try #require(appTask["attempt"].string), for: workerProducer)
        }
        let mcpCalls = try await memory.perform {
            try await $0.tasks.calls(of: try #require(mcpTask["attempt"].string), for: clientProducer)
        }
        #expect(appCalls.count == 2 && mcpCalls.count == 1,
                "the client's call before its task and the worker's are not attributed by time")
        await #expect(throws: TaskContextError.foreignTask(taskID: try #require(appTask["task"].string))) {
            _ = try await memory.perform {
                try await $0.tasks.task(try #require(appTask["task"].string), for: clientProducer)
            }
        }
        // What one producer's observation taught, the other's next expectation reads from the same archive.
        _ = await CallRecorder(
            memory: memory,
            brain: W.brain(memory),
            context: ActionContext(source: .mcp, streamID: "mcp-client")
        ).observe(W.window([W.open, W.format, W.save]))
        #expect(await memory.flush(within: .seconds(10)))
        let read = try await MemoryService.shared(for: directory).brain(of: W.bundle)
        #expect(read?.objects.count == 3, "one archive: the worker reads the client's Brain")
        let sources = try rawRows(
            "SELECT DISTINCT source FROM memory_events WHERE event_kind = 'action' ORDER BY source",
            at: memory.url
        )
        #expect(sources == ["app", "mcp"])
        await memory.close()
    }

    // MARK: S13 and the essential writes

    @Test("S13: a call whose process ended between its start and its end stays started, incomplete; a new session replays nothing")
    func crashLeavesIncomplete() async throws {
        let directory = try W.directory()
        let memory    = MemoryService(directory: directory)
        let recorder  = CallRecorder(
            memory: memory,
            brain: W.brain(memory),
            context: ActionContext(source: .app, streamID: "worker-1", traceID: "crash", sessionID: "s1")
        )
        try await recorder.begin(
            .act(target: "Save", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        // The process ends here: no end is written, the service closes as the process's end would.
        await memory.close()

        let reopened = MemoryService(directory: directory)
        let call = try #require(try await reopened.call(recorder.eventID))
        #expect(call.progress.status == .started, "started and never ended: incomplete, not completed")
        #expect(try await reopened.perform { try await $0.facts.effect(of: recorder.eventID) } == nil)
        let session = FactSession(directory: directory)
        _ = try await AutomationTools(session: session).call("status", .object([:]))
        #expect(session.gestures.isEmpty, "opening the memory again acts on nothing")
        await reopened.close()
    }

    @Test("an action whose start the memory cannot confirm is refused before any gesture")
    func unconfirmedStartActsOnNothing() async throws {
        let session = FactSession(directory: try W.directory())
        let raw = try SQLiteConnection(path: session.directory.appendingPathComponent("memory.sqlite").path)
        try raw.execute("CREATE TABLE somebody_elses (x INTEGER)")
        raw.close()
        let tools = tools(session)
        await #expect(throws: AutomationFailure.self) { _ = try await act(tools, session, "Save") }
        #expect(session.gestures.isEmpty, "the memory refused the start: nothing went out")
        let status = try await tools.call("status", .object([:])).payload
        #expect(status["memory"].string?.contains("not recorded") == true,
                "a read-only call still answers, saying it was not recorded")
        await service(session).close()
    }

    @Test("an end the memory cannot save suspends it: the answer says so, no new action starts, and once saved the next action runs; nothing is replayed")
    func failedEndSuspends() async throws {
        let store   = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(100),
            retryPause: .milliseconds(5),
            maximumRetryPause: .milliseconds(10)
        )
        let session = FactSession(directory: try W.directory())
        let memory  = MemoryService(
            directory: session.directory,
            configuration: MemoryService.Configuration(store: store, essentialAttempts: 1, essentialCycles: 1)
        )
        let recorder = CallRecorder(
            memory: memory,
            brain: W.brain(memory),
            context: ActionContext(source: .app, streamID: "worker-1", traceID: "suspension", sessionID: "s1")
        )
        try await recorder.begin(
            .act(target: "Save", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        let lock = try SQLiteConnection(path: memory.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        await #expect(throws: EssentialWriteFailure.self) {
            try await recorder.end(.completed, result: .outcome(.foundActed, message: "saved"), tool: .act,
                                   check: OperationCheck.unchecked(performed: .requested))
        }
        let suspended = await memory.status()
        #expect(suspended.suspended != nil && suspended.pendingEssential == 1)
        let next = CallRecorder(
            memory: memory,
            brain: W.brain(memory),
            context: ActionContext(source: .app, streamID: "worker-1", traceID: "suspension", sessionID: "s1")
        )
        await #expect(throws: EssentialWriteFailure.self, "suspended: no new action may start") {
            try await next.begin(
                .act(target: "Open", verb: .click, value: nil, section: nil),
                app: AppContextIdentity(bundleID: W.bundle)
            )
        }
        try lock.execute("COMMIT")
        lock.close()
        try await next.begin(
            .act(target: "Open", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        #expect(await memory.status().suspended == nil, "the kept end was saved first, then the new start")
        #expect(try await memory.call(recorder.eventID)?.progress.status == .completed)
        #expect(try await memory.calls(inTrace: "suspension").count == 2,
                "the first call once, the second once: nothing replayed")
        await memory.close()
    }

    @Test("an end the archive refuses as offered (the contract's refusal, a conflict) is saved as its least: the parts it lost and why stay in the archive, the answer says so, a reopen reads them, nothing is replayed",
          arguments: RefusingSession.Fault.allCases)
    func refusedEndIsDeclared(fault: RefusingSession.Fault) async throws {
        let session = RefusingSession(directory: try W.directory(), fault: fault)
        let tools   = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "worker-1", traceID: "message-1", messageRef: "message-1")
        let id = JSONValue.string(session.id!.uuidString)
        let first = try await tools.call("act", .object(["session": id, "target": .string("Save")])).payload
        let notice = try #require(first["memory"].string, "the answer says what was not recorded")
        #expect(notice.contains("was not recorded") && notice.contains("incomplete evidence"), "\(notice)")
        _ = try await tools.call("act", .object(["session": id, "target": .string("Open")]))
        #expect(session.base.gestures == ["Save", "Open"], "nothing replayed, and a least is no suspension")
        let shared = MemoryService.shared(for: session.base.directory)
        #expect(await shared.status().suspended == nil)
        if fault == .refusal {
            // The injected trigger is not this build's schema: a reopen would refuse the file's shape.
            _ = try await shared.perform { try await $0.store.write { try $0.execute("DROP TRIGGER refuse_effects") } }
        }
        await shared.close()

        let reopened = MemoryService(directory: session.base.directory)
        let refused  = session.calls[0], next = session.calls[1]
        let gaps = try await reopened.perform { try await $0.facts.recordingGaps(of: refused) }
        #expect(gaps.map(\.part) == [.samples, .effect, .verification])
        #expect(gaps.allSatisfy { $0.reason == (fault == .refusal ? .refused : .conflict) && $0.detail != nil })
        #expect(try await reopened.call(refused)?.progress.status == .completed, "the state and result are kept")
        #expect(try await reopened.perform { try await $0.facts.verifications(of: refused) }.isEmpty,
                "a missing verification stays missing, never a pass")
        if fault == .conflict {
            #expect(try await reopened.perform { try await $0.facts.recordingGaps(of: next) }.isEmpty)
            #expect(try await reopened.perform { try await $0.facts.verifications(of: next) }.count == 1)
        }
        await reopened.close()
    }

    @Test("an end the archive cannot write for now (a full device, a lock held past the budget) suspends the memory and is never saved as a least; once the archive writes again, it is saved whole with no gap",
          arguments: ["full", "contention"])
    func unwritableEndSuspends(cause: String) async throws {
        let store  = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(100),
            retryPause: .milliseconds(5),
            maximumRetryPause: .milliseconds(10)
        )
        let memory = MemoryService(
            directory: try W.directory(),
            configuration: MemoryService.Configuration(store: store, essentialAttempts: 1, essentialCycles: 1)
        )
        let recorder = W.recorder(memory, trace: "unwritable")
        try await recorder.begin(
            .act(target: "Save", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        // A large after sample, so the end needs pages a full device does not have.
        let padding = String(repeating: "x", count: 40)
        let many = (0..<300).map { W.button("Button \($0) \(padding)", x: 0.5) }
        await recorder.record(ActionRecord(bundleID: W.bundle, element: W.save, verb: .click, effect: nil,
                                           windowTitleAfter: "Document", before: W.window([W.save]),
                                           after: W.window([W.save] + many)))
        var lock: SQLiteConnection?
        if cause == "full" {
            let pages = try await memory.perform { repositories in
                try await repositories.store.read { snapshot in
                    try snapshot.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0
                }
            }
            // A pragma takes no bound value; the number is the file's own page count.
            _ = try await memory.perform { repositories in
                try await repositories.store.write { try $0.execute("PRAGMA max_page_count = \(pages)") }
            }
        } else {
            lock = try SQLiteConnection(path: memory.url.path)
            try lock?.execute("BEGIN IMMEDIATE")
        }
        do {
            try await recorder.end(.completed, result: .outcome(.foundActed, message: "saved"), tool: .act,
                                   check: OperationCheck.unchecked(performed: .requested))
            Issue.record("the end was saved")
        } catch let failure as EssentialWriteFailure {
            switch (cause, failure) {
                case ("full", .storageFull), ("contention", .contention): break
                default: Issue.record("\(cause) answered \(failure)")
            }
        }
        #expect(await recorder.recordingGap == nil, "no least for a failure that may pass")
        #expect(await memory.status().suspended != nil)
        if let lock {
            try lock.execute("COMMIT")
            lock.close()
        } else {
            _ = try await memory.perform { repositories in
                try await repositories.store.write { try $0.execute("PRAGMA max_page_count = 1073741823") }
            }
        }
        let next = W.recorder(memory, trace: "unwritable")
        try await next.begin(
            .act(target: "Open", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        #expect(await memory.status().suspended == nil, "the kept end was saved before the new start")
        #expect(try await memory.call(recorder.eventID)?.progress.status == .completed)
        #expect(try await memory.perform { try await $0.facts.recordingGaps(of: recorder.eventID) }.isEmpty)
        #expect(try await memory.perform { try await $0.facts.verifications(of: recorder.eventID) }.count == 1)
        await memory.close()
    }

    @Test("a close while an end waits to be saved says so: the fact is counted as never saved, the call stays started, nothing is replayed")
    func closeWhileSuspended() async throws {
        let store   = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(100),
            retryPause: .milliseconds(5),
            maximumRetryPause: .milliseconds(10)
        )
        let memory  = MemoryService(
            directory: try W.directory(),
            configuration: MemoryService.Configuration(
                store: store,
                closingBudget: .milliseconds(500),
                essentialAttempts: 1,
                essentialCycles: 1
            )
        )
        let recorder = CallRecorder(
            memory: memory,
            brain: W.brain(memory),
            context: ActionContext(source: .app, streamID: "worker-1", traceID: "closing", sessionID: "s1")
        )
        try await recorder.begin(
            .act(target: "Save", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle)
        )
        let lock = try SQLiteConnection(path: memory.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        await #expect(throws: EssentialWriteFailure.self) {
            try await recorder.end(.completed, result: .outcome(.foundActed, message: "saved"), tool: .act)
        }
        try lock.execute("COMMIT")
        lock.close()
        await memory.close()
        let closed = await memory.status()
        #expect(closed.lastClose?.contains("1 facts written after an effect never saved") == true,
                "\(closed.lastClose ?? "")")
        let reopened = MemoryService(directory: memory.directory)
        #expect(try await reopened.call(recorder.eventID)?.progress.status == .started,
                "incomplete, as a crash would leave it")
        await reopened.close()
    }

    // MARK: S19: secrets

    @Test("S19: a declared secret, a value typed into a password field and a token's shape are absent from every table, copy and status; the gaps are declared")
    func canariesAreWithheld() async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session)
        var transcript: [String] = []
        tools.record = { transcript.append($0) }
        _ = try await task(
            tools,
            ["operation": .string("begin"), "goal": .string("Sign in and paste the key"),
             "inputs": .array([.object(["name": .string("password"), "value": .string(Self.canaryPassword),
                                        "secret": .bool(true), "role": .string("account password")])])]
        )
        let id = JSONValue.string(session.id!.uuidString)
        _ = try await tools.call("type_text", .object(["session": id, "target": .string("Password"),
                                                       "text": .string(Self.canaryPassword)]))
        _ = try await tools.call("type_text", .object(["session": id, "target": .string("Notes"),
                                                       "text": .string("key \(Self.canaryToken)")]))
        _ = try await tools.call("observe", .object(["session": id]))
        let memory = service(session)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        // A copy taken after the writes, as the next day's would be.
        let copying = MemoryService(directory: session.directory, configuration: .init(backupInterval: .zero))
        _ = try await copying.ready()
        try await Task.sleep(for: .milliseconds(300))
        await copying.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
            .filter {
                $0.hasPrefix("memory.sqlite")
                    && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix(".lock")
            }
        #expect(files.count >= 2, "the archive and at least one copy: \(files)")
        for file in files {
            let url = session.directory.appendingPathComponent(file)
            for canary in [Self.canaryPassword, Self.canaryToken] {
                let found = try archiveOccurrences(of: canary, in: url)
                #expect(found.isEmpty, "\(canary.prefix(6))… in \(file): \(found)")
            }
        }
        #expect(transcript.allSatisfy { !$0.contains(Self.canaryPassword) && !$0.contains(Self.canaryToken) })
        let archive = session.directory.appendingPathComponent("memory.sqlite")
        let gaps = try rawRows(
            "SELECT location_kind || ':' || reason FROM memory_value_redactions ORDER BY redaction_id",
            at: archive
        )
        #expect(gaps.contains("argument:secret_target") && gaps.contains("argument:credential_pattern"))
        #expect(gaps.contains { $0.hasPrefix("sample_label:") } && gaps.contains { $0.hasPrefix("verification_") })
        let withheld = try rawRows(
            "SELECT content || ':' || sensitivity FROM memory_task_values WHERE name = 'password'",
            at: archive
        )
        #expect(withheld == ["withheld:secret"])
    }

    @Test("S19: a secret the task declares, long or short, is withheld from the task's goal, result, constraints, reason, notes and values, from later calls and from the transcript; ordinary values stay as given")
    func declaredSecretCopiesAreWithheld() async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session)
        var transcript: [String] = []
        tools.record = { transcript.append($0) }
        let long = Self.canaryPassword, short = Self.canaryShort
        let begun = try await task(tools, [
            "operation"  : .string("begin"),
            "goal"       : .string("Sign in with \(long) and the PIN \(short)"),
            "result"     : .string("Signed in, PIN \(short) accepted"),
            "constraints": .array([.string("Never show \(long)")]),
            "inputs"     : .array([
                .object(["name": .string("password"), "value": .string(long), "secret": .bool(true)]),
                .object(["name": .string("pin"), "value": .string(short), "secret": .bool(true)]),
                .object(["name": .string("file"), "value": .string("report.pdf")]),
                .object(["name": .string("hint"), "value": .string("the PIN is \(short)")]),
            ]),
        ])
        #expect(begun["status"].string == "begun")
        let revised = try await task(tools, [
            "operation": .string("update"),
            "goal"     : .string("Use \(long) again, PIN \(short)"),
            "reason"   : .string("the PIN \(short) was refused once"),
        ])
        #expect(revised["revision"] == .number(2))
        let id = JSONValue.string(session.id!.uuidString)
        _ = try await tools.call("type_text", .object([
            "session": id, "target": .string("Notes"), "text": .string("PIN \(short) for \(long)"),
        ]))
        _ = try await task(tools, [
            "operation": .string("checkpoint"),
            "note"     : .string("typed \(short)"),
            "outputs"  : .array([.object(["name": .string("receipt"), "value": .string("R-1 for \(short)")])]),
        ])
        _ = try await task(tools, [
            "operation": .string("end"),
            "outcome"  : .string("completed"),
            "note"     : .string("done with \(long)"),
            "outputs"  : .array([.object(["name": .string("account"), "value": .string("tom")])]),
        ])
        let memory = service(session)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()

        let archive = session.directory.appendingPathComponent("memory.sqlite")
        for canary in [long, short] {
            let found = try archiveOccurrences(of: canary, in: archive)
            #expect(found.isEmpty, "\(canary.prefix(4))… in \(found)")
            #expect(transcript.allSatisfy { !$0.contains(canary) })
        }
        let goals = try rawRows("SELECT goal FROM memory_task_revisions ORDER BY revision", at: archive)
        #expect(goals == ["Sign in with [withheld] and the PIN [withheld]", "Use [withheld] again, PIN [withheld]"])
        let values = try rawRows(
            """
            SELECT name || '=' || content || ':' || ifnull(text_value, '-') FROM memory_task_values
            WHERE revision = 2 OR checkpoint_sequence IS NOT NULL ORDER BY value_id
            """,
            at: archive
        )
        #expect(values == ["password=withheld:-", "pin=withheld:-", "file=text:report.pdf", "hint=withheld:-",
                           "receipt=withheld:-", "account=text:tom"])
        let gaps = try rawRows("SELECT location_kind || ':' || reason FROM memory_value_redactions", at: archive)
        #expect(gaps.contains("argument:declared_secret"), "the typed copy is a declared gap")
    }

    /// A task that declares `secret`, through the tools of a fresh session, and the tools.
    private func secretTask(_ secret: String, stream: String) async throws -> (FactSession, AutomationTools) {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session, stream: stream, trace: stream)
        let begun   = try await task(tools, [
            "operation": .string("begin"),
            "goal"     : .string("Change the saved credential settings"),
            "inputs"   : .array([
                .object(["name": .string("credential"), "value": .string(secret), "secret": .bool(true)]),
            ]),
        ])
        #expect(begun["status"].string == "begun")
        return (session, tools)
    }

    @Test("S19, review F02a: a declared secret in the resolved target's section, identity or role reaches neither the effect nor the verification; the gaps are declared and the check says its evidence is kept in part")
    func targetTextsAreWithheld() async throws {
        let secret = "Review-Target-Canary-7319"
        let (session, tools) = try await secretTask(secret, stream: "target-texts")
        session.plans["Save"] = FactSession.Plan(outcome: ActOutcome(.foundActed, "Saved", check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .passed, observed: "elementsAppeared",
            performed: .requested,
            target: OperationCheck.Target(elementID: "control|save\(LabelText.normalize(secret))",
                                          role: "AXButton \(secret)", label: "Save",
                                          section: "Credential settings for \(secret)")
        )))
        _ = try await tools.call("act", .object(["session": .string(session.id!.uuidString),
                                                 "target": .string("Save")]))
        let memory = service(session)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        let archive = session.directory.appendingPathComponent("memory.sqlite")
        for canary in [secret, LabelText.normalize(secret)] {
            #expect(try archiveOccurrences(of: canary, in: archive).isEmpty, "\(canary.prefix(6))…")
        }
        #expect(try rawRows(
            "SELECT target_label || '/' || target_section FROM memory_call_effects", at: archive
        ) == ["Save/Credential settings for [withheld]"], "the ordinary label and the rest of the section are kept")
        let gaps = try rawRows("SELECT DISTINCT location_kind FROM memory_value_redactions ORDER BY 1", at: archive)
        #expect(gaps.contains("target_section") && gaps.contains("target_element"))
        #expect(try rawRows("SELECT limit_kind FROM memory_operation_verification_limits", at: archive)
            .contains("value_withheld"))
    }

    @Test("S19, review F02b: a declared secret in an effect's labels is withheld from the call's effect, typed, with its gap; the Brain learns no transition from it, and the check says its evidence is kept in part")
    func effectTextsAreWithheld() async throws {
        let secret = "Review-Effect-Canary-8246"
        let (session, tools) = try await secretTask(secret, stream: "effect-texts")
        session.plans["Save"] = FactSession.Plan(
            outcome: ActOutcome(.foundActed, "Opened menu", check: OperationCheck(
                condition: .structuralEffect, method: .sceneDifference, verdict: .passed, observed: "menuOpened",
                performed: .requested,
                target: OperationCheck.Target(elementID: "control|save", role: "AXButton", label: "Save", section: nil)
            )),
            effect: .menuOpened(labels: ["Saved credential \(secret)", "Cancel"])
        )
        _ = try await tools.call("act", .object(["session": .string(session.id!.uuidString),
                                                 "target": .string("Save")]))
        let memory = service(session)
        #expect(await memory.flush(within: .seconds(10)))
        let calls = try await memory.calls(inTrace: "effect-texts")
        let effects = calls.compactMap { $0.progress.observedEffect?.sceneEffect }
        #expect(effects == [.menuOpened(labels: ["Saved credential [withheld]", "Cancel"])],
                "the effect keeps its family and its other labels, and still decodes")
        #expect(try await memory.brain(of: W.bundle)?.transitions.isEmpty ?? true,
                "no transition predicts the marker")
        await memory.close()
        let archive = session.directory.appendingPathComponent("memory.sqlite")
        #expect(try archiveOccurrences(of: secret, in: archive).isEmpty)
        #expect(try rawRows("SELECT DISTINCT location_kind FROM memory_value_redactions", at: archive)
            .contains("observed_effect"))
        #expect(try rawRows("SELECT limit_kind FROM memory_operation_verification_limits", at: archive)
            .contains("value_withheld"))
    }

    @Test("S19: a listing's window titles and application texts are minimized before they are kept, one gap per application")
    func listingTextsAreWithheld() async throws {
        let declared = "Review-Listing-Canary-5531"
        let memory   = try W.service()
        let recorder = CallRecorder(memory: memory, brain: W.brain(memory),
                                    context: ActionContext(source: .mcp, streamID: "listing", traceID: "listing"),
                                    minimization: ValueMinimization(secrets: [declared]))
        try await recorder.begin(.windows(app: nil), app: nil)
        let listing = ListingResult(kind: .windows, applications: [
            ListedApplication(name: "Notes", bundleID: "com.apple.Notes", pid: 11,
                              windows: [ListedWindow(number: 1, title: "Token \(Self.canaryToken)")]),
            ListedApplication(name: "Editor \(declared)", bundleID: W.bundle, pid: 12,
                              windows: [ListedWindow(number: 2, title: "Doc")]),
            ListedApplication(name: "Finder", bundleID: "com.apple.finder", pid: 13,
                              windows: [ListedWindow(number: 3, title: "Home")]),
        ])
        try await recorder.end(.completed, result: .listing(listing), tool: .windows)
        await memory.close()
        let archive = memory.url
        for canary in [declared, Self.canaryToken] {
            #expect(try archiveOccurrences(of: canary, in: archive).isEmpty, "\(canary.prefix(6))…")
        }
        #expect(try rawRows("SELECT title FROM memory_agent_action_windows ORDER BY title", at: archive)
            == ["Doc", "Home", "Token [withheld]"])
        #expect(try rawRows(
            "SELECT element_position FROM memory_value_redactions WHERE location_kind = 'listing_entry' ORDER BY 1",
            at: archive
        ) == ["0", "1"])
    }

    /// One operation as the agent calls it, the tool its call records and what the call's arguments read
    /// back, and the condition the path's check states (`none` for a path with no oracle).
    struct Operation: Sendable, CustomTestStringConvertible {
        let tool: String
        let arguments: [String: JSONValue]
        let recorded: AgentTool
        let read: Set<String>
        let condition: OperationCheck.Condition

        var testDescription: String {
            tool + (arguments["verb"]?.string.map { " \($0)" } ?? "")
        }
    }

    nonisolated static let operations: [Operation] = [
        Operation(tool: "act", arguments: ["target": .string("Save")], recorded: .act,
                  read: ["target=Save", "verb=click"], condition: .structuralEffect),
        Operation(tool: "act", arguments: ["target": .string("Save"), "verb": .string("double_click")], recorded: .act,
                  read: ["target=Save", "verb=double_click"], condition: .structuralEffect),
        Operation(tool: "act", arguments: ["target": .string("Save"), "verb": .string("triple_click")], recorded: .act,
                  read: ["target=Save", "verb=triple_click"], condition: .structuralEffect),
        Operation(tool: "act", arguments: ["target": .string("Save"), "verb": .string("right_click")], recorded: .act,
                  read: ["target=Save", "verb=right_click"], condition: .structuralEffect),
        Operation(tool: "act",
                  arguments: ["target": .string("Wi-Fi"), "verb": .string("set_toggle"), "value": .string("on")],
                  recorded: .act, read: ["target=Wi-Fi", "verb=set_toggle", "value=on"], condition: .structuralEffect),
        Operation(tool: "select", arguments: ["control": .string("Format"), "item": .string("Bold")], recorded: .select,
                  read: ["control=Format", "item=Bold"], condition: .none),
        Operation(tool: "type_text", arguments: ["target": .string("Name"), "text": .string("report")],
                  recorded: .typeText, read: ["target=Name", "text=report"], condition: .valueReadBack),
        Operation(tool: "insert_text", arguments: ["text": .string("report")], recorded: .insertText,
                  read: ["text=report"], condition: .none),
        Operation(tool: "press_key",
                  arguments: ["key": .string("s"), "modifiers": .array([.string("cmd"), .string("shift")]),
                              "count": .number(2)],
                  recorded: .pressKey, read: ["key=s", "modifiers=cmd", "modifiers=shift", "count=2"],
                  condition: .none),
        Operation(tool: "scroll",
                  arguments: ["direction": .string("down"), "lines": .number(2), "target": .string("Files")],
                  recorded: .scroll, read: ["direction=down", "lines=2", "target=Files"], condition: .none),
        Operation(tool: "drag", arguments: ["from": .string("Photo"), "to": .string("Album")], recorded: .drag,
                  read: ["from=Photo", "to=Album"], condition: .none),
        Operation(tool: "context_menu", arguments: ["target": .string("Photo"), "item": .string("Duplicate")],
                  recorded: .contextMenu, read: ["target=Photo", "item=Duplicate"], condition: .none),
        Operation(tool: "menu", arguments: ["path": .string("File > Save")], recorded: .menu,
                  read: ["path=File > Save"], condition: .windowSetChanged),
        Operation(tool: "press", arguments: ["button": .string("OK")], recorded: .press,
                  read: ["button=OK"], condition: .windowSetChanged),
    ]

    @Test("every operation tool records its call with its arguments, the effect really performed and the check its path states, all read back from the repositories after reopening",
          arguments: Self.operations)
    func everyOperationIsRecorded(operation: Operation) async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session, trace: "operation")
        var arguments = operation.arguments
        arguments["session"] = .string(session.id!.uuidString)
        _ = try await tools.call(operation.tool, .object(arguments))
        #expect(session.gestures.count == 1, "one gesture, recorded once")
        await service(session).close()

        let reopened = MemoryService(directory: session.directory)
        let calls = try await reopened.calls(inTrace: "operation")
        let call  = try #require(calls.first)
        #expect(calls.count == 1 && call.request.tool == operation.recorded && call.progress.status == .completed)
        let read = Set(call.request.arguments.map { argument -> String in
            let value: String = switch argument.value {
                case .text(let text)    : text
                case .integer(let value): "\(value)"
                case .real(let value)   : "\(value)"
                case .boolean(let flag) : "\(flag)"
            }
            return "\(argument.name)=\(value)"
        })
        #expect(read.isSuperset(of: operation.read), "\(read)")
        let id = call.event.eventID
        let effect = try #require(try await reopened.perform { try await $0.facts.effect(of: id) })
        #expect(effect.performed == .requested || effect.performed == .uncertain)
        let verifications = try await reopened.perform { try await $0.facts.verifications(of: id) }
        #expect(verifications.map(\.check.condition) == [operation.condition])
        await reopened.close()
    }

    @Test("an operation the call contract cannot represent (one with no session) is refused before any gesture, and nothing is recorded")
    func unrepresentableCallActsOnNothing() async throws {
        let session = FactSession(directory: try W.directory())
        session.id = nil
        let tools = tools(session, trace: "unrepresentable")
        do {
            _ = try await tools.call("act", .object(["target": .string("Save")]))
            Issue.record("the call ran")
        } catch {
            #expect("\(error)".contains("did not confirm this call before it could act"), "\(error)")
        }
        #expect(session.gestures.isEmpty, "no gesture went out")
        let memory = service(session)
        #expect(try await memory.calls(inTrace: "unrepresentable").isEmpty)
        await memory.close()
    }

    @Test("a revision no integer holds, a fraction or a negative one is refused as invalid with nothing written; a huge whole one is stale; the next valid update works")
    func outOfRangeRevisions() async throws {
        let session = FactSession(directory: try W.directory())
        let tools   = tools(session)
        _ = try await task(tools, ["operation": .string("begin"), "goal": .string("Export the report")])
        for number in [1e30, Double.greatestFiniteMagnitude, 1.5, -3] {
            let answer = try await tools.call("memory_task", .object([
                "operation": .string("update"), "revision": .number(number), "goal": .string("Export it again"),
            ]))
            #expect(answer["isError"] == .bool(true) && answer.payload["error"].string == "invalid_task", "\(number)")
        }
        let huge = try await task(tools, [
            "operation": .string("update"), "revision": .number(9e18), "goal": .string("Export it again"),
        ])
        #expect(huge["error"].string == "stale_revision")
        let archive = session.directory.appendingPathComponent("memory.sqlite")
        #expect(try rawRows("SELECT count(*) FROM memory_task_revisions", at: archive) == ["1"])
        let revised = try await task(tools, [
            "operation": .string("update"), "revision": .number(1), "goal": .string("Export the report as PDF"),
        ])
        #expect(revised["status"].string == "revised" && revised["revision"] == .number(2))
        await service(session).close()
    }
}

extension Array {

    /// The elements mapped in order by an asynchronous transform.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var mapped: [T] = []
        for element in self { mapped.append(try await transform(element)) }
        return mapped
    }
}
