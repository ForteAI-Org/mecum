//
//  VerticalStopTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AutomationMCP
import AutomationRuntime
import Darwin
import EngineCore
import Foundation
import Memory
import SeatDriving
import SeatSession
import SQLite3
import Testing
@testable import mecum

/// The stop of a direct command, through the composition the entry point calls: `VerticalInvocation`
/// (the stop, the scope, the task, the ending and its exit status) around `SeatRuntime.hold` (the Seat
/// brought up and let go) around `StepRunner` (the calls), over a stand-in Seat, a scripted performer
/// and a temporary memory. The stop is called the way `TerminalSignals` calls it; the real signals are
/// `VerticalSignalProcessTests`'. No application, Seat, provider or desktop: that the real window comes
/// back is for the live case C9-A.
@MainActor
@Suite("Vertical commands: one stop, the Seat let go, then the exit", .serialized)
struct VerticalStopTests {

    // MARK: Fixtures

    private static let app = AppContextIdentity(bundleID: "test.vertical-stop", version: "1.0")

    private static func memory(budget: Duration = .seconds(3)) -> MemoryService {
        MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-vertical-stop-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true),
                      configuration: MemoryService.Configuration(finalizationBudget: budget))
    }

    /// A Seat standing in for `SeatTarget`: it counts its starts and stops, notes whether the stop ran in
    /// a cancelled task, and answers the release it is given.
    private final class StandInSeat: SeatHolding {
        var release = SeatTargetRelease(windows: [41: .returned], teardown: TeardownReport(
            displayRemoved: true, fenceReleased: true, mainDisplayRestored: true, topologyRestoration: nil,
            windows: [:], removalNanoseconds: 1))
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var stoppedInACancelledTask: Bool?
        private(set) var events: [String] = []

        func start() async throws {
            starts += 1
            events.append("start")
        }

        func stop() async -> SeatTargetRelease {
            stops += 1
            stoppedInACancelledTask = Task.isCancelled
            // A pause the way the Driver's return waits: a cancelled task would end it at once.
            try? await Task.sleep(for: .milliseconds(20))
            events.append(Task.isCancelled ? "stop-cut" : "stop")
            return release
        }

        func note(_ event: String) { events.append(event) }
    }

    /// A performer standing in for the engine: each step runs `during` (where a test sends the stop, holds
    /// the archive or waits for the cancellation), notes the scope it ran under, then answers `found_acted`.
    private final class Performer: StepPerforming {
        var during: (Int) async throws -> Void = { _ in }
        var throwAt: Int?
        private(set) var performed = 0
        private(set) var scopes: [MemoryFinalizationScope?] = []

        func checkTarget() throws {}

        func perform(_ request: AgentCallRequest, context: ActionContext, evidence: String?) async throws -> StepResult {
            performed += 1
            scopes.append(MemoryFinalizationScope.current)
            if throwAt == performed { throw AutomationFailure("scripted failure at step \(performed)") }
            try await during(performed)
            return StepResult(outcome: ActOutcome(.foundActed, "scripted found_acted"), report: nil)
        }
    }

    private static func steps() throws -> [BatchStep] {
        try BatchPlan(arguments: ["batch", "App", "--window", "W", "--seat", "--", "act", "A", "--then", "act", "B",
                                  "--then", "act", "C"]).steps
    }

    /// The direct action as `ActionCommand` composes it: the Seat held around one call.
    private static func action(_ seat: StandInSeat, _ performer: Performer, _ memory: MemoryService,
                               _ trace: CLITrace) -> @MainActor () async throws -> Void {
        {
            do {
                try await SeatRuntime.hold(seat, bringUp: { $0.note("adopted") }, { _ in
                    _ = try await StepRunner.single(try ActionGrammar.step(["act", "A"]), performer: performer, memory: memory,
                                                    trace: trace, app: app, output: { _ in })
                }, say: { _ in })
            } catch {
                await memory.close()
                throw error
            }
            await memory.close()
        }
    }

    /// The batch as `BatchCommand` composes it.
    private static func batch(_ seat: StandInSeat, _ performer: Performer, _ memory: MemoryService,
                              _ trace: CLITrace) -> @MainActor () async throws -> Void {
        {
            do {
                try await SeatRuntime.hold(seat, bringUp: { $0.note("adopted") }, { _ in
                    try await StepRunner.batch(try steps(), performer: performer, memory: memory, trace: trace, app: app,
                                               output: { _ in })
                }, say: { _ in })
            } catch {
                await memory.close()
                throw error
            }
            await memory.close()
        }
    }

    private static func batchCall(_ memory: MemoryService, _ trace: CLITrace) async throws -> (AgentCall, [AgentCall]) {
        let calls = try await memory.calls(inTrace: trace.traceID, after: nil, limit: 20)
        let batch = try #require(calls.first { $0.request.tool == .batch })
        return (batch, try await memory.steps(ofBatch: batch.event.eventID))
    }

    // MARK: Normal completion

    @Test("a command not stopped finishes: exit 0, the Seat let go once, the call completed, the scope never stopped")
    func aNormalCommandFinishes() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        let invocation = VerticalInvocation(say: { _ in })
        let ending = await invocation.run(Self.action(seat, performer, memory, trace))
        guard case .finished = ending else { Issue.record("\(ending)"); return }
        #expect(VerticalInvocation.status(ending) == 0 && VerticalInvocation.summary(ending) == nil)
        #expect(seat.events == ["start", "adopted", "stop"] && seat.stoppedInACancelledTask == false)
        #expect(performer.performed == 1)
        #expect(performer.scopes.count == 1 && performer.scopes[0] === invocation.scope, "the command runs under the invocation's scope")
        #expect(invocation.scope.stopInstant == nil)
        let reopened = MemoryService(directory: memory.directory)
        let calls = try await reopened.calls(inTrace: trace.traceID, after: nil, limit: 5)
        #expect(calls.map(\.progress.status) == [.completed])
        await reopened.close()
    }

    // MARK: The stop

    @Test("a stop before the command starts it cancelled: no Seat brought up, nothing performed, exit 130")
    func aStopBeforeTheCommand() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        var said: [String] = []
        let invocation = VerticalInvocation(say: { said.append($0) })
        invocation.stop(SIGINT)
        let ending = await invocation.run(Self.action(seat, performer, memory, trace))
        guard case .stopped(let signal, let error) = ending else { Issue.record("\(ending)"); return }
        #expect(signal == SIGINT && error is CancellationError)
        #expect(VerticalInvocation.status(ending) == 130)
        #expect(VerticalInvocation.summary(ending) == "mecum: stopped by SIGINT")
        #expect(seat.starts == 0 && seat.stops == 0 && performer.performed == 0)
        #expect(invocation.scope.stopInstant != nil)
        #expect(said.count == 1 && said[0].hasPrefix("mecum: SIGINT received"))
        await memory.close()
    }

    @Test("a stop during a batch's step: the step's known outcome kept, no further step, the Seat let go outside the cancellation, exit 130")
    func aStopDuringABatch() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        let invocation = VerticalInvocation(say: { _ in })
        var stoppedAt: ContinuousClock.Instant?
        performer.during = { step in
            if step == 1 {
                invocation.stop(SIGINT)
                stoppedAt = invocation.scope.stopInstant
            }
        }
        let ending = await invocation.run(Self.batch(seat, performer, memory, trace))
        guard case .stopped(let signal, let error) = ending else { Issue.record("\(ending)"); return }
        #expect(signal == SIGINT && VerticalInvocation.status(ending) == 130)
        #expect((error as? BatchFailure)?.step == 2 && (error as? BatchFailure)?.cause is CancellationError)
        #expect(performer.performed == 1, "no step after the stop, none repeated")
        #expect(seat.events == ["start", "adopted", "stop"], "the release ran once and was not cut")
        #expect(seat.stoppedInACancelledTask == false)
        #expect(stoppedAt != nil && invocation.scope.stopInstant == stoppedAt, "the stop is the scope's one instant")
        let reopened = MemoryService(directory: memory.directory)
        let (batch, steps) = try await Self.batchCall(reopened, trace)
        #expect(batch.progress.status == .cancelled)
        #expect(steps.map(\.progress.status) == [.completed, .skipped, .skipped])
        await reopened.close()
    }

    @Test("a stop while an action waits: the action ends at its cancellation point, recorded cancelled, never replayed; the Seat let go")
    func aStopDuringAnAction() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        let invocation = VerticalInvocation(say: { _ in })
        performer.during = { _ in
            Task { @MainActor in invocation.stop(SIGTERM) }
            try await Task.sleep(for: .seconds(30))
        }
        let started = ContinuousClock.now
        let ending = await invocation.run(Self.action(seat, performer, memory, trace))
        guard case .stopped(let signal, let error) = ending else { Issue.record("\(ending)"); return }
        #expect(signal == SIGTERM && error is CancellationError && VerticalInvocation.status(ending) == 143)
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(performer.performed == 1)
        #expect(seat.events == ["start", "adopted", "stop"] && seat.stoppedInACancelledTask == false)
        let reopened = MemoryService(directory: memory.directory)
        let calls = try await reopened.calls(inTrace: trace.traceID, after: nil, limit: 5)
        #expect(calls.map(\.progress.status) == [.cancelled])
        await reopened.close()
    }

    @Test("a second and a third signal start nothing: one stop instant, one line said, one release, the first signal's status")
    func aSecondSignalStartsNothing() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        var said: [String] = []
        let invocation = VerticalInvocation(say: { said.append($0) })
        var first: ContinuousClock.Instant?
        performer.during = { _ in
            invocation.stop(SIGINT)
            first = invocation.scope.stopInstant
            try? await Task.sleep(for: .milliseconds(5))
            invocation.stop(SIGINT)
            invocation.stop(SIGTERM)
        }
        let ending = await invocation.run(Self.batch(seat, performer, memory, trace))
        #expect(VerticalInvocation.status(ending) == 130)
        #expect(said.filter { $0.contains("received") }.count == 1)
        #expect(invocation.scope.stopInstant == first)
        #expect(seat.stops == 1 && performer.performed == 1)
        invocation.stop(SIGINT)
        #expect(seat.stops == 1, "a signal after the end starts no cleanup")
    }

    // MARK: Errors

    @Test("an error of the command still lets the Seat go once, outside any cancellation; the error is the ending, exit 1")
    func aBodyErrorStillReleases() async throws {
        let memory = Self.memory(), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        performer.throwAt = 1
        let invocation = VerticalInvocation(say: { _ in })
        let ending = await invocation.run(Self.batch(seat, performer, memory, trace))
        guard case .failed(let error) = ending else { Issue.record("\(ending)"); return }
        #expect((error as? BatchFailure)?.cause is AutomationFailure)
        #expect(VerticalInvocation.status(ending) == 1)
        #expect(seat.events == ["start", "adopted", "stop"])
        let reopened = MemoryService(directory: memory.directory)
        let (_, steps) = try await Self.batchCall(reopened, trace)
        #expect(steps.map(\.progress.status) == [.failed, .skipped, .skipped])
        await reopened.close()
    }

    @Test("a release that leaves a window away or the display up is an error, never a return: alone, after an error, after a stop")
    func aCleanupErrorIsKept() async throws {
        let incomplete = SeatTargetRelease(windows: [41: .returned, 57: .refused], teardown: TeardownReport(
            displayRemoved: false, fenceReleased: true, mainDisplayRestored: true, topologyRestoration: nil,
            windows: [:], removalNanoseconds: 1))
        #expect(!incomplete.isComplete && incomplete.windowsNotReturned == [57])
        #expect(SeatRuntime.describe(incomplete)
                == "seat: release incomplete: window #57 not returned; virtual display not removed (#41 returned, #57 refused)")
        // The command did what was asked; the release did not: exit 1, the release named.
        var memory = Self.memory()
        var seat = StandInSeat()
        seat.release = incomplete
        var ending = await VerticalInvocation(say: { _ in }).run(Self.action(seat, Performer(), memory, CLITrace()))
        guard case .failed(let alone as SeatReleaseFailure) = ending else { Issue.record("\(ending)"); return }
        #expect(alone.after == nil && VerticalInvocation.status(ending) == 1)
        #expect(VerticalInvocation.summary(ending)?.contains("window #57 not returned") == true)
        // The command failed first: both kept.
        memory = Self.memory()
        seat = StandInSeat()
        seat.release = incomplete
        let failing = Performer()
        failing.throwAt = 1
        ending = await VerticalInvocation(say: { _ in }).run(Self.action(seat, failing, memory, CLITrace()))
        guard case .failed(let both as SeatReleaseFailure) = ending else { Issue.record("\(ending)"); return }
        #expect(both.after is AutomationFailure)
        #expect(both.description.hasPrefix("scripted failure at step 1; then the seat's release incomplete"))
        // A stop: exit 130, the incomplete release still said in the last line.
        memory = Self.memory()
        seat = StandInSeat()
        seat.release = incomplete
        let invocation = VerticalInvocation(say: { _ in })
        let stopping = Performer()
        stopping.during = { _ in invocation.stop(SIGINT) }
        ending = await invocation.run(Self.batch(seat, stopping, memory, CLITrace()))
        guard case .stopped(SIGINT, let stopped as SeatReleaseFailure) = ending else { Issue.record("\(ending)"); return }
        #expect(stopped.after is BatchFailure && VerticalInvocation.status(ending) == 130)
        #expect(VerticalInvocation.summary(ending)?.hasPrefix("mecum: stopped by SIGINT: batch stopped at step 2/3") == true)
        #expect(VerticalInvocation.summary(ending)?.contains("window #57 not returned") == true)
        #expect(seat.stops == 1)
    }

    // MARK: The memory under contention

    @Test("held archive at the stop: one budget from the stop for every finalization, nothing replayed, the Seat let go once")
    func theStopBoundsTheMemoryOnce() async throws {
        let budget = Duration.milliseconds(400)
        let memory = Self.memory(budget: budget), seat = StandInSeat(), performer = Performer(), trace = CLITrace()
        _ = await memory.ready()
        let invocation = VerticalInvocation(say: { _ in })
        var holder: OpaquePointer?
        var stoppedAt: ContinuousClock.Instant?
        performer.during = { step in
            // After the first step's effect another process takes the archive, then the person stops.
            try #require(sqlite3_open(memory.url.path, &holder) == SQLITE_OK)
            try #require(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            invocation.stop(SIGINT)
            stoppedAt = invocation.scope.stopInstant
        }
        let ending = await invocation.run(Self.batch(seat, performer, memory, trace))
        let ended = ContinuousClock.now
        #expect(VerticalInvocation.status(ending) == 130)
        let stop = try #require(stoppedAt)
        // The first finalization waits until the deadline; every later one is a gap at once.
        #expect(stop.duration(to: ended) >= budget)
        #expect(stop.duration(to: ended) < budget * 2 + .seconds(1), "one budget, not one per write")
        #expect(performer.performed == 1 && seat.stops == 1 && seat.stoppedInACancelledTask == false)
        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
        sqlite3_close(holder)
        // What the archive keeps: the first step started, its end a gap; nothing else ran or was replayed.
        let reopened = MemoryService(directory: memory.directory)
        let (batch, steps) = try await Self.batchCall(reopened, trace)
        #expect(batch.progress.status == .started)
        #expect(steps.map(\.progress.status) == [.started, .planned, .planned])
        await reopened.close()
    }
}
