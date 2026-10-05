//
//  Runtime.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SeatDriving

/// Runtime keeps terminal parsing in the CLI while all consumers share EngineRuntime's composition.
typealias Runtime = EngineRuntime

extension EngineRuntime {
    init(invocation: Invocation, seat: SeatTarget? = nil, memory: MemoryService) {
        self.init(memory: memory, seat: seat)
    }
}

/// CLIMemory is how a vertical command owns its living memory: one `MemoryService` per invocation
/// over the `--knowledge` directory (or the default), opened before the first call with its status
/// said on standard error, and closed when the command ends. The command's calls are recorded as the
/// tools' are, from the `cli` source under one trace (the invocation) and one session (the seat the
/// command brought up, or the invocation itself without one), so what `mecum act` did is read back
/// like what the chat did. A memory that cannot be used is one line on standard error; the command
/// goes on without it.
enum CLIMemory {

    static func directory(_ invocation: Invocation) -> URL {
        if let path = invocation.options["knowledge"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mecum/Knowledge", isDirectory: true)
    }

    /// The invocation's service, opened, its status said.
    static func open(_ invocation: Invocation) async -> MemoryService {
        let service = MemoryService(directory: directory(invocation))
        let status  = await service.ready()
        say(status.sentence)
        return service
    }

    static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// CLITrace is one invocation's identity in the memory: this process as the stream, the invocation as
/// the trace, and the session every call that takes one names.
struct CLITrace {

    let streamID  = "mecum-cli-\(ProcessInfo.processInfo.processIdentifier)"
    let traceID   = UUID().uuidString
    let sessionID = UUID().uuidString

    func context(_ tool: AgentTool, parent: ActionContext? = nil, position: Int? = nil) -> ActionContext {
        ActionContext(
            source        : .cli,
            streamID      : streamID,
            traceID       : traceID,
            sessionID     : tool.takesSession ? sessionID : nil,
            parentEventID : parent?.eventID,
            parentPosition: position
        )
    }
}

/// CLICall records one command's call as the tools record theirs: `planned` with its decoded
/// arguments and `started` before any effect, then concluded with its outcome, the effect the engine
/// observed and the monotonic duration of the run, failed with its error, cancelled, or skipped when
/// a batch stopped before it. The task's cancellation ends the call in `begin`, wherever it lands in
/// a write or its wait, and nothing runs; a memory that refuses for any other reason is one line on
/// standard error, and the command goes on. The end of a call that ran is a finalization: the
/// cancellation does not cut it, a busy archive is waited out with the command, the invocation's one
/// budget bounds the waits only once it is stopped (`MemoryFinalizationScope`, owned by
/// `VerticalInvocation` and stopped by its signal), and what is not saved is said.
@MainActor
final class CLICall {

    let memory: MemoryService
    let request: AgentCallRequest
    let context: ActionContext
    let app: AppContextIdentity?
    private(set) var isStored = false
    private var startedNS: Int64?

    init(memory: MemoryService, request: AgentCallRequest, context: ActionContext, app: AppContextIdentity?) {
        self.memory  = memory
        self.request = request
        self.context = context
        self.app     = app
    }

    var record: AgentCallRecord {
        get throws {
            try AgentCallRecord(
                event  : context.event(app: app, occurredAtMS: memory.clock.calendarMS(), monotonicNS: memory.clock.monotonicNS()),
                request: request
            )
        }
    }

    /// Records the call planned and started, before any effect. Throws `CancellationError` when the
    /// task was cancelled meanwhile; nothing has run.
    func begin() async throws {
        do {
            _ = try await memory.record(try record)
            isStored = true
        } catch {
            if MemoryService.isCancellation(error) { throw CancellationError() }
            say("could not record \(request.tool.rawValue)", error)
        }
        try await start()
    }

    /// Records a batch's step started, before its effect: the step was planned with its batch
    /// (`begin(batch:steps:)`), so only its start is written here. Throws `CancellationError` when the
    /// task was cancelled meanwhile; nothing has run.
    func beginStep() async throws {
        try await start()
    }

    /// Records a batch with its steps planned, then the batch started, before any effect.
    static func begin(batch: CLICall, steps: [CLICall]) async throws {
        do {
            _ = try await batch.memory.record(batch: try batch.record, steps: try steps.map { try $0.record })
            batch.isStored = true
            for step in steps { step.isStored = true }
        } catch {
            if MemoryService.isCancellation(error) { throw CancellationError() }
            batch.say("could not record batch", error)
        }
        try await batch.start()
    }

    /// Records `started` at the calendar and takes the monotonic reading the duration is measured from.
    private func start() async throws {
        if isStored {
            do {
                _ = try await memory.advance([AgentCallTransition(context.eventID, .started(atMS: memory.clock.calendarMS()))])
            } catch {
                if MemoryService.isCancellation(error) { throw CancellationError() }
                say("could not record \(request.tool.rawValue) started", error)
            }
        }
        try Task.checkCancellation()
        startedNS = memory.clock.monotonicNS()
    }

    private var duration: Int64? {
        startedNS.map { MemoryClock.durationMS(from: $0, to: memory.clock.monotonicNS()) }
    }

    func complete(_ result: AgentCallResult?, effect: SceneEffect? = nil) async {
        await finalize(AgentCallProgress(.completed, result: result, endedAtMS: memory.clock.calendarMS(),
                                         durationMS: duration, observedEffect: effect.map(ObservedEffect.init)))
    }

    func fail(_ error: any Error) async {
        if MemoryService.isCancellation(error) {
            await finalize(AgentCallProgress(.cancelled, endedAtMS: memory.clock.calendarMS(), durationMS: duration))
        } else {
            await finalize(AgentCallProgress(.failed, result: .error(message: String(describing: error)),
                                             endedAtMS: memory.clock.calendarMS(), durationMS: duration))
        }
    }

    func skip() async {
        await finalize(AgentCallProgress(.skipped, endedAtMS: memory.clock.calendarMS()))
    }

    /// Says what the recorder could not write, and what the brain learned.
    func say(_ report: CallRecorder.Report) {
        for note in report.notes { CLIMemory.say("memory: \(note)") }
        if let learned = report.learned { CLIMemory.say("brain: \(learned)") }
    }

    /// The observation result of a `scene` command, when the sample was recorded; nil otherwise, said.
    func observationResult(from report: CallRecorder.Report) -> AgentCallResult? {
        guard report.samples.contains(.current), let sessionID = context.sessionID, let revision = report.sessionRevision else {
            CLIMemory.say("memory: the observation's result is not recorded: its sample is missing")
            return nil
        }
        return .observation(ObservationResult(
            sessionID: sessionID, sessionRevision: revision, observedAtMS: memory.clock.calendarMS(),
            sample: CaptureSampleKey(eventID: report.eventID, phase: .current)
        ))
    }

    private func finalize(_ progress: AgentCallProgress) async {
        guard isStored else { return }
        let memory = self.memory, eventID = context.eventID
        do {
            _ = try await memory.finalize { try await memory.advance([AgentCallTransition(eventID, progress)]) }
        } catch {
            say("could not record \(request.tool.rawValue) \(progress.status.rawValue)", error)
        }
    }

    private func say(_ what: String, _ error: any Error) {
        CLIMemory.say("memory: \(what): \(MemoryService.describe(error))")
    }
}
