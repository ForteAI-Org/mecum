//
//  LivingMemoryStoreTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Synchronization
import Testing

/// Synthetic contexts and proofs shaped like a routing dialog; no real application was observed.
@Suite("The living memory contract and in-memory store")
struct LivingMemoryStoreTests {

    private let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
    private let routing2 = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing 2")!
    private let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mix")!
    private let other = WindowContext(bundleID: "test.synthetic.editor", windowTitle: "Synthetic Routing")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(
        _ context: WindowContext,
        _ identity: SightingIdentity,
        name: String = "All Busses",
        source: LabelSource? = .observed,
        at seconds: TimeInterval = 0,
        block: Int = 1
    ) -> SightingObservation {
        SightingObservation(key: SightingKey(context: context, identity: identity), name: name, nameSource: source,
                            seenAt: t0.addingTimeInterval(seconds), observationBlock: block)
    }

    private func evidence(before: String = "All Busses", _ readback: DropdownReadback = .window("Output Busses"))
        -> DropdownEvidence {
        DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing", control: before,
                         controlRole: "AXPopUpButton", section: nil, valueBefore: before,
                         requestedItem: "Output Busses", readback: readback, menuClosedByChoice: true)
    }

    private var draft: ExperienceDraft {
        ExperienceDraft(phrase: "imposta le uscite su Output Busses",
                        step: ExperienceStep(evidence()), context: routing)!
    }

    private func counter() -> @Sendable () -> ExperienceID {
        let next = Counter()
        return { ExperienceID("experience-\(next.increment())") }
    }

    // MARK: Sightings

    @Test("the same sighting is updated: dates widen, reads count every frame, evidence once per block")
    func sameSightingUpdated() async throws {
        let store = InMemoryLivingMemoryStore()
        let anchor = SightingIdentity.anchor("anchor-1")
        _ = try await store.recordSightings([
            observation(routing, anchor, at: 60, block: 3),
            observation(routing, anchor, at: 0, block: 3),
            observation(routing, anchor, name: "All Buses", at: 120, block: 4),
        ])
        let sightings = try await store.sightings(in: ["test.synthetic.mixer"])
        #expect(sightings.count == 1)
        let sighting = try #require(sightings.first)
        #expect(sighting.readCount == 3)
        #expect(sighting.evidenceCount == 2)
        #expect(sighting.lastCountedBlock == 4)
        #expect(sighting.firstSeen == t0)
        #expect(sighting.lastSeen == t0.addingTimeInterval(120))
        #expect(sighting.name == "All Buses")
    }

    @Test("an assigned name survives an observed one; a later assigned name replaces it")
    func assignedNameKept() async throws {
        let store = InMemoryLivingMemoryStore()
        let anchor = SightingIdentity.anchor("anchor-1")
        _ = try await store.recordSightings([
            observation(routing, anchor, name: "Bus routing", source: .user, block: 1),
            observation(routing, anchor, name: "All Busses", source: .observed, block: 2),
        ])
        #expect(try await store.sightings(in: ["test.synthetic.mixer"]).first?.name == "Bus routing")
        _ = try await store.recordSightings([
            observation(routing, anchor, name: "Output routing", source: .llm, block: 3),
        ])
        #expect(try await store.sightings(in: ["test.synthetic.mixer"]).first?.nameSource == .llm)
    }

    @Test("homonyms are not merged without evidence")
    func homonymsNotMerged() async throws {
        let names = ["Output", "Output", "Input"]
        #expect(SightingIdentity.semantic(kind: .control, name: "Output", amongSceneNames: names) == nil)
        #expect(SightingIdentity.semantic(kind: .control, name: "Input", amongSceneNames: names)
                == .semantic(kind: .control, normalizedName: "input"))
        #expect(SightingIdentity.semantic(kind: .control, name: "•••", amongSceneNames: ["•••"]) == nil)
        let store = InMemoryLivingMemoryStore()
        _ = try await store.recordSightings([
            observation(routing, .anchor("anchor-left"), name: "Output"),
            observation(routing, .anchor("anchor-right"), name: "Output"),
        ])
        #expect(try await store.sightings(in: ["test.synthetic.mixer"]).count == 2)
    }

    @Test("windows and applications stay isolated, and unattributable contexts build nothing")
    func contextsIsolated() async throws {
        #expect(routing == routing2)
        #expect(WindowContext(bundleID: "pid.4242", windowTitle: "Synthetic Routing") == nil)
        #expect(WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "2 — 3") == nil)
        #expect(WindowContext(bundleID: "pid.synthetic", windowTitle: "Synthetic Routing") != nil)
        let store = InMemoryLivingMemoryStore()
        let anchor = SightingIdentity.anchor("anchor-1")
        _ = try await store.recordSightings([observation(routing, anchor), observation(mixer, anchor),
                                             observation(other, anchor)])
        let mixerSightings = try await store.sightings(in: ["test.synthetic.mixer"])
        #expect(mixerSightings.map(\.key.context.windowFamily) == ["syntheticmix", "syntheticrouting"])
        #expect(mixerSightings.allSatisfy { $0.readCount == 1 })
        #expect(try await store.sightings(in: ["test.synthetic.editor"]).count == 1)
        #expect(try await store.sightings(in: ["test.synthetic.mixer", "test.synthetic.editor"]).count == 3)
    }

    @Test("concurrent updates lose nothing and create one experience")
    func concurrentUpdates() async throws {
        let store = InMemoryLivingMemoryStore(makeID: counter())
        let anchor = SightingIdentity.anchor("anchor-1")
        let first = observation(routing, anchor)
        let draft = self.draft
        let proof = evidence()
        let t0 = self.t0
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for index in 0..<25 {
                        _ = try? await store.recordSightings([first])
                        _ = try? await store.record(ExperienceEvent(
                            id: "event-\(writer)-\(index)", subject: .step(draft), outcome: .verified(proof),
                            at: t0.addingTimeInterval(Double(index))
                        ))
                    }
                }
            }
        }
        #expect(try await store.sightings(in: ["test.synthetic.mixer"]).first?.readCount == 200)
        let experiences = try await store.experiences(in: ["test.synthetic.mixer"])
        #expect(experiences.count == 1)
        #expect(experiences.first?.successCount == 200)
    }

    // MARK: Experiences

    @Test("a duplicate event changes nothing, and a reused id with other content is refused")
    func duplicateEvent() async throws {
        let store = InMemoryLivingMemoryStore(makeID: counter())
        let event = ExperienceEvent(id: "event-1", subject: .step(draft), outcome: .verified(evidence()), at: t0)
        let first = try await store.record(event)
        #expect(first == .applied(first.experience))
        let again = try await store.record(event)
        #expect(again == .duplicate(first.experience))
        #expect(again.experience?.successCount == 1)
        let reused = ExperienceEvent(id: "event-1", subject: .step(draft), outcome: .contradicted(.userCorrection),
                                     at: t0)
        await #expect(throws: LivingMemoryError.conflictingEvent(id: "event-1")) { try await store.record(reused) }
        let id = try #require(first.experience?.id)
        #expect(try await store.history(of: id).count == 1)
        #expect(try await store.experiences(in: ["test.synthetic.mixer"]).first?.failureCount == 0)
    }

    @Test("a correction keeps the successes, counts one failure and keeps the history")
    func correctionKeepsSuccesses() async throws {
        let store = InMemoryLivingMemoryStore(makeID: counter())
        _ = try await store.record(ExperienceEvent(id: "e1", subject: .step(draft), outcome: .verified(evidence()),
                                                   at: t0))
        let second = try await store.record(ExperienceEvent(id: "e2", subject: .step(draft),
                                                            outcome: .verified(evidence()), at: t0 + 60))
        let id = try #require(second.experience?.id)
        let corrected = try await store.record(ExperienceEvent(id: "e3", subject: .experience(id),
                                                               outcome: .contradicted(.userCorrection), at: t0 + 120))
        #expect(corrected.experience?.successCount == 2)
        #expect(corrected.experience?.failureCount == 1)
        #expect(corrected.experience?.lastVerifiedAt == t0 + 60)
        #expect(corrected.experience?.lastContradictedAt == t0 + 120)
        #expect(try await store.history(of: id).map(\.event.id) == ["e1", "e2", "e3"])
    }

    @Test("a missing reading is uncertain, a no-op is not a success, another value contradicts")
    func outcomesFromEvidence() async throws {
        let unreadable = evidence(.unreadable(.nothingAtControl))
        #expect(ExperienceEvent.Outcome(unreadable) == .uncertain(.readbackUnavailable(.nothingAtControl)))
        let alreadySet = evidence(before: "Output Busses")
        #expect(ExperienceEvent.Outcome(alreadySet) == .noChange(alreadySet))
        #expect(ExperienceEvent.Outcome(evidence(.window("All Busses")))
                == .contradicted(.readbackShowed("All Busses")))
        #expect(ExperienceEvent.Outcome(evidence()) == .verified(evidence()))

        let store = InMemoryLivingMemoryStore(makeID: counter())
        let learned = try await store.record(ExperienceEvent(id: "e1", subject: .step(draft),
                                                             outcome: .verified(evidence()), at: t0))
        for (index, proof) in [unreadable, alreadySet].enumerated() {
            _ = try await store.record(ExperienceEvent(id: "later-\(index)", subject: .step(draft),
                                                       outcome: ExperienceEvent.Outcome(proof), at: t0 + 60))
        }
        let id = try #require(learned.experience?.id)
        let record = try #require(try await store.experiences(in: ["test.synthetic.mixer"]).first)
        #expect(record.successCount == 1)
        #expect(record.failureCount == 0)
        #expect(try await store.history(of: id).count == 3)
    }

    @Test("only a verified success starts an experience; other outcomes stay unlinked history")
    func onlySuccessCreates() async throws {
        let store = InMemoryLivingMemoryStore(makeID: counter())
        let failed = try await store.record(ExperienceEvent(id: "e1", subject: .step(draft),
                                                            outcome: .contradicted(.readbackShowed("All Busses")),
                                                            at: t0))
        #expect(failed == .applied(nil))
        let unattributed = try await store.record(ExperienceEvent(id: "e2", subject: .unattributed(routing),
                                                                  outcome: .uncertain(.failureNotAttributable), at: t0))
        #expect(unattributed == .applied(nil))
        #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        await #expect(throws: LivingMemoryError.unknownExperience(ExperienceID("missing"))) {
            try await store.record(ExperienceEvent(id: "e3", subject: .experience(ExperienceID("missing")),
                                                   outcome: .contradicted(.userCorrection), at: t0))
        }
    }

    @Test("a step keeps only its semantic arguments, and a phrase without goal content is no draft")
    func stepArguments() {
        let step = ExperienceStep(evidence())
        #expect(step.arguments == ["control": "All Busses", "item": "Output Busses"])
        #expect(step.terms == ["all", "busses", "output"])
        #expect(ExperienceDraft(phrase: "vai su", step: step, context: routing) == nil)
    }

    @Test("candidates share a goal token with the phrase or the step, within the named applications")
    func candidates() async throws {
        let store = InMemoryLivingMemoryStore(makeID: counter())
        _ = try await store.record(ExperienceEvent(id: "e1", subject: .step(draft), outcome: .verified(evidence()),
                                                   at: t0))
        #expect(try await store.candidates(for: "metti Output Busses", in: nil).count == 1)
        #expect(try await store.candidates(for: "uscite", in: ["test.synthetic.mixer"]).count == 1)
        #expect(try await store.candidates(for: "uscite", in: ["test.synthetic.editor"]).isEmpty)
        #expect(try await store.candidates(for: "apri il browser", in: nil).isEmpty)
    }

    @Test("recall decisions keep their reason, once per id")
    func decisions() async throws {
        let store = InMemoryLivingMemoryStore()
        let id = ExperienceID("experience-1")
        let decision = RecallDecisionRecord(id: "d1", at: t0, phrase: "imposta le uscite", context: routing,
                                            experienceID: id, verdict: .refused,
                                            reason: "the control was not in the fresh scene")
        try await store.record(decision)
        try await store.record(decision)
        #expect(try await store.decisions(about: id) == [decision])
        let changed = RecallDecisionRecord(id: "d1", at: t0, phrase: "imposta le uscite", context: routing,
                                           experienceID: id, verdict: .suggested, reason: "")
        await #expect(throws: LivingMemoryError.conflictingDecision(id: "d1")) { try await store.record(changed) }
    }
}

/// Counter hands out increasing numbers across tasks for deterministic experience ids.
private final class Counter: Sendable {
    private let state = Mutex(0)

    func increment() -> Int {
        state.withLock { value in
            value += 1
            return value
        }
    }
}
