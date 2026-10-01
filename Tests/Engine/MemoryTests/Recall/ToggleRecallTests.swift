//
//  ToggleRecallTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// A synthetic toggle experience learned in a mixer window, recalled for other requests.
@Suite("Contextual recall of a verified toggle")
struct ToggleRecallTests {

    private let bundle = "test.synthetic.mixer"
    private let verifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ state: ControlState = .on, phrase: String = "Attiva Mute") -> ExperienceRecord {
        let context = WindowContext(bundleID: bundle, windowTitle: "Synthetic Mixer")!
        let draft = ExperienceDraft(phrase: phrase, step: .setToggle(control: "Mute", section: nil, state: state),
                                    context: context)!
        let proof = ToggleEvidence(bundleID: bundle, windowTitle: "Synthetic Mixer", control: "Mute", controlRole: nil,
                                   section: nil, desiredState: state, stateBefore: .read(state.toggled, .resolvedElement),
                                   click: .sent, stateAfter: .read(state, .sameElement))
        return ExperienceRecord(id: ExperienceID("toggle-\(state.rawValue)"), draft: draft, createdAt: verifiedAt,
                                successCount: 1, latestProof: .toggle(proof), lastVerifiedAt: verifiedAt)
    }

    private func scene(_ elements: [SceneElement], title: String = "Synthetic Mixer") -> SceneSnapshot {
        var scene = SceneSnapshot(bundleID: bundle, appName: "Synthetic Mixer", windowTitle: title,
                                  viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: elements)
        scene.coverage = .window
        return scene
    }

    private func mute(_ state: ControlState?, id: String = "control|mute") -> SceneElement {
        SceneElement(id: id, kind: .control, label: "Mute",
                     bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05), state: state)
    }

    private func suggest(_ input: String, _ records: [ExperienceRecord], context: Recall.Context = Recall.Context())
        -> Recall.SuggestionAnswer {
        Recall.suggest(input: input, in: Recall.World(records: records, sightings: [], context: context))
    }

    @Test("a request for the remembered state finds the toggle, however it is phrased")
    func sameState() {
        guard case .suggest(let exact, _) = suggest("Attiva Mute", [record()]) else {
            Issue.record("the learning phrase was not recalled"); return
        }
        #expect(exact.match == .exactPhrase)
        let recalling = "Attiva Mute in Synthetic Mixer. Prima dimmi se hai un’esperienza verificata che può aiutare; "
            + "poi osserva la finestra attuale e agisci solo se il controllo è presente."
        guard case .suggest(let step, _) = suggest(recalling, [record()]) else {
            Issue.record("the recall phrase was not recalled"); return
        }
        #expect(step.match == .sameStep)
        guard case .suggest = suggest("Turn Mute on", [record()]) else { Issue.record("English not recalled"); return }
    }

    @Test("a request for the other state, an unclear state or a compound goal recalls nothing")
    func otherState() {
        for input in ["Disattiva Mute", "Turn Mute off", "Imposta Mute", "Attiva Mute e poi esporta il mix"] {
            guard case .abstain(nil, let considered) = suggest(input, [record()]) else {
                Issue.record("'\(input)' recalled the 'on' memory"); continue
            }
            #expect(considered.map(\.verdict) == ["no match"])
        }
        let both = [record(), record(.off, phrase: "Disattiva Mute")]
        guard case .suggest(let off, _) = suggest("Disattiva Mute", both) else {
            Issue.record("the 'off' memory was not recalled"); return
        }
        #expect(off.record.step == .setToggle(control: "Mute", section: nil, state: .off))
    }

    @Test("a toggle remembered in a section is recalled only for a request that names that section")
    func sectionRecall() {
        let context = WindowContext(bundleID: bundle, windowTitle: "Synthetic Mixer")!
        let draft = ExperienceDraft(phrase: "Attiva Mute in Track 1",
                                    step: .setToggle(control: "Mute", section: "Track 1", state: .on), context: context)!
        let track1 = ExperienceRecord(id: ExperienceID("track-1"), draft: draft, createdAt: verifiedAt, successCount: 1,
                                      lastVerifiedAt: verifiedAt)
        guard case .abstain(nil, _) = suggest("Attiva Mute in Track 2", [track1]) else {
            Issue.record("Track 1 was recalled for Track 2"); return
        }
        guard case .abstain(nil, _) = suggest("Attiva Mute", [track1]) else {
            Issue.record("a sectioned memory was recalled without its section"); return
        }
        guard case .suggest(let suggestion, _) = suggest("Attiva Mute nella sezione Track 1", [track1]) else {
            Issue.record("Track 1 was not recalled for Track 1"); return
        }
        #expect(suggestion.match == .sameStep)
    }

    @Test("a memory without a section is not recalled for a request that narrows the control further")
    func genericMemoryNotRecalledForASection() {
        for input in ["Attiva Mute in Track 2", "Enable Mute on the master track", "Attiva Mute nella traccia 2"] {
            guard case .abstain(nil, _) = suggest(input, [record()]) else {
                Issue.record("'\(input)' recalled the memory learned without a section"); continue
            }
        }
        guard case .suggest = suggest("Attiva Mute in Synthetic Mixer", [record()]) else {
            Issue.record("the remembered window's own name stopped the recall"); return
        }
    }

    @Test("a fresh scene of the window shows the toggle present; another application refuses it")
    func presence() {
        let fresh = Recall.Context(freshScene: scene([mute(.off)]))
        guard case .suggest(let present, _) = suggest("Attiva Mute", [record()], context: fresh) else {
            Issue.record("no suggestion"); return
        }
        #expect(present.presence == .presentNow)
        let absent = Recall.Context(freshScene: scene([]))
        guard case .historical(_, .notOperationalNow(.absentNow), _) = suggest("Attiva Mute", [record()], context: absent)
        else { Issue.record("an absent toggle was offered"); return }
        let other = Recall.Context(bundleID: "test.synthetic.other", windowFamily: "syntheticmixer")
        guard case .abstain(let refused?, _) = suggest("Attiva Mute", [record()], context: other),
              case .otherApplication = refused.refusal else { Issue.record("another application was not refused"); return }
    }

    @Test("the briefing remembers a state to reach with set_toggle, never a click")
    func briefing() throws {
        let answer = suggest("Attiva Mute", [record()])
        let briefing = try #require(RecallBriefing(answer, records: [record()]))
        let remembered = try #require(briefing.remembered)
        #expect(remembered.tool == "set_toggle")
        #expect(remembered.control == "Mute" && remembered.state == "on")
        #expect(remembered.item == nil && remembered.section == nil)
        #expect(briefing.guidance.contains("verb set_toggle"))
        #expect(briefing.guidance.contains("not a click"))
        #expect(record().recallExperience.tool == "set_toggle")
        #expect(record().recallExperience.argsJSON == #"{"target":"Mute","value":"on"}"#)
    }
}
