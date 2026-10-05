//
//  CallRecorder.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// CallRecorder writes what one call saw and learned into the living memory, under the call's
/// context: the perceptions the engine actually used as the call's samples (`before`, `menu`,
/// `after`, ordinal 0, each with its capture quality, associated with the application's structural
/// scenes), the scene an observation read as its `current` sample, and the brain's own learning
/// through `BrainMemory` (an observed scene ingested, an action with an effect recorded), applied
/// once per key by the store. It is the engine's `ActionObserving` for the call, so a record reaches
/// it after the outcome is decided and nothing it does can fail the action: every write is a
/// finalization (`MemoryService.finalize`): the fact exists, the caller's cancellation does not cut
/// it, a busy archive is waited out like any other write while the call's task is not cancelled,
/// and once the call's owner (`MemoryFinalizationScope`) is stopped every write left shares its one
/// budget from the stop, then is a gap at once, so a stopped call under a lock that never goes waits
/// one budget in all, not one per fact; what could not be written is a note in the report, which the
/// producer shows and keeps as a diagnostic while the tool goes on. The call's task owns these
/// writes: it awaits them.
///
/// One recorder per call: the context names the event every sample and application is keyed by, and
/// `requestedAt`, the Brain's clock read once when the recorder was made, is the instant every
/// application of the call is asked for, so the same facts offered again are the same commands.
/// A batch step is a call of its own, with its own recorder.
public actor CallRecorder: ActionObserving {

    /// Report is what a call left for its record: the effect the engine attributed, which the
    /// producer stores with the call's result, the samples written, what the brain decided, the
    /// session's revision the samples were taken at, and the notes of what could not be written,
    /// each safe to show.
    nonisolated public struct Report: Sendable, Equatable {

        public let eventID: String
        public let effect: SceneEffect?
        public let samples: [CapturePhase]
        /// What the brain decided for this call, when it was asked: the observation's counts, or
        /// what the action's record taught. Nil when nothing reached the brain.
        public let learned: BrainApplicationOutcome?
        public let sessionRevision: Int64?
        public let notes: [String]

        public init(eventID: String, effect: SceneEffect?, samples: [CapturePhase],
                    learned: BrainApplicationOutcome? = nil, sessionRevision: Int64? = nil, notes: [String]) {
            self.eventID         = eventID
            self.effect          = effect
            self.samples         = samples
            self.learned         = learned
            self.sessionRevision = sessionRevision
            self.notes           = notes
        }
    }

    private let memory: MemoryService
    private let brain: BrainMemory
    private let context: ActionContext
    private let sessionRevision: Int64?
    private let requestedAt: Date

    private var effect: SceneEffect?
    private var samples: [CapturePhase] = []
    private var learned: BrainApplicationOutcome?
    private var notes: [String] = []

    /// `sessionRevision` is the session's own count of observations, kept with each sample;
    /// `requestedAt` the Brain's clock for this call's applications (`MemoryClock.brainNow`).
    public init(memory: MemoryService, brain: BrainMemory, context: ActionContext, sessionRevision: Int64? = nil,
                requestedAt: Date) {
        self.memory          = memory
        self.brain           = brain
        self.context         = context
        self.sessionRevision = sessionRevision
        self.requestedAt     = requestedAt
    }

    public var eventID: String { context.eventID }

    // MARK: ActionObserving

    /// An action's record: its perceptions as the `before` and `after` samples, and its learning,
    /// which the brain takes only from an effect on an element, as it always did.
    public func record(_ record: ActionRecord) async {
        effect = record.effect
        await sample(record.before, as: .before)
        await sample(record.after, as: .after)
        guard record.effect != nil, record.element != nil else { return }
        let brain = self.brain, context = self.context, requestedAt = self.requestedAt
        do {
            learned = try await memory.finalize { try await brain.record(record, eventID: context.eventID, requestedAt: requestedAt) }?.outcome
        } catch {
            note("brain record", error)
        }
    }

    /// An input's record: its perceptions as the `before`, `menu` and `after` samples. An input
    /// teaches the brain nothing.
    public func record(_ input: InputRecord) async {
        effect = input.effect
        await sample(input.before, as: .before)
        await sample(input.menu, as: .menu)
        await sample(input.after, as: .after)
    }

    /// A selection's perceptions, as the dropdown selector read them. A selection attributes no
    /// scene effect and teaches the brain nothing.
    public func record(before: PerceivedWindow?, menu: PerceivedWindow?, after: PerceivedWindow?) async {
        await sample(before, as: .before)
        await sample(menu, as: .menu)
        await sample(after, as: .after)
    }

    /// An observation: the window as the `current` sample, ingested into the brain under that sample,
    /// and the scene enriched from the brain, which is what the caller shows. The enrichment never
    /// fails; what could not be written is noted.
    public func observe(_ window: PerceivedWindow) async -> SceneSnapshot {
        let key = CaptureSampleKey(eventID: context.eventID, phase: .current)
        if await sample(window, as: .current) {
            let brain = self.brain, requestedAt = self.requestedAt
            do {
                learned = try await memory.finalize { try await brain.observe(window.scene, sample: key, requestedAt: requestedAt) }.outcome
            } catch {
                note("brain observe", error)
            }
        }
        return await brain.enrich(window.scene)
    }

    /// An observation the session takes on its own, as the first scene after `open_session`: the
    /// context's event is recorded here first, an `observation` of `app` whose origin is the call
    /// that opened the application (`ActionContext.another`), since no call planned it; then the
    /// window is observed as any observation is. The call that opened the application could not name
    /// it when it was planned, and never rewrites its event.
    public func observe(_ window: PerceivedWindow, recordingObservationOf app: AppContextIdentity?) async -> SceneSnapshot {
        let memory = self.memory
        let event  = context.event(app: app, occurredAtMS: memory.clock.calendarMS(), monotonicNS: memory.clock.monotonicNS(),
                                   kind: .observation)
        do {
            _ = try await memory.finalize { try await memory.record(event) }
        } catch {
            note("observation event", error)
            return await brain.enrich(window.scene)
        }
        return await observe(window)
    }

    /// What this call left for its record.
    public func report() -> Report {
        Report(eventID: context.eventID, effect: effect, samples: samples, learned: learned,
               sessionRevision: sessionRevision, notes: notes)
    }

    // MARK: Samples

    /// Writes the window as the primary sample of `phase` and associates it with the application's
    /// scenes (a menu is kept but never associated). True when the sample is stored.
    @discardableResult
    private func sample(_ window: PerceivedWindow?, as phase: CapturePhase) async -> Bool {
        guard let window else { return false }
        let key    = CaptureSampleKey(eventID: context.eventID, phase: phase)
        let memory = self.memory
        let sample = CaptureSample(key: key, of: window, sessionRevision: sessionRevision)
        do {
            _ = try await memory.finalize { try await memory.record(sample) }
            samples.append(phase)
        } catch {
            note("sample \(phase.rawValue)", error)
            return false
        }
        guard phase.isAssociable else { return true }
        do {
            _ = try await memory.finalize { try await memory.associate(key, at: memory.clock.brainMS()) }
        } catch {
            note("scene \(phase.rawValue)", error)
        }
        return true
    }

    private func note(_ what: String, _ error: any Error) {
        notes.append("\(what): \(MemoryService.describe(error))")
    }
}
