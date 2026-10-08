//
//  CallRecorder.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory

/// CallRecorder writes what one call did, saw and taught into the living memory, under the call's
/// context: the call itself (its request, its start, its end with the result and the effect the
/// engine attributed), the perceptions the engine used as the call's samples (`before`, `menu`,
/// `after`, and `current` for an observation), and the Brain's own learning (an observed scene
/// ingested, an action with an effect recorded), applied once per key by the store.
///
/// It is the engine's `ActionObserving` for the call. Nothing it does can fail or hold up the call:
/// every write goes through `MemoryService.enqueue`, in order, and a write that fails is a gap the
/// service counts. The one wait is an observation's: the scene is ingested before it is enriched
/// from the Brain, as it always was, within `observationBudget`; a busy archive past that budget
/// leaves the enrichment one observation behind, never the call stuck.
///
/// One recorder per call, and one per batch step. A call made outside the tools (a command line
/// action, a session's own observation) gets a recorder of its own from whoever makes the call, so
/// the Brain learns on every path. `current` is the recorder of the call the task is running, set by
/// the producer around the call so a session hands it to the engine without a parameter.
public actor CallRecorder: ActionObserving {

    /// The recorder of the call this task is performing, when a producer set one.
    @TaskLocal public static var current: CallRecorder?

    /// How long an observation waits for its own ingest before it enriches the scene from the Brain.
    public static let observationBudget: Duration = .milliseconds(50)

    nonisolated public let context: ActionContext
    nonisolated public let memory: MemoryService
    private let brain: BrainMemory
    private let requestedAt: Date

    /// The application the call's event names, once the event is written: nil for a call made before
    /// any application (`status`, `windows`, `apps`, `open_session`).
    private var app: AppContextIdentity?
    private var eventWritten = false
    private var startedNS: Int64?
    private var effect: SceneEffect?
    /// The `current` sample of the call's latest observation, once it is offered to the memory.
    public private(set) var lastObservation: CaptureSampleKey?
    /// The observation events this call made for an application its own event does not name.
    private var observationEvents: [String: String] = [:]

    public init(memory: MemoryService, brain: BrainMemory, context: ActionContext) {
        self.memory      = memory
        self.brain       = brain
        self.context     = context
        self.requestedAt = memory.clock.brainNow()
    }

    nonisolated public var eventID: String { context.eventID }

    // MARK: The call

    /// Records the call `planned` and `started`: its event, for `app` when the producer knows it.
    public func begin(_ request: AgentCallRequest, app: AppContextIdentity?) async {
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        let start = AgentCallTransition(context.eventID, .started(atMS: clock.calendarMS()))
        self.app      = app
        eventWritten  = true
        startedNS     = clock.monotonicNS()
        await memory.enqueue("call \(request.tool.rawValue)") { repositories in
            _ = try await repositories.calls.record(try AgentCallRecord(event: event, request: request))
            _ = try await repositories.calls.advance([start])
        }
    }

    /// Records a batch and its steps `planned`, then the batch `started`. Each step's recorder is the
    /// one given with it, whose context is the batch's child at its position.
    public func begin(batch steps: [(recorder: CallRecorder, request: AgentCallRequest)], app: AppContextIdentity?) async {
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        var children: [AgentCallRecord] = []
        for step in steps {
            let child = step.recorder.context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
            if let record = try? AgentCallRecord(event: child, request: step.request) { children.append(record) }
            await step.recorder.planned(app: app)
        }
        let start = AgentCallTransition(context.eventID, .started(atMS: clock.calendarMS()))
        self.app     = app
        eventWritten = true
        startedNS    = clock.monotonicNS()
        let planned  = children
        await memory.enqueue("call batch") { repositories in
            _ = try await repositories.calls.record(batch: try AgentCallRecord(event: event, request: .batch), steps: planned)
            _ = try await repositories.calls.advance([start])
        }
    }

    /// A batch step whose call the batch already recorded as planned: only its start is left.
    private func planned(app: AppContextIdentity?) {
        self.app     = app
        eventWritten = true
    }

    /// Starts a step the batch recorded as planned.
    public func startStep() async {
        let clock = memory.clock
        startedNS = clock.monotonicNS()
        let start = AgentCallTransition(context.eventID, .started(atMS: clock.calendarMS()))
        await memory.enqueue("step start") { repositories in
            _ = try await repositories.calls.advance([start])
        }
    }

    /// Records a planned step that never ran.
    public func skip() async {
        let end = AgentCallTransition(context.eventID, AgentCallProgress(.skipped, endedAtMS: memory.clock.calendarMS()))
        await memory.enqueue("step skipped") { repositories in
            _ = try await repositories.calls.advance([end])
        }
    }

    /// Records the call's end: completed with what its tool answered, or failed with its error. The
    /// effect the engine attributed rides with a completed action or input.
    public func end(_ status: AgentCallStatus, result: AgentCallResult?, tool: AgentTool) async {
        // A call that never began (a batch whose steps could not be read) has nothing to end.
        guard eventWritten else { return }
        let clock    = memory.clock
        let duration = startedNS.map { MemoryClock.durationMS(from: $0, to: clock.monotonicNS()) }
        let observed = status == .completed && tool.isBatchStep ? effect.map(ObservedEffect.init) : nil
        let end      = AgentCallTransition(context.eventID, AgentCallProgress(
            status, result: result, endedAtMS: clock.calendarMS(), durationMS: duration, observedEffect: observed
        ))
        await memory.enqueue("call end") { repositories in
            _ = try await repositories.calls.advance([end])
        }
    }

    // MARK: ActionObserving

    /// An action's record: its perceptions as the `before` and `after` samples, and its learning,
    /// which the Brain takes only from an effect on an element, as it always did.
    public func record(_ record: ActionRecord) async {
        effect = record.effect
        await ensureEvent(app: AppContextIdentity(bundleID: record.bundleID))
        await sample(record.before, as: .before, of: context.eventID)
        await sample(record.after, as: .after, of: context.eventID)
        guard record.effect != nil,
              let command = try? BrainApplicationCommand.record(record, eventID: context.eventID, requestedAt: requestedAt)
        else { return }
        await memory.enqueue("brain record") { repositories in
            _ = try await repositories.applications.apply(command)
        }
    }

    /// An input's record: its perceptions as the `before`, `menu` and `after` samples. An input
    /// teaches the Brain nothing.
    public func record(_ input: InputRecord) async {
        effect = input.effect
        await ensureEvent(app: AppContextIdentity(bundleID: input.bundleID))
        await sample(input.before, as: .before, of: context.eventID)
        await sample(input.menu, as: .menu, of: context.eventID)
        await sample(input.after, as: .after, of: context.eventID)
    }

    // MARK: Observations

    /// An observation: the window as the `current` sample, ingested into the Brain under it, and the
    /// scene enriched from the Brain, which is what the caller shows. When the call's event names no
    /// application, or another one (an `open_session`), the sample belongs to an observation event of
    /// the scene's application whose origin is this call.
    public func observe(_ window: PerceivedWindow) async -> SceneSnapshot {
        let scene    = window.scene
        let identity = AppContextIdentity(bundleID: scene.bundleID)
        let eventID: String
        if eventWritten, app?.bundleID == scene.bundleID {
            eventID = context.eventID
        } else if !eventWritten {
            await ensureEvent(app: identity)
            eventID = context.eventID
        } else {
            eventID = await observationEvent(for: identity)
        }
        let key = CaptureSampleKey(eventID: eventID, phase: .current)
        await sample(window, as: .current, of: eventID)
        lastObservation = key
        if let command = try? BrainApplicationCommand.observe(scene, sample: key, requestedAt: requestedAt) {
            await memory.enqueue("brain observe") { repositories in
                _ = try await repositories.applications.apply(command)
            }
        }
        await memory.flush(within: Self.observationBudget)
        return await brain.enrich(scene)
    }

    /// The scene enriched from the Brain, for a result that carries a scene the call did not observe.
    public func enrich(_ scene: SceneSnapshot) async -> SceneSnapshot {
        await brain.enrich(scene)
    }

    /// A selection's perceptions, as the dropdown selector read them. A selection attributes no scene
    /// effect and teaches the Brain nothing.
    public func record(before: PerceivedWindow?, menu: PerceivedWindow?, after: PerceivedWindow?, bundleID: String) async {
        await ensureEvent(app: AppContextIdentity(bundleID: bundleID))
        await sample(before, as: .before, of: context.eventID)
        await sample(menu, as: .menu, of: context.eventID)
        await sample(after, as: .after, of: context.eventID)
    }

    // MARK: Events and samples

    /// Writes the call's event as an action of `app` when no call recorded it: a command line action,
    /// a session's own observation.
    private func ensureEvent(app: AppContextIdentity) async {
        guard !eventWritten else { return }
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        self.app     = app
        eventWritten = true
        await memory.enqueue("event") { repositories in
            _ = try await repositories.captures.record(event)
        }
    }

    /// The observation event of an application this call's own event does not name, made once.
    private func observationEvent(for app: AppContextIdentity) async -> String {
        if let known = observationEvents[app.bundleID] { return known }
        let derived = context.another(sessionID: context.sessionID)
        let clock   = memory.clock
        let event   = derived.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS(),
                                    kind: .observation)
        observationEvents[app.bundleID] = derived.eventID
        await memory.enqueue("observation event") { repositories in
            _ = try await repositories.captures.record(event)
        }
        return derived.eventID
    }

    /// Writes a perception as the primary sample of `phase` and associates it with the application's
    /// structural scenes; a menu is kept but never associated.
    private func sample(_ window: PerceivedWindow?, as phase: CapturePhase, of eventID: String) async {
        guard let window else { return }
        let key    = CaptureSampleKey(eventID: eventID, phase: phase)
        let sample = CaptureSample(key: key, of: window, sessionRevision: nil)
        let nowMS  = memory.clock.brainMS()
        await memory.enqueue("sample \(phase.rawValue)") { repositories in
            _ = try await repositories.captures.record(sample)
            if phase.isAssociable { _ = try await repositories.scenes.associate(key, at: nowMS) }
        }
    }
}
