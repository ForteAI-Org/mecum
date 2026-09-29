//
//  ClickRecallTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// Synthetic click, double-click and right-click experiences learned in a mixer window, recalled
/// for other requests.
@Suite("Contextual recall of a verified click")
struct ClickRecallTests {

    private let bundle = "test.synthetic.mixer"
    private let verifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ gesture: ClickEvidence.Gesture = .rightClick,
        target   : String = "Track 1",
        section  : String? = nil,
        opens    : ClickEvidence.Surface = .menu,
        phrase   : String = "Fai clic destro su Track 1"
    ) -> ExperienceRecord {
        let context = WindowContext(bundleID: bundle, windowTitle: "Synthetic Mixer")!
        let step = ExperienceStep.click(gesture, target: target, section: section, opens: opens)
        let draft = ExperienceDraft(phrase: phrase, step: step, context: context)!
        let effect: ClickEvidence.Effect = switch opens {
            case .menu             : .menuOpened(items: ["Delete Track", "Rename"])
            case .window(let title): .windowOpened(title: title)
        }
        let proof = ClickEvidence(bundleID: bundle, windowTitle: "Synthetic Mixer", target: target, targetRole: nil,
                                  section: section, gesture: gesture, delivery: .sent, effect: effect)
        return ExperienceRecord(id: ExperienceID("\(gesture.rawValue)-\(target)"), draft: draft, createdAt: verifiedAt,
                                successCount: 1, latestProof: .click(proof), lastVerifiedAt: verifiedAt)
    }

    private func suggest(_ input: String, _ records: [ExperienceRecord], context: Recall.Context = Recall.Context())
        -> Recall.SuggestionAnswer {
        Recall.suggest(input: input, in: Recall.World(records: records, sightings: [], context: context))
    }

    private func scene(_ labels: [String]) -> SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: bundle, appName: "Synthetic Mixer", windowTitle: "Synthetic Mixer",
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: labels.enumerated().map { index, label in
                SceneElement(id: "control|\(label.lowercased())|\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.1, height: 0.05))
            }
        )
        scene.coverage = .window
        return scene
    }

    @Test("a request for the remembered gesture on its target finds it, however it is phrased")
    func sameGesture() {
        guard case .suggest(let exact, _) = suggest("Fai clic destro su Track 1", [record()]) else {
            Issue.record("the learning phrase was not recalled"); return
        }
        #expect(exact.match == .exactPhrase)
        for input in ["Right-click Track 1 to open the context menu", "Clicca con il tasto destro su Track 1",
                      "Fai clic destro su Track 1 in Synthetic Mixer"] {
            guard case .suggest(let step, _) = suggest(input, [record()]) else {
                Issue.record("'\(input)' did not recall the right-click"); continue
            }
            #expect(step.match == .sameStep)
        }
    }

    @Test("another gesture, another surface, another target or a qualified request recalls nothing")
    func noCrossGesture() {
        for input in ["Clicca Track 1", "Fai doppio clic su Track 1", "Fai clic destro su Track 1 per aprire la finestra",
                      "Fai clic destro su Track 2", "Fai clic destro su Track 1 nella traccia 2",
                      "Non fare clic destro su Track 1", "Fai clic destro su Track 1 e poi elimina la traccia"] {
            guard case .abstain(nil, let considered) = suggest(input, [record()]) else {
                Issue.record("'\(input)' recalled the right-click"); continue
            }
            #expect(considered.map(\.verdict) == ["no match"], "'\(input)'")
        }
        let click = record(.click, target: "Track 1", opens: .menu, phrase: "Clicca Track 1")
        guard case .suggest(let chosen, _) = suggest("Clicca Track 1", [record(), click]) else {
            Issue.record("the click was not recalled beside the right-click"); return
        }
        #expect(chosen.record.step == .click(.click, target: "Track 1", section: nil, opens: .menu))
    }

    @Test("a second target named Stop is not a guard, so the click memory is not offered for it")
    func stopIsNoGuard() {
        let play = record(.click, target: "Play", opens: .menu, phrase: "Clicca Play")
        guard case .abstain(nil, _) = suggest("Clicca Play e poi Stop", [play]) else {
            Issue.record("a compound request recalled the click"); return
        }
        guard case .suggest = suggest("Clicca Play. Stop if it is not unique.", [play]) else {
            Issue.record("a real guard stopped the recall"); return
        }
    }

    @Test("a sectioned memory needs its section, and a generic one is not recalled for a section")
    func sections() {
        let sectioned = record(section: "Mixer", phrase: "Fai clic destro su Track 1 nel pannello Mixer")
        guard case .abstain(nil, _) = suggest("Fai clic destro su Track 1", [sectioned]) else {
            Issue.record("a sectioned memory was recalled without its section"); return
        }
        guard case .suggest = suggest("Fai clic destro su Track 1 nel Mixer", [sectioned]) else {
            Issue.record("the sectioned memory was not recalled for its section"); return
        }
        guard case .abstain(nil, _) = suggest("Fai clic destro su Track 1 nel pannello Edit", [record()]) else {
            Issue.record("a generic memory was recalled for a named panel"); return
        }
    }

    @Test("a fresh scene shows the target present, absent or ambiguous; the step is never a point")
    func presenceAndBriefing() throws {
        let present = Recall.Context(freshScene: scene(["Track 1", "Track 2"]))
        guard case .suggest(let suggestion, _) = suggest("Fai clic destro su Track 1", [record()], context: present)
        else { Issue.record("not suggested"); return }
        #expect(suggestion.presence == .presentNow)
        let absent = Recall.Context(freshScene: scene(["Track 2"]))
        guard case .historical(_, .notOperationalNow(.absentNow), _) = suggest("Fai clic destro su Track 1", [record()],
                                                                               context: absent)
        else { Issue.record("an absent target was offered"); return }
        let twice = Recall.Context(freshScene: scene(["Track 1", "Track 1"]))
        guard case .historical(_, .notOperationalNow(.ambiguousNow), _) = suggest("Fai clic destro su Track 1",
                                                                                  [record()], context: twice)
        else { Issue.record("an ambiguous target was offered"); return }

        let window = record(.doubleClick, target: "Project", opens: .window(title: "Project 1"),
                            phrase: "Fai doppio clic su Project")
        let answer = suggest("Fai doppio clic su Project", [window])
        let briefing = try #require(RecallBriefing(answer, records: [window]))
        #expect(briefing.status == "suggested")
        #expect(briefing.remembered?.tool == "double_click")
        #expect(briefing.remembered?.control == "Project")
        #expect(briefing.remembered?.opens == "the window 'Project 1'")
        #expect(briefing.remembered?.item == nil && briefing.remembered?.state == nil)
        #expect(briefing.guidance.contains("use act with verb double_click"))
        #expect(!briefing.guidance.contains("set_toggle"))
    }
}
