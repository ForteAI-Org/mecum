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
/// context and, when the agent declared one, its task attempt.
///
/// The facts of the call are essential and confirmed (`MemoryService.confirm`): its start, with the
/// arguments as admitted and the task attribution, is committed before the call may act, and `begin`
/// throws when it is not, so the producer does not act; its end, written after the effect in one
/// transaction with the samples the engine perceived, the effect the call really had and the
/// verification the engine's oracle made (`OperationCheck`), suspends the memory when it cannot be
/// saved, and `end` throws then, so the producer reports it and acts no more. An observation's
/// sample is confirmed when it is taken, since the Brain learns from it before the scene is
/// enriched. What can be rebuilt from these facts (the scene associations, the Brain's learning) is
/// enqueued, never awaited.
///
/// Values the call may not keep are withheld before anything is written (`ValueMinimization`): from
/// its arguments, its result's message, its samples' labels and titles, its verification's texts and
/// what the Brain learns, with the gap declared. The texts withheld from the arguments are kept in
/// this recorder's memory only, to withhold them wherever else they appear (`withheldTexts`).
///
/// One recorder per call, and one per batch step. A call made outside the tools (a session's own
/// observation, the command line's `scene`) gets a recorder of its own and no call row: its event and
/// samples are written when they arrive. `current` is the recorder of the call the task is running,
/// set by the producer around the call so a session hands it to the engine without a parameter.
public actor CallRecorder: ActionObserving {

    /// The recorder of the call this task is performing, when a producer set one.
    @TaskLocal public static var current: CallRecorder?

    /// How long an observation waits for its own ingest before it enriches the scene from the Brain.
    public static let observationBudget: Duration = .milliseconds(50)

    nonisolated public let context: ActionContext
    nonisolated public let memory: MemoryService
    private let brain: BrainMemory
    private let requestedAt: Date
    private var minimization: ValueMinimization

    /// The application the call's event names, once the event is written: nil for a call made before
    /// any application (`status`, `windows`, `apps`, `open_session`).
    private var app: AppContextIdentity?
    private var eventWritten = false
    /// The call's row exists (begun, or planned with its batch): its samples wait for its end.
    private var callRecorded = false
    private var tool: AgentTool?
    private var attribution: TaskCallAttribution?
    private var startedNS: Int64?
    /// The effect the engine attributed, minimized, and why something of it was withheld.
    private var effect: SceneEffect?
    private var effectWithheld: WithholdingReason?
    private var attempt: ActionAttempt?
    private var target: OperationCheck.Target?
    /// The call's own samples, written with its end.
    private var samples: [CaptureSample] = []
    /// Samples of the call already in the archive (an observation's), which its verification may name.
    private var storedSamples: [CaptureSampleKey] = []
    /// Gaps found in what waits for the end.
    private var gaps: [ValueRedaction] = []
    /// The texts withheld from this call's arguments, in memory only.
    public private(set) var withheldTexts: [String] = []
    /// What of the call's facts could not be saved, each said once, in order: shown to the agent as the
    /// record's gap after the call's end, which may add one.
    private var recordingGaps: [String] = []
    public var recordingGap: String? { recordingGaps.isEmpty ? nil : recordingGaps.joined(separator: "; ") }
    /// The `current` sample of the call's latest observation, once it is in the archive.
    public private(set) var lastObservation: CaptureSampleKey?
    /// The observation events this call made for an application its own event does not name.
    private var observationEvents: [String: String] = [:]

    public init(memory: MemoryService, brain: BrainMemory, context: ActionContext,
                minimization: ValueMinimization = ValueMinimization()) {
        self.memory       = memory
        self.brain        = brain
        self.context      = context
        self.minimization = minimization
        self.requestedAt  = memory.clock.brainNow()
    }

    nonisolated public var eventID: String { context.eventID }

    // MARK: The call

    /// Confirms the call planned and started, with its arguments as admitted, its task attribution and
    /// the gaps of what was withheld from them, before the call acts. Throws `EssentialWriteFailure`
    /// when the archive did not confirm it: the call must not act then. A request the contract cannot
    /// represent is `refused` the same way, so nothing acts unrecorded.
    public func begin(
        _ request  : AgentCallRequest,
        app        : AppContextIdentity?,
        attribution: TaskCallAttribution? = nil
    ) async throws {
        let clock = memory.clock
        let (admitted, redactions) = admit(request)
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        let opening: OperationOpening
        do {
            opening = try OperationOpening(
                call       : try AgentCallRecord(event: event, request: admitted),
                startedAtMS: clock.calendarMS(),
                attribution: attribution,
                redactions : redactions
            )
        } catch {
            throw EssentialWriteFailure.refused(MemoryService.describe(error))
        }
        try await memory.confirm(
            "call \(request.tool.rawValue) start",
            beforeEffect: request.tool.requiresConfirmedStart
        ) {
            _ = try await $0.facts.open(opening)
        }
        self.app          = app
        self.tool         = request.tool
        self.attribution  = attribution
        eventWritten      = true
        callRecorded      = true
        startedNS         = clock.monotonicNS()
    }

    /// Confirms a batch started and its steps planned, before its first step. Each step's recorder is
    /// the one given with it, whose context is the batch's child at its position.
    public func begin(batch steps: [(recorder: CallRecorder, request: AgentCallRequest)], app: AppContextIdentity?,
                      attribution: TaskCallAttribution? = nil) async throws {
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        var children: [AgentCallRecord] = []
        var redactions: [ValueRedaction] = []
        let opening: BatchOpening
        do {
            for step in steps {
                let child = step.recorder.context.event(
                    app         : app,
                    occurredAtMS: clock.calendarMS(),
                    monotonicNS : clock.monotonicNS()
                )
                let (admitted, gaps) = await step.recorder.admit(step.request)
                children.append(try AgentCallRecord(event: child, request: admitted))
                redactions += gaps
            }
            opening = try BatchOpening(
                batch      : try AgentCallRecord(event: event, request: .batch),
                steps      : children,
                startedAtMS: clock.calendarMS(),
                attribution: attribution,
                redactions : redactions
            )
        } catch {
            throw EssentialWriteFailure.refused(MemoryService.describe(error))
        }
        try await memory.confirm("call batch start", beforeEffect: true) { _ = try await $0.facts.open(batch: opening) }
        for (step, request) in zip(steps.map(\.recorder), steps.map(\.request)) {
            await step.planned(app: app, tool: request.tool, attribution: attribution)
        }
        self.app         = app
        self.tool        = .batch
        self.attribution = attribution
        eventWritten     = true
        callRecorded     = true
        startedNS        = clock.monotonicNS()
    }

    /// A batch step whose call the batch already recorded as planned: only its start is left.
    private func planned(app: AppContextIdentity?, tool: AgentTool, attribution: TaskCallAttribution?) {
        self.app         = app
        self.tool        = tool
        self.attribution = attribution
        eventWritten     = true
        callRecorded     = true
    }

    /// Confirms a planned step started, before it acts; throws when the archive did not confirm it.
    public func startStep() async throws {
        let clock = memory.clock
        let at    = clock.calendarMS()
        let eventID = context.eventID, attribution = self.attribution
        try await memory.confirm("step start", beforeEffect: true) {
            _ = try await $0.facts.start(step: eventID, atMS: at, attribution: attribution)
        }
        startedNS = clock.monotonicNS()
    }

    /// Records a planned step that never ran, after an earlier step's effect: suspends the memory and
    /// throws when it cannot be saved.
    public func skip() async throws {
        let end = AgentCallTransition(context.eventID, AgentCallProgress(.skipped, endedAtMS: memory.clock.calendarMS()))
        let conclusion = try OperationConclusion(end: end)
        try await memory.confirm("step skipped", afterEffect: true) { _ = try await $0.facts.conclude(conclusion) }
    }

    /// Writes the call's end in one transaction: completed with what its tool answered, or failed with
    /// its error, or cancelled; the samples it perceived; for an operation, what it really did and the
    /// check its oracle made. After a call that may have acted, a failure suspends the memory and
    /// throws: the caller reports it and acts no more until it is saved. A call never begun writes
    /// nothing.
    public func end(
        _ status: AgentCallStatus,
        result  : AgentCallResult?,
        tool    : AgentTool,
        check   : OperationCheck? = nil
    ) async throws {
        guard callRecorded else { return }
        let clock    = memory.clock
        let duration = startedNS.map { MemoryClock.durationMS(from: $0, to: clock.monotonicNS()) }
        let observed = status == .completed && tool.isBatchStep ? effect.map(ObservedEffect.init) : nil
        let (kept, resultGap) = admit(result)
        let end = AgentCallTransition(context.eventID, AgentCallProgress(
            status, result: kept, endedAtMS: clock.calendarMS(), durationMS: duration, observedEffect: observed
        ))
        var redactions = gaps + resultGap
        if let effectWithheld, observed != nil {
            redactions.append(ValueRedaction(
                eventID : context.eventID,
                location: .observedEffect,
                reason  : effectWithheld
            ))
        }
        var operationEffect: OperationEffect?
        if tool.isOperation {
            let (fact, targetGaps) = try effectFact(check: check, result: result)
            operationEffect = fact
            redactions += targetGaps
        }
        var verifications: [OperationVerification] = []
        if tool.isOperation, let check {
            let (admittedCheck, checkGaps) = admit(check)
            redactions += checkGaps
            let sampleKeys = storedSamples + samples.map(\.key)
            let event = context.verificationEvent(
                eventID: OperationVerification.eventID(call: context.eventID, condition: check.condition), app: app,
                occurredAtMS: clock.calendarMS()
            )
            verifications.append(try OperationVerification(
                event      : event,
                callEventID: context.eventID,
                check      : admittedCheck,
                samples    : sampleKeys
            ))
        }
        let conclusion = try OperationConclusion(end: end, samples: samples, effect: operationEffect,
                                                 verifications: verifications, redactions: redactions)
        // The least the end is saved as when the archive refuses the whole: its state and result, with
        // the parts it leaves out declared durably in the same transaction, and why.
        var omitted: [OperationRecordingGap.Part] = []
        if !samples.isEmpty { omitted.append(.samples) }
        if operationEffect != nil { omitted.append(.effect) }
        if !verifications.isEmpty { omitted.append(.verification) }
        let callID = context.eventID, minimization = self.minimization, omittedParts = omitted
        let least: @Sendable (MemoryRepositories, EssentialWriteFailure) async throws -> Void = {
            repositories, refusal in
            let reason: OperationRecordingGap.Reason = switch refusal {
                case .conflict: .conflict
                default       : .refused
            }
            let detail  = minimization.minimize(text: refusal.description).0
            let unsaved = try omittedParts.map {
                try OperationRecordingGap(callEventID: callID, part: $0, reason: reason, detail: detail)
            }
            _ = try await repositories.facts.conclude(
                try OperationConclusion(end: end, redactions: resultGap, unsaved: unsaved)
            )
        }
        let saved = try await memory.confirm(
            "call \(tool.rawValue) end",
            afterEffect: tool.requiresConfirmedStart,
            fallback   : least
        ) {
            _ = try await $0.facts.conclude(conclusion)
        }
        if case .least(let refusal) = saved {
            let parts = omitted.map(\.rawValue)
            let what  = parts.isEmpty ? "the gaps it declared" : "its " + parts.joined(separator: ", ")
            recordingGaps.append("the call's end was saved without \(what), which the archive refused "
                + "(\(minimization.minimize(text: refusal.description).0)); the call is kept as incomplete evidence")
            samples = []
        }
        await associate(samples.map(\.key))
        samples = []
        gaps    = []
    }

    // MARK: ActionObserving

    /// An action's record: its perceptions as the `before` and `after` samples, written with the call's
    /// end, and its learning, which the Brain takes only from an effect on an element, as it always did.
    public func record(_ record: ActionRecord) async {
        keep(effect: record.effect)
        attempt = record.attempt
        target  = OperationCheck.Target(record.element)
        await keep([(record.before, .before), (record.after, .after)], bundleID: record.bundleID)
        // An effect with a withheld value teaches nothing: its transition would predict the marker.
        guard eventWritten, record.effect != nil, effectWithheld == nil,
              let command = try? BrainApplicationCommand.record(
                  admit(record),
                  eventID    : context.eventID,
                  requestedAt: requestedAt
              )
        else { return }
        await memory.enqueue("brain record") { repositories in
            _ = try await repositories.applications.apply(command)
        }
    }

    /// An input's record: its perceptions as the `before`, `menu` and `after` samples, written with the
    /// call's end. An input teaches the Brain nothing.
    public func record(_ input: InputRecord) async {
        keep(effect: input.effect)
        attempt = input.attempt
        target  = input.target.map(OperationCheck.Target.init)
        await keep([(input.before, .before), (input.menu, .menu), (input.after, .after)], bundleID: input.bundleID)
    }

    /// Keeps the effect the engine attributed with its titles and labels minimized.
    private func keep(effect observed: SceneEffect?) {
        guard let observed else {
            effect = nil
            return
        }
        let (kept, reason) = minimization.minimize(effect: observed)
        effect         = kept
        effectWithheld = reason
    }

    // MARK: Observations

    /// An observation: the window as the `current` sample, confirmed now, ingested into the Brain under
    /// it, and the scene enriched from the Brain, which is what the caller shows. When the call's event
    /// names no application, or another one (an `open_session`), the sample belongs to an observation
    /// event of the scene's application whose origin is this call. A sample the archive did not
    /// confirm leaves `lastObservation` nil, the record's gap; after an effect it suspends the memory.
    public func observe(_ window: PerceivedWindow) async -> SceneSnapshot {
        let scene    = window.scene
        let identity = AppContextIdentity(bundleID: scene.bundleID)
        let eventID: String?
        if eventWritten, app?.bundleID == scene.bundleID {
            eventID = context.eventID
        } else if !eventWritten {
            eventID = await ensureEvent(app: identity) ? context.eventID : nil
        } else {
            eventID = await observationEvent(for: identity)
        }
        guard let eventID else { return await brain.enrich(scene) }
        let key = CaptureSampleKey(eventID: eventID, phase: .current)
        let (sample, sampleGaps) = minimization.minimize(
            sample: CaptureSample(key: key, of: window, sessionRevision: nil)
        )
        guard (try? sample.validate()) != nil else {
            recordingGaps.append("the observation's sample was refused by the contract and not kept")
            lastObservation = nil
            return await brain.enrich(scene)
        }
        do {
            try await memory.confirm("sample current", afterEffect: tool?.requiresConfirmedStart == true) {
                _ = try await $0.facts.record(samples: [sample], redactions: sampleGaps)
            }
        } catch {
            recordingGaps.append("the observation was not saved: \(error)")
            lastObservation = nil
            return await brain.enrich(scene)
        }
        lastObservation = key
        storedSamples.append(key)
        await associate([key])
        if let command = try? BrainApplicationCommand.observe(
            minimization.minimize(scene: scene),
            sample     : key,
            requestedAt: requestedAt
        ) {
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

    /// A selection's or a contextual menu's perceptions, as its selector read them, written with the
    /// call's end. A selection attributes no scene effect and teaches the Brain nothing.
    public func record(before: PerceivedWindow?, menu: PerceivedWindow?, after: PerceivedWindow?, bundleID: String,
                       target: SceneElement? = nil) async {
        if let target { self.target = OperationCheck.Target(target) }
        await keep([(before, .before), (menu, .menu), (after, .after)], bundleID: bundleID)
    }

    // MARK: Events and samples

    /// Keeps perceptions as the call's samples: with the call's end when the call is recorded, or at
    /// once under an event of its own for a call made outside the tools.
    private func keep(_ windows: [(PerceivedWindow?, CapturePhase)], bundleID: String) async {
        var kept: [CaptureSample] = []
        var keptGaps: [ValueRedaction] = []
        let eventID: String
        if callRecorded {
            eventID = context.eventID
        } else {
            guard await ensureEvent(app: AppContextIdentity(bundleID: bundleID)) else { return }
            eventID = context.eventID
        }
        for case let (window?, phase) in windows {
            let key = CaptureSampleKey(eventID: eventID, phase: phase)
            guard !samples.contains(where: { $0.key == key }), !storedSamples.contains(key) else { continue }
            let (sample, sampleGaps) = minimization.minimize(
                sample: CaptureSample(key: key, of: window, sessionRevision: nil)
            )
            // A sample the contract refuses is left out, said as a gap: it never holds up the call's end.
            guard (try? sample.validate()) != nil else {
                recordingGaps.append("a \(phase.rawValue) sample the contract refuses was not kept")
                continue
            }
            kept.append(sample)
            keptGaps += sampleGaps
        }
        if callRecorded {
            samples += kept
            gaps    += keptGaps
            return
        }
        let written = kept, writtenGaps = keptGaps
        do {
            try await memory.confirm("samples", afterEffect: true) {
                _ = try await $0.facts.record(samples: written, redactions: writtenGaps)
            }
            storedSamples += written.map(\.key)
            await associate(written.map(\.key))
        } catch {
            recordingGaps.append("the samples were not saved: \(error)")
        }
    }

    /// Writes the call's event as an action of `app` when no call recorded it: a session's own
    /// observation, the command line's `scene`. False when the archive did not confirm it.
    private func ensureEvent(app: AppContextIdentity) async -> Bool {
        guard !eventWritten else { return true }
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        do {
            try await memory.confirm("event") { _ = try await $0.captures.record(event) }
        } catch {
            recordingGaps.append("the event was not saved: \(error)")
            return false
        }
        self.app     = app
        eventWritten = true
        return true
    }

    /// The observation event of an application this call's own event does not name, made once.
    private func observationEvent(for app: AppContextIdentity) async -> String? {
        if let known = observationEvents[app.bundleID] { return known }
        let derived = context.another(sessionID: context.sessionID)
        let clock   = memory.clock
        let event   = derived.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS(),
                                    kind: .observation)
        do {
            try await memory.confirm("observation event", afterEffect: tool?.requiresConfirmedStart == true) {
                _ = try await $0.captures.record(event)
            }
        } catch {
            recordingGaps.append("the observation event was not saved: \(error)")
            return nil
        }
        observationEvents[app.bundleID] = derived.eventID
        return derived.eventID
    }

    /// Offers the scene associations of samples now in the archive; a menu is kept but never associated.
    private func associate(_ keys: [CaptureSampleKey]) async {
        let nowMS = memory.clock.brainMS()
        for key in keys where key.phase.isAssociable {
            await memory.enqueue("scene \(key.phase.rawValue)") { _ = try await $0.scenes.associate(key, at: nowMS) }
        }
    }

    // MARK: Admission

    /// The request with what may not be kept withheld, and the gaps; the withheld texts are kept in
    /// memory to withhold them wherever else they appear in this call.
    func admit(_ request: AgentCallRequest) -> (AgentCallRequest, [ValueRedaction]) {
        let (admitted, redactions) = minimization.minimize(request, eventID: context.eventID)
        guard !redactions.isEmpty else { return (admitted, []) }
        var original: [String: String] = [:]
        for argument in request.arguments {
            if case .text(let text) = argument.value { original["\(argument.name)#\(argument.position)"] = text }
        }
        for redaction in redactions {
            guard case .argument(let name, let position) = redaction.location,
                  let text = original["\(name)#\(position)"],
                  text != ValueMinimization.marker else { continue }
            // A withheld text is searched for whole elsewhere, never by the parts a rule matched in it.
            if !withheldTexts.contains(text) { withheldTexts.append(text) }
        }
        minimization = minimization.adding(secrets: withheldTexts)
        return (admitted, redactions)
    }

    private func admit(_ result: AgentCallResult?) -> (AgentCallResult?, [ValueRedaction]) {
        minimization.minimize(result: result, eventID: context.eventID)
    }

    private func admit(_ check: OperationCheck) -> (OperationCheck, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        func scrub(_ text: String?, _ location: ValueRedaction.Location) -> String? {
            guard let text else { return nil }
            let (_, reason) = minimization.minimize(text: text)
            guard let reason else { return text }
            gaps.append(ValueRedaction(eventID: context.eventID, location: location, reason: reason))
            return nil
        }
        let expected = scrub(check.expected, .verificationExpected(check.condition))
        let observed = scrub(check.observed, .verificationObserved(check.condition))
        var target   = check.target
        if let current = target {
            let (kept, targetGaps) = minimization.minimize(target: current, eventID: context.eventID)
            target = kept
            gaps  += targetGaps
        }
        // The effect the check judged had a value withheld: its evidence is kept in part.
        if let effectWithheld, effect != nil {
            gaps.append(ValueRedaction(eventID: context.eventID, location: .observedEffect, reason: effectWithheld))
        }
        let limits = gaps.isEmpty || check.limits.contains(.valueWithheld)
            ? check.limits
            : check.limits + [.valueWithheld]
        return (OperationCheck(condition: check.condition, method: check.method, methodVersion: check.methodVersion,
                               verdict: check.verdict, expected: expected, observed: observed, limits: limits,
                               performed: check.performed, substitute: check.substitute, target: target), gaps)
    }

    /// The record with its element's texts and identity minimized and the effect kept, for what the
    /// Brain learns; called only for an effect nothing was withheld from.
    private func admit(_ record: ActionRecord) -> ActionRecord {
        let element = minimization.minimize(element: record.element).0
        return ActionRecord(bundleID: record.bundleID, element: element, verb: record.verb, effect: effect,
                            windowTitleAfter: record.windowTitleAfter.map { minimization.minimize(text: $0).0 },
                            before: nil, after: nil, attempt: record.attempt)
    }

    /// What an operation really did: the check's account when its path reported one, else what the
    /// engine's record says of the gesture, else unknown; and the target, minimized.
    private func effectFact(
        check : OperationCheck?,
        result: AgentCallResult?
    ) throws -> (OperationEffect, [ValueRedaction]) {
        var performed: OperationCheck.Performed
        var reason: String?
        switch (check?.performed, attempt) {
            case (let stated?, _)              : performed = stated
            case (nil, .delivered?)            : performed = .requested
            case (nil, .notAttempted(let why)?): performed = .none; reason = why
            case (nil, .deliveryFailed?)       : performed = .uncertain
            case (nil, nil)                    : performed = .uncertain
        }
        if performed == .none, reason == nil {
            if case .notAttempted(let why)? = attempt { reason = why }
            else if case .outcome(let kind, _)? = result { reason = kind.rawValue }
        }
        if performed != .none { reason = nil }
        var fact = check?.target ?? target
        var gaps: [ValueRedaction] = []
        if let current = fact {
            let (kept, targetGaps) = minimization.minimize(target: current, eventID: context.eventID)
            fact = kept
            gaps = targetGaps
        }
        let effect = try OperationEffect(callEventID: context.eventID, performed: performed,
                                         substitute: performed == .substitute ? (check?.substitute ?? "unknown") : nil,
                                         notSentReason: reason, target: fact, checked: check != nil)
        return (effect, gaps)
    }
}

extension ActionContext {

    /// The event of a verification of this context's call: its own identity, the call's producer,
    /// trace and session, no parent.
    nonisolated func verificationEvent(
        eventID     : String,
        app         : AppContextIdentity?,
        occurredAtMS: Int64
    ) -> MemoryEventRecord {
        MemoryEventRecord(eventID: eventID, source: source, streamID: streamID, traceID: traceID, sessionID: sessionID,
                          kind: .verification, app: app, occurredAtMS: occurredAtMS)
    }
}
