//
//  RecallSuggestionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The two demo requests against a synthetic record learned in a routing window.
@Suite("Contextual recall of verified experiences")
struct RecallSuggestionTests {

    private let learning = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recalling = "Seleziona Output Busses nel filtro della scheda Bus in Pro Tools. Prima dimmi se hai "
        + "un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."
    private let bundle = "test.synthetic.mixer"
    private let verifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var routing: WindowContext { WindowContext(bundleID: bundle, windowTitle: "Synthetic Routing")! }

    private func record(_ id: String = "experience-1", successes: Int = 1, failures: Int = 0,
                        bundle: String? = nil) -> ExperienceRecord {
        let context = WindowContext(bundleID: bundle ?? self.bundle, windowTitle: "Synthetic Routing")!
        let draft = ExperienceDraft(phrase: learning,
                                    step: ExperienceStep(tool: .select, control: "All Busses", item: "Output Busses"),
                                    context: context)!
        return ExperienceRecord(id: ExperienceID(id), draft: draft, createdAt: verifiedAt, successCount: successes,
                                failureCount: failures, lastVerifiedAt: verifiedAt)
    }

    private func scene(title: String = "Synthetic Routing", labels: [String], coverage: SceneCoverage = .window)
        -> SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: bundle, appName: "Synthetic Mixer", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: labels.enumerated().map { index, label in
                SceneElement(id: "control|\(label)|\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.2 + Double(index) * 0.1,
                                                    width: 0.15, height: 0.05))
            }
        )
        scene.coverage = coverage
        return scene
    }

    private func world(_ records: [ExperienceRecord], context: Recall.Context = Recall.Context(),
                       sightings: [Sighting] = []) -> Recall.World {
        Recall.World(records: records, sightings: sightings, context: context)
    }

    @Test("both demo requests find the verified experience, by its phrase and by its step")
    func demoRequests() {
        guard case .suggest(let exact, _) = Recall.suggest(input: learning, in: world([record()])) else {
            Issue.record("the learning phrase was not recalled"); return
        }
        #expect(exact.match == .exactPhrase)
        guard case .suggest(let step, _) = Recall.suggest(input: recalling, in: world([record()])) else {
            Issue.record("the recall phrase was not recalled"); return
        }
        #expect(step.match == .sameStep)
        #expect(step.record.phrase == learning)
        // The phrase coverage alone does not reach the second request, which is why the step's own terms matter.
        #expect(MemoryHint.hint(input: recalling, from: [record().recallExperience]) == nil)
    }

    @Test("an exact match with no fresh scene is a suggestion to observe first, not presence")
    func exactWithoutPresence() {
        guard case .suggest(let suggestion, _) = Recall.suggest(input: learning, in: world([record()])) else {
            Issue.record("no suggestion"); return
        }
        #expect(suggestion.presence == .notObserved)
        #expect(suggestion.isOperational)
        let present = world([record()], context: Recall.Context(freshScene: scene(labels: ["All Busses", "Input"])))
        guard case .suggest(let seen, _) = Recall.suggest(input: learning, in: present) else {
            Issue.record("no suggestion with the control present"); return
        }
        #expect(seen.presence == .presentNow)
    }

    @Test("another application refuses, another window is history only")
    func otherContexts() {
        let elsewhere = world([record()], context: Recall.Context(bundleID: "test.synthetic.editor"))
        guard case .abstain(let refused?, _) = Recall.suggest(input: learning, in: elsewhere) else {
            Issue.record("a memory moved between applications"); return
        }
        #expect(refused.refusal == .otherApplication(learnedIn: bundle, current: "test.synthetic.editor"))
        let otherWindow = world([record()], context: Recall.Context(freshScene: scene(title: "Synthetic Mix",
                                                                                         labels: ["All Busses"])))
        guard case .historical(_, .otherWindow(let learned, let current), _) = Recall.suggest(input: learning,
                                                                                             in: otherWindow) else {
            Issue.record("another window was operational"); return
        }
        #expect(learned == "syntheticrouting")
        #expect(current == "syntheticmix")
    }

    @Test("an absent, ambiguous or unattributable target is history only, and never a contradiction")
    func targetNotUsableNow() {
        let withoutControl = Recall.Context(freshScene: scene(labels: ["Input"]))
        let absent = Recall.suggest(input: learning, in: world([record()], context: withoutControl))
        #expect(absent == .historical(Recall.Suggestion(record: record(), match: .exactPhrase, presence: .absentNow,
                                                        sightingEvidence: 0),
                                      .notOperationalNow(.absentNow), considered: absent.considered))
        let decision = absent.decisionRecord(id: "d1", at: verifiedAt, phrase: learning, context: routing)
        #expect(decision.verdict == .refused)
        #expect(decision.experienceID == ExperienceID("experience-1"))
        let twice = Recall.Context(freshScene: scene(labels: ["All Busses", "All Busses"]))
        guard case .historical(_, .notOperationalNow(.ambiguousNow), _) = Recall.suggest(input: learning,
                                                                                         in: world([record()],
                                                                                                   context: twice))
        else { Issue.record("an ambiguous control was operational"); return }
        let popups = Recall.Context(freshScene: scene(labels: ["All Busses"], coverage: .windowAndPopups))
        guard case .historical(_, .notOperationalNow(.unattributable), _) = Recall.suggest(input: learning,
                                                                                           in: world([record()],
                                                                                                     context: popups))
        else { Issue.record("a pop-up scene was trusted"); return }
    }

    @Test("an unreliable memory is refused with its counts and never comes back as a hint or a replay")
    func unreliable() {
        let weak = record(successes: 1, failures: 2)
        guard case .abstain(let refused?, let considered) = Recall.suggest(input: learning, in: world([weak])) else {
            Issue.record("an unreliable memory was offered"); return
        }
        #expect(refused.refusal == .notReliable(successes: 1, failures: 2))
        #expect(considered.first?.verdict.contains("notReliable") == true)
        #expect(MemoryHint.hint(input: learning, from: [weak.recallExperience]) == nil)
        #expect(Recall.decide(input: learning, in: Recall.World(memories: [weak.recallExperience]))
                == .abstain(Recall.Abstention(reason: "nothing remembered matches \"\(learning)\"", refused: nil)))
    }

    @Test("a suggestion cites its record, its verification and its sightings; a compound request finds nothing")
    func provenance() {
        let sighting = Sighting(key: SightingKey(context: routing, identity: .anchor("anchor-1")), name: "All Busses",
                                nameSource: .observed, firstSeen: verifiedAt, lastSeen: verifiedAt, readCount: 5,
                                evidenceCount: 2, lastCountedBlock: 3)
        let answer = Recall.suggest(input: recalling, in: world([record()], sightings: [sighting]))
        guard case .suggest(let suggestion, let considered) = answer else { Issue.record("no suggestion"); return }
        #expect(suggestion.record.id == ExperienceID("experience-1"))
        #expect(suggestion.record.lastVerifiedAt == verifiedAt)
        #expect(suggestion.record.successCount == 1)
        #expect(suggestion.sightingEvidence == 2)
        #expect(considered.map(\.verdict) == ["suggested, notObserved"])
        #expect(answer.decisionRecord(id: "d1", at: verifiedAt, phrase: recalling, context: nil).verdict == .suggested)
        #expect(record().recallExperience.source == ExperienceID("experience-1"))
        let compound = Recall.suggest(input: "Seleziona Output Busses e poi esporta la sessione", in: world([record()]))
        #expect(compound == .abstain(nil, considered: [
            Recall.Consideration(experienceID: ExperienceID("experience-1"), match: nil, verdict: "no match"),
        ]))
        #expect(compound.decisionRecord(id: "d2", at: verifiedAt, phrase: "x", context: nil).verdict == .abstained)
    }
}
