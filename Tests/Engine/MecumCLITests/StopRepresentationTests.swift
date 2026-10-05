//
//  StopRepresentationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import Darwin
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing
@testable import mecum

/// How a stop is written in the memory when it reaches the engine: the real `ActionEngine` over a scene
/// source that answers what a stopped capture answers (`CancellationError`), a capture that really failed,
/// or a scene, driven by the vertical command's `StepRunner` under its invocation, and read back from the
/// archive. A stop before the scene is `cancelled`; a failure to read it is the engine's honest miss,
/// `completed`; a stop after the gesture keeps the gesture's known outcome. No Seat, no screen.
@MainActor
@Suite("A stop is written as a stop", .serialized)
struct StopRepresentationTests {

    final class Scenes: SceneProviding, @unchecked Sendable {
        var answers: [Result<PerceivedWindow, any Error>]
        /// Runs as the scene is read, before it answers: where a test sends the stop.
        var onRead: () -> Void = {}
        init(_ answers: [Result<PerceivedWindow, any Error>]) { self.answers = answers }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            onRead()
            return try (answers.count > 1 ? answers.removeFirst() : answers[0]).get()
        }
    }

    final class Actuator: Actuating, @unchecked Sendable {
        var gestures = 0
        var onGesture: () -> Void = {}
        func perform(_ gesture: Gesture, in processID: pid_t) async throws { gestures += 1; onGesture() }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    struct Windows: WindowListing {
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            [WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Export", number: 1)]
        }
    }

    struct CaptureBroke: Error {}

    /// The engine as the vertical command's performer runs it, over the doubles.
    final class EnginePerformer: StepPerforming {
        let engine: ActionEngine
        init(_ engine: ActionEngine) { self.engine = engine }
        func checkTarget() throws {}
        func perform(_ request: AgentCallRequest, context: ActionContext, evidence: String?) async throws -> StepResult {
            StepResult(outcome: try await engine.act(ActionRequest(
                processID: 4242, bundleID: "com.x", appName: "X", target: "Export", verb: .click,
                section: nil, desiredState: nil, isDryRun: false
            )), report: nil)
        }
    }

    private static let window = PerceivedWindow(scene: SceneSnapshot(
        bundleID: "com.x", appName: "X", windowTitle: "Export",
        viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
        elements: [SceneElement(id: "control|export", kind: .control, label: "Export",
                                bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.08, height: 0.03))]
    ), frame: CGRect(x: 100, y: 100, width: 1000, height: 800))

    private static func memory() -> MemoryService {
        MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-stop-representation-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true))
    }

    /// One `act` through the invocation and the runner; answers the ending and the call read back.
    private static func run(_ scenes: Scenes, _ actuator: Actuator, invocation: VerticalInvocation = VerticalInvocation(say: { _ in }))
        async throws -> (VerticalInvocation.Ending, AgentCall) {
        let memory = memory(), trace = CLITrace()
        let engine = ActionEngine(ActionEngine.Dependencies(scenes: scenes, actuator: actuator, windows: Windows()), pause: { _ in })
        let ending = await invocation.run {
            _ = try await StepRunner.single(try ActionGrammar.step(["act", "Export"]), performer: EnginePerformer(engine),
                                            memory: memory, trace: trace, app: nil, output: { _ in })
        }
        await memory.close()
        let reopened = MemoryService(directory: memory.directory)
        let call = try #require(try await reopened.calls(inTrace: trace.traceID, after: nil, limit: 5).first)
        await reopened.close()
        return (ending, call)
    }

    @Test("a stop that reaches the scene before any effect is recorded cancelled, nothing performed")
    func aStopBeforeTheSceneIsCancelled() async throws {
        let actuator = Actuator()
        let invocation = VerticalInvocation(say: { _ in })
        let scenes = Scenes([.failure(CancellationError())])
        scenes.onRead = { invocation.stop(SIGINT) }
        let (ending, call) = try await Self.run(scenes, actuator, invocation: invocation)
        #expect(VerticalInvocation.status(ending) == 130)
        #expect(call.progress.status == .cancelled, "\(call.progress)")
        #expect(actuator.gestures == 0)
    }

    @Test("the scene stopped mid-call without a stop of the invocation is still the engine's typed cancellation")
    func aCancelledCaptureIsCancelled() async throws {
        let actuator = Actuator()
        let (_, call) = try await Self.run(Scenes([.failure(CancellationError())]), actuator)
        #expect(call.progress.status == .cancelled, "\(call.progress)")
    }

    @Test("a capture that really failed stays the engine's honest miss, completed, with its advice")
    func aCaptureFailureIsAMiss() async throws {
        let actuator = Actuator()
        let (ending, call) = try await Self.run(Scenes([.failure(CaptureBroke())]), actuator)
        guard case .finished = ending else { Issue.record("\(ending)"); return }
        #expect(call.progress.status == .completed)
        if case .outcome(let kind, let message)? = call.progress.result {
            #expect(kind == .honestMiss && message.contains("Screen Recording"))
        } else { Issue.record("no outcome: \(String(describing: call.progress.result))") }
    }

    @Test("a stop after the gesture keeps its known outcome, completed, the gesture not repeated")
    func aStopAfterTheGestureKeepsTheOutcome() async throws {
        let actuator = Actuator()
        let invocation = VerticalInvocation(say: { _ in })
        actuator.onGesture = { invocation.stop(SIGINT) }
        let (ending, call) = try await Self.run(Scenes([.success(Self.window), .failure(CancellationError())]), actuator,
                                                invocation: invocation)
        #expect(VerticalInvocation.status(ending) == 130)
        #expect(actuator.gestures == 1)
        #expect(call.progress.status == .completed)
        if case .outcome(let kind, _)? = call.progress.result { #expect(kind == .actedUnverified) }
        else { Issue.record("no outcome") }
    }
}
