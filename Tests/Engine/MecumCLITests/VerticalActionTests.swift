//
//  VerticalActionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing
@testable import mecum

/// The vertical commands' seven actions: the terminal grammar read into the tools' decoder (goldens of
/// the old invocations and of the new ones, and what is refused before anything runs), and the runner
/// that records them, over a scripted performer that writes real samples into a temporary memory. No
/// application, Seat, provider or desktop.
@MainActor
@Suite("Vertical actions: grammar, decoder and recording", .serialized)
struct VerticalActionTests {

    // MARK: Fixtures

    private static func memory(_ directory: URL = directory()) -> MemoryService { MemoryService(directory: directory) }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-vertical-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true)
    }

    private static let app = AppContextIdentity(bundleID: "test.vertical", version: "1.0")

    private static func window(_ labels: [String]) -> PerceivedWindow {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.1 + Double(index) * 0.2, y: 0.1, width: 0.1, height: 0.05), role: "AXButton")
        }
        let scene = SceneSnapshot(bundleID: app.bundleID, appName: "Vertical", windowTitle: "Window",
                                  viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
        return PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                               capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                                       windowRole: "AXWindow", nodesVisited: 9, elementsEmitted: labels.count),
                               surface: .window)
    }

    /// A performer standing in for the engine: it answers scripted outcomes, writes each step's real
    /// before/after samples through the call's own recorder, and can throw, fail the window check or
    /// cancel its task after the effect.
    private final class ScriptedPerformer: StepPerforming {
        var outcomes: [ActOutcomeKind] = []
        var throwAt: Int?
        var targetLostAt: Int?
        var cancelAfter: Int?
        private(set) var performed: [AgentCallRequest] = []
        private(set) var checks = 0
        let memory: MemoryService
        let brain: BrainMemory

        init(memory: MemoryService) {
            self.memory = memory
            let clock = memory.clock
            brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        }

        func checkTarget() throws {
            checks += 1
            if targetLostAt == checks { throw UsageError.invalid(option: "window", value: "Window", expected: "the original window") }
        }

        func perform(_ request: AgentCallRequest, context: ActionContext, evidence: String?) async throws -> StepResult {
            performed.append(request)
            let number = performed.count
            if throwAt == number { throw AutomationFailure("scripted failure at step \(number)") }
            let recorder = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: Int64(number),
                                        requestedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)))
            let before = VerticalActionTests.window(["Export", "Platform"])
            if case .act = request {
                let after = VerticalActionTests.window(["Export", "Platform", "Desktop"])
                await recorder.record(ActionRecord(
                    bundleID: VerticalActionTests.app.bundleID, element: before.scene.elements[1], verb: .click,
                    effect: .menuOpened(labels: ["Desktop"]), windowTitleAfter: "Window", before: before, after: after,
                    attempt: .delivered
                ))
            } else {
                await recorder.record(before: before, menu: nil, after: VerticalActionTests.window(["Export", "Platform"]))
            }
            if cancelAfter == number { withUnsafeCurrentTask { $0?.cancel() } }
            let kind = outcomes.isEmpty ? ActOutcomeKind.foundActed : outcomes.removeFirst()
            return StepResult(outcome: ActOutcome(kind, "scripted \(kind.rawValue)"), report: await recorder.report())
        }
    }

    private static func request(_ words: [String]) throws -> AgentCallRequest { try ActionGrammar.step(words) }

    // MARK: Grammar: the old invocations

    @Test("the old act and select invocations read as before, with every shared option accepted")
    func theOldInvocationsReadAsBefore() throws {
        let act = try Invocation(arguments: ["act", "Pro Tools", "Auto-create sub paths", "--verb", "set_toggle", "--value", "on",
                                             "--section", "Paths", "--seat", "--window", "New Paths", "--dry-run",
                                             "--allow-destructive", "--allow-unvalidated-build", "--knowledge", "/tmp/k"],
                                 spec: CommandSpecs.action(.act))
        #expect(act.positionals == ["Pro Tools", "Auto-create sub paths"])
        #expect(act.options["window"] == "New Paths" && act.options["knowledge"] == "/tmp/k")
        #expect(act.flags == ["seat", "dry-run", "allow-destructive", "allow-unvalidated-build"])
        let decoded = try ActionGrammar.request(.act, Words.Parsed(positionals: ["Auto-create sub paths"],
                                                                   values: ["verb": ["set_toggle"], "value": ["on"], "section": ["Paths"]]))
        #expect(decoded.isExactly(.act(target: "Auto-create sub paths", verb: .setToggle, value: .on, section: "Paths")))
        let plain = try Self.request(["act", "Create"])
        #expect(plain.isExactly(.act(target: "Create", verb: .click, value: nil, section: nil)), "click when absent, as before")
        let select = try Invocation(arguments: ["select", "Pro Tools", "Mono", "Stereo", "--seat", "--evidence", "/tmp/e"],
                                    spec: CommandSpecs.action(.select))
        #expect(select.positionals == ["Pro Tools", "Mono", "Stereo"] && select.options["evidence"] == "/tmp/e")
        let plan = try BatchPlan(arguments: ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--allow-unvalidated-build",
                                             "--", "select", "Mono", "Stereo", "--then", "act", "Auto-create sub paths",
                                             "--verb", "set_toggle", "--value", "on", "--then", "act", "Create"])
        #expect(plan.steps.map(\.summary) == [
            "select control=\"Mono\" item=\"Stereo\"",
            "act target=\"Auto-create sub paths\" verb=set_toggle value=on",
            "act target=\"Create\" verb=click",
        ])
    }

    // MARK: Grammar: the new invocations, golden

    @Test("each of the seven operations reads into the tools' request, with the decoder's defaults written out", arguments: [
        (["act", "Send"], "act target=\"Send\" verb=click"),
        (["act", "Bold", "--verb", "right_click", "--section", "Toolbar"], "act target=\"Bold\" verb=right_click section=\"Toolbar\""),
        (["select", "Format", "H.264"], "select control=\"Format\" item=\"H.264\""),
        (["type_text", "Body", "Hello, world"], "type_text target=\"Body\" text=\"Hello, world\" replace=true"),
        (["type_text", "Body", " ", "--append"], "type_text target=\"Body\" text=\" \" replace=false"),
        (["type_text", "Body", "--", "--then"], "type_text target=\"Body\" text=\"--then\" replace=true"),
        (["type_text", "--", "--x", "--", "--"], "type_text target=\"--x\" text=\"--\" replace=true"),
        (["press_key", "return"], "press_key key=return modifiers=[] count=1"),
        (["press_key", "A", "--modifier", "shift", "--modifier", "cmd", "--count", "2"], "press_key key=a modifiers=[cmd,shift] count=2"),
        (["press_key", "9", "--count", "20"], "press_key key=9 modifiers=[] count=20"),
        (["scroll", "down"], "scroll direction=down lines=3"),
        (["scroll", "up", "--target", "List", "--lines", "50", "--section", "Sidebar"],
         "scroll direction=up lines=50 target=\"List\" section=\"Sidebar\""),
        (["drag", "Clip", "--to", "Bin"], "drag from=\"Clip\" to=\"Bin\""),
        (["drag", "Clip", "--dy", "12"], "drag from=\"Clip\" dx=0 dy=12"),
        (["drag", "Clip", "--dx", "-3.5"], "drag from=\"Clip\" dx=-3.5 dy=0"),
        (["context_menu", "Text", "Copy", "--section", "Editor"], "context_menu target=\"Text\" item=\"Copy\" section=\"Editor\""),
    ])
    func goldens(_ words: [String], _ expected: String) throws {
        #expect(CallText.request(try Self.request(words), detail: true) == expected)
    }

    @Test("a word is passed as typed: Unicode in either normalization, quotes and separators stay the same bytes")
    func wordsArePassedAsTyped() throws {
        for text in ["Cafe\u{301}", "Caf\u{E9}", "日本語 ✓", "a|b;c \"q\"", "--then"] {
            guard case .typeText(_, let typed, _, _) = try Self.request(["type_text", "Body", "--", text]) else {
                Issue.record("not type_text"); continue
            }
            #expect(Array(typed.utf8) == Array(text.utf8))
        }
        guard case .act(let target, _, _, _) = try Self.request(["act", "Cafe\u{301}"]) else { Issue.record("not act"); return }
        #expect(Array(target.utf8) == Array("Cafe\u{301}".utf8), "no normalization: NFD stays NFD")
    }

    @Test("what the decoder or the grammar refuses is refused before anything runs", arguments: [
        ["act"], ["act", "A", "B"], ["act", "   "], ["act", "A", "--verb", "typo"], ["act", "A", "--value", "on"],
        ["act", "A", "--verb", "set_toggle"], ["act", "A", "--verb", "set_toggle", "--value", "maybe"],
        ["act", "A", "--section", "x", "--section", "y"], ["act", "A", "--section"], ["act", "A", "--section", "--then"],
        ["act", "A", "--window", "W"], ["act", "A", "--dry-run"], ["select", "Mono"], ["select", "Mono", ""],
        ["type_text", "Body"], ["type_text", "Body", ""], ["type_text", "Body", "x", "--append", "--append"],
        ["press_key", "F13"], ["press_key", "return", "--modifier", "hyper"], ["press_key", "return", "--modifier", "cmd", "--modifier", "cmd"],
        ["press_key", "return", "--count", "0"], ["press_key", "return", "--count", "21"], ["press_key", "return", "--count", "1.5"],
        ["press_key", "return", "--count", "1e2"], ["press_key", "return", "--count", "two"],
        ["scroll", "left"], ["scroll", "down", "--lines", "51"], ["scroll", "down", "--lines", ""],
        ["drag", "Clip"], ["drag", "Clip", "--to", "Bin", "--dx", "3"], ["drag", "Clip", "--dx", "6000"], ["drag", "Clip", "--dx", "inf"],
        ["context_menu", "Text"], ["context_menu", "Text", "Copy", "--verb", "click"], ["type_text", "Body", "--"],
        ["observe"], ["status"], [],
    ])
    func refusals(_ words: [String]) {
        #expect(throws: (any Error).self) { try ActionGrammar.step(words) }
    }

    @Test("a direct command refuses an unknown, repeated or misplaced option, and select or an input without --seat")
    func directCommandsAreChecked() throws {
        #expect(throws: (any Error).self) { try Invocation(arguments: ["act", "App", "X", "--seet"], spec: CommandSpecs.action(.act)) }
        #expect(throws: (any Error).self) {
            try Invocation(arguments: ["act", "App", "X", "--seat", "--seat"], spec: CommandSpecs.action(.act))
        }
        #expect(throws: (any Error).self) {
            try Invocation(arguments: ["press_key", "App", "return", "--evidence", "d"], spec: CommandSpecs.action(.pressKey))
        }
        #expect(throws: (any Error).self) { try Invocation(arguments: ["windows", "App", "--json"], spec: CommandSpecs.windows) }
        #expect(throws: (any Error).self) { try Invocation(arguments: ["memory", "status", "--seat"], spec: CommandSpecs.memory) }
        let repeated = try Invocation(arguments: ["press_key", "App", "a", "--modifier", "cmd", "--modifier", "opt", "--seat"],
                                      spec: CommandSpecs.action(.pressKey))
        #expect(repeated.values["modifier"] == ["cmd", "opt"])
    }

    @Test("a batch of the seven operations is decoded whole before adoption; one refused step refuses it and names the step")
    func aMixedBatchIsDecodedWhole() throws {
        let header = ["batch", "App", "--window", "Window", "--seat", "--"]
        let steps = ["act", "Create", "--then", "select", "Format", "H.264", "--then", "type_text", "Name", "Bus 1", "--then",
                     "press_key", "return", "--modifier", "cmd", "--then", "scroll", "down", "--lines", "5", "--then",
                     "drag", "Clip", "--to", "Bin", "--then", "context_menu", "Text", "Copy"]
        let plan = try BatchPlan(arguments: header + steps)
        #expect(plan.steps.map(\.request.tool) == ToolRequestDecoder.stepTools)
        let bad = steps.prefix(18) + ["--lines", "500"] + steps.dropFirst(20)
        do {
            _ = try BatchPlan(arguments: header + Array(bad))
            Issue.record("a refused fifth step was accepted")
        } catch let error as BatchPlanError {
            #expect(error.step == 5)
            #expect(error.description.contains("Nothing was run"))
        }
        let escaped = try BatchPlan(arguments: header + ["type_text", "Body", "--", "--then", "--then", "press_key", "return"])
        #expect(escaped.steps.count == 2)
        #expect(CallText.request(escaped.steps[0].request, detail: true) == "type_text target=\"Body\" text=\"--then\" replace=true")
        #expect(throws: (any Error).self) { try BatchPlan(arguments: header + ["act", "A", "--dry-run"]) }
        #expect(throws: (any Error).self) {
            try BatchPlan(arguments: ["batch", "App", "--window", "Window", "--seat", "--dry-run", "--", "act", "A"])
        }
    }

    // MARK: Recording

    @Test("a direct action is planned, started and completed under a cli trace, its samples and effect kept, read back after reopening")
    func aDirectActionIsRecorded() async throws {
        let directory = Self.directory()
        let memory = Self.memory(directory)
        let performer = ScriptedPerformer(memory: memory)
        let trace = CLITrace()
        var printed: [String] = []
        let outcome = try await StepRunner.single(try Self.request(["act", "Platform"]), performer: performer, memory: memory,
                                                  trace: trace, app: Self.app, output: { printed.append($0) })
        #expect(outcome.kind == .foundActed && performer.performed.count == 1)
        #expect(printed.first == "found_acted: scripted found_acted")
        await memory.close()
        let reopened = Self.memory(directory)
        let calls = try await reopened.calls(inTrace: trace.traceID, after: nil, limit: 10)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.event.source == .cli && call.event.streamID == trace.streamID && call.event.sessionID == trace.sessionID)
        #expect(call.progress.status == .completed && call.startedAtMS != nil && call.durationMS != nil)
        #expect(call.progress.observedEffect?.sceneEffect == .menuOpened(labels: ["Desktop"]))
        #expect(try await reopened.sample(CaptureSampleKey(eventID: call.event.eventID, phase: .before)) != nil)
        #expect(try await reopened.sample(CaptureSampleKey(eventID: call.event.eventID, phase: .after)) != nil)
        #expect(try await reopened.application(.record(eventID: call.event.eventID)) != nil, "the brain learned once from the effect")
        await reopened.close()
    }

    @Test("a mixed batch of the seven actions runs each once, in order, with its children and samples; acted_noop goes on only for set_toggle")
    func aMixedBatchIsRecorded() async throws {
        let memory = Self.memory()
        let performer = ScriptedPerformer(memory: memory)
        performer.outcomes = [.foundActed, .actedNoop, .foundActed, .foundActed, .foundActed, .foundActed, .foundActed, .foundActed]
        let plan = try BatchPlan(arguments: ["batch", "App", "--window", "W", "--seat", "--", "act", "Create", "--then",
                                             "act", "Auto", "--verb", "set_toggle", "--value", "on", "--then", "select", "F", "H",
                                             "--then", "type_text", "Name", "Bus", "--then", "press_key", "return", "--then",
                                             "scroll", "down", "--then", "drag", "Clip", "--dx", "4", "--then",
                                             "context_menu", "Text", "Copy"])
        let trace = CLITrace()
        let summary = try await StepRunner.batch(plan.steps, performer: performer, memory: memory, trace: trace, app: Self.app,
                                                 output: { _ in })
        #expect(summary == StepRunner.BatchSummary(attempted: 8, verified: 8))
        #expect(performer.performed.count == 8 && performer.checks == 8)
        let calls = try await memory.calls(inTrace: trace.traceID, after: nil, limit: 20)
        let batch = try #require(calls.first { $0.request.tool == .batch })
        if case .batch(let stopped, let attempted, let verified)? = batch.progress.result {
            #expect(!stopped && attempted == 8 && verified == 8)
        } else { Issue.record("no batch summary") }
        let steps = try await memory.steps(ofBatch: batch.event.eventID)
        #expect(steps.map(\.request.tool) == [.act, .act, .select, .typeText, .pressKey, .scroll, .drag, .contextMenu])
        #expect(steps.allSatisfy { $0.progress.status == .completed })
        #expect(steps.map(\.event.parentPosition) == Array(0..<8).map(Optional.init))
        for step in steps {
            #expect(try await memory.sample(CaptureSampleKey(eventID: step.event.eventID, phase: .before)) != nil)
        }
        await memory.close()
    }

    @Test("a step the rule does not accept stops the batch: the rest skipped, nothing repeated", arguments: [
        ActOutcomeKind.actedNoop, .honestMiss, .ambiguous, .actedUnverified, .refused,
    ])
    func aStopKeepsTheKnownAndSkipsTheRest(_ kind: ActOutcomeKind) async throws {
        let memory = Self.memory()
        let performer = ScriptedPerformer(memory: memory)
        performer.outcomes = [.foundActed, kind]
        let plan = try BatchPlan(arguments: ["batch", "App", "--window", "W", "--seat", "--", "act", "A", "--then",
                                             "press_key", "tab", "--then", "act", "C", "--then", "scroll", "up"])
        let trace = CLITrace()
        do {
            try await StepRunner.batch(plan.steps, performer: performer, memory: memory, trace: trace, app: Self.app, output: { _ in })
            Issue.record("the batch went on after \(kind)")
        } catch let failure as BatchFailure {
            #expect(failure.step == 2 && (failure.cause as? ActFailure)?.kind == kind)
        }
        #expect(performer.performed.count == 2, "no step after the stop, and none repeated")
        let calls = try await memory.calls(inTrace: trace.traceID, after: nil, limit: 20)
        let batch = try #require(calls.first { $0.request.tool == .batch })
        let steps = try await memory.steps(ofBatch: batch.event.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .completed, .skipped, .skipped])
        if case .outcome(let recorded, _)? = steps[1].progress.result { #expect(recorded == kind) }
        if case .batch(let stopped, let attempted, let verified)? = batch.progress.result {
            #expect(stopped && attempted == 2 && verified == 1)
        } else { Issue.record("no batch summary") }
        await memory.close()
    }

    @Test("an error, a lost window and a cancellation after an effect each stop the batch with what is known kept")
    func errorsAndCancellation() async throws {
        let memory = Self.memory()
        // An error thrown by the second step: failed with its error, the rest skipped.
        let failing = ScriptedPerformer(memory: memory)
        failing.throwAt = 2
        let trace = CLITrace()
        let plan = try BatchPlan(arguments: ["batch", "App", "--window", "W", "--seat", "--", "act", "A", "--then", "act", "B",
                                             "--then", "act", "C"])
        await #expect(throws: BatchFailure.self) {
            try await StepRunner.batch(plan.steps, performer: failing, memory: memory, trace: trace, app: Self.app, output: { _ in })
        }
        var steps = try await memory.steps(ofBatch: try #require(try await memory.calls(inTrace: trace.traceID, after: nil, limit: 9)
            .first { $0.request.tool == .batch }).event.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .failed, .skipped])
        // The window lost before the second step: that step failed before acting, nothing performed for it.
        let lost = ScriptedPerformer(memory: memory)
        lost.targetLostAt = 2
        let lostTrace = CLITrace()
        await #expect(throws: BatchFailure.self) {
            try await StepRunner.batch(plan.steps, performer: lost, memory: memory, trace: lostTrace, app: Self.app, output: { _ in })
        }
        #expect(lost.performed.count == 1)
        steps = try await memory.steps(ofBatch: try #require(try await memory.calls(inTrace: lostTrace.traceID, after: nil, limit: 9)
            .first { $0.request.tool == .batch }).event.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .failed, .skipped])
        // A stop that lands after the first step's effect: its outcome kept, the next never begun, the batch cancelled.
        let stopped = ScriptedPerformer(memory: memory)
        stopped.cancelAfter = 1
        let stopTrace = CLITrace()
        let task = Task { @MainActor in
            try await StepRunner.batch(plan.steps, performer: stopped, memory: memory, trace: stopTrace, app: Self.app, output: { _ in })
        }
        if case .success = await task.result { Issue.record("a cancelled batch completed") }
        #expect(stopped.performed.count == 1, "nothing ran after the stop and nothing was repeated")
        let batch = try #require(try await memory.calls(inTrace: stopTrace.traceID, after: nil, limit: 9).first { $0.request.tool == .batch })
        #expect(batch.progress.status == .cancelled)
        steps = try await memory.steps(ofBatch: batch.event.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .skipped, .skipped])
        await memory.close()
    }

    @Test("a cancellation before the first effect runs nothing: the call is never started and the performer never reached")
    func cancellationBeforeAnyEffect() async throws {
        let memory = Self.memory()
        let performer = ScriptedPerformer(memory: memory)
        let trace = CLITrace()
        let task = Task { @MainActor () -> ActOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StepRunner.single(try Self.request(["press_key", "return"]), performer: performer, memory: memory,
                                               trace: trace, app: Self.app, output: { _ in })
        }
        let result = await task.result
        if case .failure(let error) = result { #expect(error is CancellationError, "\(error)") } else { Issue.record("it ran") }
        #expect(performer.performed.isEmpty)
        let calls = try await memory.calls(inTrace: trace.traceID, after: nil, limit: 5)
        #expect(calls.allSatisfy { $0.progress.status != .started && $0.progress.status != .completed })
        await memory.close()
    }

    @Test("the cli source stays apart from the app's in one archive: two traces, each with its own source and counts")
    func cliAndAppTracesStayApart() async throws {
        let memory = Self.memory()
        let performer = ScriptedPerformer(memory: memory)
        let trace = CLITrace()
        _ = try await StepRunner.single(try Self.request(["act", "A"]), performer: performer, memory: memory, trace: trace,
                                        app: Self.app, output: { _ in })
        let appContext = ActionContext(source: .app, streamID: "worker-1", traceID: "app-message-1", sessionID: "s")
        _ = try await memory.record(try AgentCallRecord(event: appContext.event(app: Self.app, occurredAtMS: memory.clock.calendarMS()),
                                                        request: .observe))
        let traces = try await memory.traces(before: nil, limit: 10)
        #expect(Set(traces.map(\.traceID)) == [trace.traceID, "app-message-1"])
        #expect(traces.first { $0.traceID == trace.traceID }?.source == .cli)
        #expect(traces.first { $0.traceID == "app-message-1" }?.source == .app)
        #expect(traces.first { $0.traceID == trace.traceID }?.calls == 1, "one call, counted once")
        #expect(try await memory.brain(of: Self.app.bundleID)?.transitions.count == 1, "the one effect taught once")
        await memory.close()
    }
}
