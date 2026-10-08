//
//  UncertainInputTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 08/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// PM-05: an uncertain input, a wrong or unreadable state, an interrupted batch and a wrong final result,
/// through the tools as a worker or an MCP client drives them, with the memory recording each call. The
/// session simulates a calculator for real: every key the tools send changes its display, so a test checks
/// the inputs sent, the effect they had, the state the caller could read, and what the call and the memory
/// say, never the text of a prompt.
@MainActor
@Suite("Uncertain input and resumption, through the tools with the memory")
struct UncertainInputTests {

    private static let bundle = "com.apple.calculator"
    private static let trace  = "calculator-trace"

    private func tools(_ session: CalculatorSession) -> AutomationTools {
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "worker-1", traceID: Self.trace)
        return tools
    }

    private func batch(_ keys: [String], in session: CalculatorSession) -> JSONValue {
        .object(["session": .string(session.id!.uuidString),
                 "steps"  : .array(keys.map { .object(["operation": .string("act"), "target": .string($0)]) })])
    }

    /// The batches of the trace, each with its steps in order, as the memory holds them.
    private func batches(_ session: CalculatorSession) async throws -> [(batch: AgentCall, steps: [AgentCall])] {
        let service = MemoryService.shared(for: session.directory)
        #expect(await service.flush(within: .seconds(10)))
        let status = await service.status()
        #expect(status.failed == 0 && status.partial == 0, "\(status.lastFailure ?? "")")
        var found: [(AgentCall, [AgentCall])] = []
        for call in try await service.calls(inTrace: Self.trace) where call.request.tool == .batch {
            found.append((call, try await service.ready().calls.steps(ofBatch: call.event.eventID)))
        }
        return found
    }

    /// No call of the trace is left planned or started once the producers are done.
    private func nothingUnfinished(_ session: CalculatorSession) async throws {
        let calls = try await MemoryService.shared(for: session.directory).calls(inTrace: Self.trace)
        let unfinished = calls.filter { $0.progress.status == .planned || $0.progress.status == .started }
        #expect(unfinished.isEmpty, "unfinished calls: \(unfinished.map { "\($0.request.tool) \($0.progress.status)" })")
    }

    @Test("the second key took effect but came back unverified: the batch stops there, nothing is sent again, the rest is recorded as never run")
    func uncertainKeyStopsTheBatch() async throws {
        let session = try CalculatorSession()
        session.outcomes[2] = .actedUnverified
        let answer = try await tools(session).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2"], "the uncertain key is not sent again and no later key is sent")
        #expect(session.display == "12", "the key took effect")
        #expect(answer["status"].string == "stopped")
        #expect(answer["attemptedSteps"] == .number(2) && answer["verifiedSteps"] == .number(1))
        #expect(answer["steps"].array?.last?["status"].string == "acted_unverified")

        let recorded = try #require(try await batches(session).first)
        guard case .batch(let stopped, let attempted, let verified)? = recorded.batch.progress.result else {
            Issue.record("the batch's result is not a batch summary: \(String(describing: recorded.batch.progress.result))"); return
        }
        #expect(stopped && attempted == 2 && verified == 1)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .skipped, .skipped, .skipped, .skipped])
        if case .outcome(let kind, _)? = recorded.steps[1].progress.result { #expect(kind == .actedUnverified) }
        else { Issue.record("the uncertain step's outcome is not recorded") }
        try await nothingUnfinished(session)
    }

    @Test("a caller that reads the state after the uncertain key resumes from it: every key reaches the calculator once, and 42 is what it reads")
    func resumptionFromTheObservedState() async throws {
        let session = try CalculatorSession()
        session.outcomes[2] = .actedUnverified
        let tools = tools(session)
        _ = try await tools.call("batch", batch(["1", "2", "+", "3", "0", "="], in: session))

        let observed = try await tools.call("observe", .object(["session": .string(session.id!.uuidString),
                                                                 "full"   : .bool(true)])).payload
        #expect(observed["scene"].string?.contains("[text] 12 ") == true,
                "the fresh observation shows what the uncertain key did")
        let answer = try await tools.call("batch", batch(["+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+", "3", "0", "="], "each key once")
        #expect(session.display == "42")
        #expect(answer["status"].string == "completed" && answer["verifiedSteps"] == .number(4))
        let recorded = try await batches(session)
        #expect(recorded.count == 2)
        #expect(recorded.last?.steps.map(\.progress.status) == [.completed, .completed, .completed, .completed])
        try await nothingUnfinished(session)
    }

    @Test("a key the tools cannot find or may not press stops the batch with nothing invented after it", arguments: [
        ActOutcomeKind.honestMiss, .refused, .ambiguous,
    ])
    func wrongStateStopsTheBatch(_ kind: ActOutcomeKind) async throws {
        let session = try CalculatorSession()
        session.outcomes[3] = kind
        let answer = try await tools(session).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+"])
        #expect(answer["status"].string == "stopped" && answer["verifiedSteps"] == .number(2))
        #expect(answer["steps"].array?.last?["status"].string == kind.rawValue)
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .completed, .skipped, .skipped, .skipped])
        try await nothingUnfinished(session)
    }

    @Test("a step that fails mid-batch: the keys before it keep their effect, nothing after it is sent, nothing is replayed")
    func failedStepStopsTheBatch() async throws {
        let session = try CalculatorSession()
        session.failsAt = 3
        let answer = try await tools(session).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+"] && session.display == "12", "the effects before the failure stay, and are not undone")
        #expect(answer["status"].string == "stopped" && answer["verifiedSteps"] == .number(2))
        #expect(answer["steps"].array?.last?["status"].string == "error")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .failed, .skipped, .skipped, .skipped])
        try await nothingUnfinished(session)
    }

    @Test("a batch cancelled between two keys: the call ends with the cancellation, nothing after it is sent, and the keys it never sent are recorded as never run")
    func cancelledBatchRecordsTheRestAsNeverRun() async throws {
        let session = try CalculatorSession()
        session.cancelsAt = 3
        let tools = tools(session), request = batch(["1", "2", "+", "3", "0", "="], in: session)
        // The call runs in a task of its own, the one the session cancels, as a client's cancellation would.
        let call = Task { try await tools.call("batch", request) }
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(session.inputs == ["1", "2", "+"], "no key after the cancellation")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.batch.progress.status == .failed)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .completed, .skipped, .skipped, .skipped])
        try await nothingUnfinished(session)
    }

    @Test("every key verified but the result is 41: the batch says its steps completed and shows 41; nothing claims the task succeeded")
    func completedBatchIsNotATaskSuccess() async throws {
        let session = try CalculatorSession()
        session.wrongResult = "41"
        let answer = try await tools(session).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.display == "41")
        #expect(answer["status"].string == "completed" && answer["verifiedSteps"] == .number(6))
        let last = String(decoding: try JSONEncoder().encode(answer["steps"].array?.last ?? .null), as: UTF8.self)
        #expect(last.contains("[text] 41 "), "the last step's observation carries the display the caller must judge: \(last)")
        #expect(Set(answer.object.map { Array($0.keys) } ?? []) == ["status", "steps", "attemptedSteps", "verifiedSteps", "requested"],
                "a batch reports its steps, not a task's outcome")
        let recorded = try #require(try await batches(session).first)
        guard case .batch(let stopped, let attempted, let verified)? = recorded.batch.progress.result else {
            Issue.record("no batch summary"); return
        }
        #expect(!stopped && attempted == 6 && verified == 6)
        try await nothingUnfinished(session)
    }
}

/// CalculatorSession is a session over a simulated calculator: every key `act` names changes the display
/// as the real one would, and the outcome each key answers is scripted by its position, so an uncertain
/// verdict can follow a key that really took effect. It records every key sent.
@MainActor
final class CalculatorSession: AutomationSessionOperating {

    let directory: URL
    var id: UUID? = UUID()

    /// What the key at each position (from 1) answers; any other answers found_acted.
    var outcomes: [Int: ActOutcomeKind] = [:]
    /// The key at this position throws instead of acting.
    var failsAt: Int?
    /// The key at this position cancels the task that runs the call, after its effect.
    var cancelsAt: Int?
    /// What `=` shows instead of the sum.
    var wrongResult: String?

    private(set) var inputs: [String] = []
    private(set) var display = "0"
    private var left: Int?
    private var entry = ""

    init() throws {
        directory = try W.directory()
    }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { "com.apple.calculator" }

    func open(application: String, window: String?) async throws -> SceneSnapshot { scene() }
    func observe() async throws -> SceneSnapshot { scene() }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let position = inputs.count + 1
        if failsAt == position {
            inputs.append(target)
            throw AutomationFailure("The calculator's window went away.")
        }
        inputs.append(target)
        press(target)
        if cancelsAt == position { withUnsafeCurrentTask { $0?.cancel() } }
        return ActOutcome(outcomes[position] ?? .foundActed, "clicked '\(target)'", scene: scene())
    }

    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("not here") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("not here") }
    func close() async { id = nil }

    private func press(_ key: String) {
        switch key {
        case "+":
            left  = Int(display)
            entry = ""
        case "=":
            let sum = (left ?? 0) + (Int(entry) ?? 0)
            display = wrongResult ?? String(sum)
            entry   = ""
        default:
            entry   = entry == "0" ? key : entry + key
            display = entry
        }
    }

    private func scene() -> SceneSnapshot {
        let keys = ["1", "2", "3", "0", "+", "="].enumerated().map { index, key in
            SceneElement(id: "control|\(key)", kind: .control, label: key,
                         bounds: NormalizedRect(x: 0.1 + 0.12 * Double(index), y: 0.6, width: 0.1, height: 0.1),
                         role: "AXButton", labelOrigin: .title)
        }
        let shown = SceneElement(id: "text|display", kind: .text, label: display,
                                 bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.15), role: "AXStaticText")
        return SceneSnapshot(bundleID: "com.apple.calculator", appName: "Calculator", windowTitle: "Calculator",
                             viewportPixelSize: ViewportPixelSize(width: 460, height: 816), elements: [shown] + keys)
    }
}

extension JSONValue {

    /// A tool result's value as the model reads it: the JSON text of its one content item.
    var payload: JSONValue {
        guard let text = self["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return self }
        return value
    }
}
