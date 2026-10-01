//
//  ClickAdmissionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// Synthetic click, double-click and right-click turns and requests; no application, store or
/// provider is involved.
@Suite("Which turns may teach a single-click experience")
struct ClickAdmissionTests {

    private let preparation: [TurnAdmission.Attempt] = [
        .preparation("status"), .preparation("open_session"), .preparation("observe"),
    ]
    private let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer")!

    private func evidence(
        _ gesture: ClickEvidence.Gesture = .rightClick,
        target   : String = "Track 1",
        section  : String? = nil,
        delivery : ClickEvidence.Delivery = .sent,
        effect   : ClickEvidence.Effect = .menuOpened(items: ["Delete Track", "Duplicate Track", "Rename"])
    ) -> ClickEvidence {
        ClickEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer", target: target,
                      targetRole: nil, section: section, gesture: gesture, delivery: delivery, effect: effect)
    }

    private func act(
        _ proof : ClickEvidence?,
        verb    : ActionVerb = .rightClick,
        target  : String = "Track 1",
        section : String? = nil,
        kind    : ActOutcomeKind = .foundActed
    ) -> TurnAdmission.Attempt {
        .act(ActionArguments(target: target, verb: verb, section: section), kind: kind,
             evidence: proof.map(ActEvidence.click))
    }

    private func decide(
        _ request : String,
        _ attempts: [TurnAdmission.Attempt],
        ending    : TurnAdmission.Ending = .completed,
        followed  : TurnAdmission.FollowedExperience? = nil
    ) -> TurnAdmission.Decision {
        TurnAdmission.decide(TurnAdmission.Turn(request: request, attempts: preparation + attempts, ending: ending,
                                                followed: followed))
    }

    @Test("a surface in the evidence of an unverified outcome is kept as uncertain, never as verified history")
    func unverifiedOutcomeIsNotVerifiedHistory() {
        let decision = decide("Fai clic destro su Track 1", [act(evidence(), kind: .actedUnverified)])
        #expect(decision.reason == .notVerified)
        #expect(decision.action == .keepAttempt(mixer, .uncertain(.outcomeNotVerified)))
    }

    @Test func windowNamesDoNotHideRealAlternatives() {
        let windows = ["I/O Setup"]
        #expect(ClickGoal.classify("Chiudi I/O Setup con Cancel", target: "Cancel", windows: windows)
                == .single(ClickGoal.Ask(.click, opens: nil, closes: true)))
        for request in ["Chiudi I/O Setup con Cancel o OK", "Non chiudere I/O Setup con Cancel",
                        "Chiudi Other Window con Cancel"] {
            #expect(ClickGoal.classify(request, target: "Cancel", windows: windows)
                    != .single(ClickGoal.Ask(.click, opens: nil, closes: true)))
        }
    }

    @Test func closureMustAnswerTheGoal() throws {
        let proof = evidence(.click, target: "Cancel", effect: .windowClosed(title: "Synthetic Mixer"))
        let attempt = act(proof, verb: .click, target: "Cancel")
        #expect(decide("Close Synthetic Mixer with Cancel", [attempt]).reason == .admittedSingleClick)
        #expect(decide("Click Cancel to open the window", [attempt]).reason == .surfaceNotInGoal)
        for request in ["Do not close Synthetic Mixer with Cancel", "Close Other Window with Cancel",
                        "Close Synthetic Mixer", "Close Synthetic Mixer with Cancel and save",
                        "1. Close Synthetic Mixer with Cancel\n2. Click File"] {
            #expect(decide(request, [attempt]).reason != .admittedSingleClick, "\(request)")
        }
        let opening = evidence(.click, target: "Cancel", effect: .windowOpened(title: "New"))
        #expect(decide("Close Synthetic Mixer with Cancel", [act(opening, verb: .click, target: "Cancel")]).reason
                == .surfaceNotInGoal)
        let step = try #require(ExperienceStep(proof, requestedSection: nil))
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(ExperienceStep.self, from: data) == step)
        let legacy = ExperienceStep.click(.click, target: "Cancel", section: nil, opens: .window(title: "New"))
        #expect(try JSONDecoder().decode(ExperienceStep.self, from: JSONEncoder().encode(legacy)) == legacy)
        let malformed = Data(#"{"tool":"click","control":"Cancel","opens":{"menu":{}},"closes":"Mixer"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExperienceStep.self, from: malformed) }
    }

    // MARK: Goals

    @Test("the gesture comes from the request, in Italian and English, with the surface when it names one")
    func goals() {
        #expect(ClickGoal.classify("Clicca Export", target: "Export") == .single(.click, opens: nil))
        #expect(ClickGoal.classify("Premi il pulsante Export, per favore", target: "Export")
                == .single(.click, opens: nil))
        #expect(ClickGoal.classify("Clicca File per aprire il menu", target: "File") == .single(.click, opens: .menu))
        #expect(ClickGoal.classify("Fai doppio clic su Project per aprirlo", target: "Project")
                == .single(.doubleClick, opens: nil))
        #expect(ClickGoal.classify("Double-click Project to open the window", target: "Project")
                == .single(.doubleClick, opens: .window))
        #expect(ClickGoal.classify("Clicca due volte Project", target: "Project") == .single(.doubleClick, opens: nil))
        #expect(ClickGoal.classify("Fai clic destro su Track 1", target: "Track 1") == .single(.rightClick, opens: nil))
        #expect(ClickGoal.classify("Clicca con il tasto destro su Track 1 e verifica il menu contestuale",
                                   target: "Track 1") == .single(.rightClick, opens: nil),
                "a surface named in another clause is not what the gesture was asked to open")
        #expect(ClickGoal.classify("Right-click Track 1 to open the context menu", target: "Track 1")
                == .single(.rightClick, opens: .menu))
        #expect(ClickGoal.classify("Right-click Track 1. Stop if it is not unique.", target: "Track 1")
                == .single(.rightClick, opens: nil))
        #expect(ClickGoal.classify("Clicca Export in Synthetic Mixer", target: "Export", windows: ["Synthetic Mixer"])
                == .single(.click, opens: nil))
    }

    @Test("a negation, an alternative, another action, a second click or an unnamed target is not a single click")
    func contestedGoals() {
        #expect(ClickGoal.classify("Non cliccare Export", target: "Export") == .uncertain("non cliccare export"))
        #expect(ClickGoal.classify("Clicca Export oppure Import", target: "Export")
                == .uncertain("clicca export oppure import"))
        #expect(ClickGoal.classify("Clicca Export e poi salva il progetto", target: "Export")
                == .compound("salva il progetto"))
        #expect(ClickGoal.classify("Clicca Export, clicca Import", target: "Export") == .severalSteps)
        #expect(ClickGoal.classify("Apri il menu File", target: "File") == .compound("apri il menu file"))
        #expect(ClickGoal.classify("Attiva Mute", target: "Mute") == .compound("attiva mute"))
        #expect(ClickGoal.classify("Clicca Exporter", target: "Export") == .targetNotNamed)
        #expect(ClickGoal.classify("Fai doppio clic destro su Export", target: "Export")
                == .uncertain("fai doppio clic destro su export"))
        #expect(ClickGoal.classify("Clicca Export nel menu della finestra", target: "Export")
                == .uncertain("clicca export nel menu della finestra"))
        #expect(ClickGoal.classify("Export", target: "Export") == .noStep)
    }

    @Test("a section is required when the step keeps one, and a qualifier the step does not keep is refused")
    func sectionGoals() {
        #expect(ClickGoal.classify("Fai clic destro su Track 1 nel pannello Mixer", target: "Track 1", section: "Mixer")
                == .single(.rightClick, opens: nil))
        #expect(ClickGoal.classify("Fai clic destro su Track 1", target: "Track 1", section: "Mixer")
                == .sectionNotNamed)
        #expect(ClickGoal.classify("Clicca Solo in Track 2", target: "Solo") == .qualified("track 2"))
    }

    // MARK: Promotion

    @Test("each gesture that opened an attributed surface under its own goal is promoted as its own step")
    func promoted() throws {
        let right = decide("Fai clic destro su Track 1", [act(evidence())])
        #expect(right.reason == .admittedSingleClick)
        guard case .promote(let draft, let proof) = right.action else { Issue.record("not promoted"); return }
        #expect(draft.step == .click(.rightClick, target: "Track 1", section: nil, opens: .menu))
        #expect(draft.step.tool == .rightClick)
        #expect(draft.step.arguments == ["target": "Track 1", "verb": "right_click"])
        #expect(proof == .click(evidence()))
        #expect(right.event(id: "turn-1", at: Date(timeIntervalSince1970: 0))?.outcome == .verified(.click(evidence())))

        let window = evidence(.doubleClick, target: "Project", effect: .windowOpened(title: "Project 1"))
        let double = decide("Fai doppio clic su Project per aprire la finestra",
                            [act(window, verb: .doubleClick, target: "Project")])
        guard case .promote(let doubleDraft, _) = double.action else { Issue.record("not promoted"); return }
        #expect(doubleDraft.step == .click(.doubleClick, target: "Project", section: nil,
                                           opens: .window(title: "Project 1")))

        let menu = evidence(.click, target: "File", effect: .menuOpened(items: ["New", "Open", "Save"]))
        let click = decide("Clicca File", [act(menu, verb: .click, target: "File")])
        guard case .promote(let clickDraft, _) = click.action else { Issue.record("not promoted"); return }
        #expect(clickDraft.step == .click(.click, target: "File", section: nil, opens: .menu))
        #expect(Set([draft.step.key, doubleDraft.step.key, clickDraft.step.key]).count == 3)
        #expect(ExperienceStep.click(.click, target: "Track 1", section: nil, opens: .menu).key
                != draft.step.key, "a click and a right-click on one target are two steps")
    }

    @Test("a section the call narrowed to is kept and must be named by the request")
    func section() {
        let proof = evidence(section: "Mixer")
        let named = decide("Fai clic destro su Track 1 nel pannello Mixer", [act(proof, section: "Mixer")])
        guard case .promote(let draft, _) = named.action else { Issue.record("not promoted: \(named)"); return }
        #expect(draft.step == .click(.rightClick, target: "Track 1", section: "Mixer", opens: .menu))
        #expect(decide("Fai clic destro su Track 1", [act(proof, section: "Mixer")]).reason == .sectionNotInGoal)
        #expect(decide("Fai clic destro su Track 1 nel pannello Mixer", [act(proof, section: "Edit")]).reason
                == .argumentsDoNotMatchEvidence)
    }

    // MARK: Refusals

    @Test("an input sent, a found_acted or a changed scene without an attributed surface is never learned")
    func unattributed() {
        for why in [ClickEvidence.Unattributed.noChange, .repaint, .otherChange, .surfaceElsewhere,
                    .severalSurfaces, .unreadableSurface, .otherWindow, .noScene] {
            let proof = evidence(effect: .unattributed(why))
            let decision = decide("Fai clic destro su Track 1", [act(proof)])
            #expect(decision.reason == .notVerified, "\(why)")
            #expect(decision.action == .keepAttempt(mixer, .uncertain(.clickEffectUnattributed(why))), "\(why)")
        }
        let failed = evidence(delivery: .failed, effect: .unattributed(.notDelivered))
        #expect(decide("Fai clic destro su Track 1", [act(failed, kind: .actedUnverified)]).action
                == .keepAttempt(mixer, .uncertain(.failureNotAttributable)))
        #expect(decide("Fai clic destro su Track 1", [act(nil)]).reason == .noEvidence)
        #expect(decide("Fai clic destro su Track 1", [act(evidence(), kind: .actedUnverified)]).reason == .notVerified,
                "an outcome that reported a surprise is not learned, whatever the evidence says")
    }

    @Test("another gesture, another surface, another target or a qualified request is not promoted")
    func goalMismatch() {
        #expect(decide("Clicca Track 1", [act(evidence())]).reason == .gestureNotInGoal)
        #expect(decide("Fai doppio clic su Track 1", [act(evidence())]).reason == .gestureNotInGoal)
        let asRight = evidence(.rightClick)
        #expect(decide("Fai clic destro su Track 1", [act(asRight, verb: .click)]).reason
                == .argumentsDoNotMatchEvidence, "a right-click's proof never stands for a click call")
        #expect(decide("Fai clic destro su Track 1 per aprire la finestra", [act(evidence())]).reason
                == .surfaceNotInGoal)
        #expect(decide("Fai clic destro su Track 2", [act(evidence())]).reason == .controlNotInGoal)
        #expect(decide("Fai clic destro su Track 1 nella traccia 2", [act(evidence())]).reason == .qualifierNotInStep)
        #expect(decide("Non fare clic destro su Track 1", [act(evidence())]).reason == .uncertainGoal)
        #expect(decide("Fai clic destro su Track 1 e poi elimina la traccia", [act(evidence())]).reason
                == .compoundGoal)
        #expect(decide("Fai clic destro su Track 1", [act(evidence(), target: "Track 2")]).reason
                == .argumentsDoNotMatchEvidence)
    }

    @Test("several steps, a batch, a failed call and an unfinished turn are excluded")
    func exclusions() {
        let request = "Fai clic destro su Track 1"
        #expect(decide(request, [act(evidence()), act(evidence())]).reason == .severalSteps)
        #expect(decide(request, [.batch, act(evidence())]).reason == .batchUsed)
        #expect(decide(request, [act(evidence()), .failed("observe")]).reason == .toolFailed)
        let failed = ActionArguments(target: "Track 1", verb: .rightClick)
        #expect(decide(request, [.failed("act", act: failed)]).reason == .toolFailed)
        #expect(decide(request, [act(evidence())], ending: .interrupted).reason == .turnInterrupted)
        #expect(decide(request, [act(evidence())], ending: .failed).reason == .turnFailed)
        #expect(decide(request, [act(evidence())], ending: .handedToUser).reason == .handedToUser)
    }

    // MARK: Followed experiences

    @Test("the same gesture, target, section and surface in the learned window confirms the memory")
    func confirmation() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.click(.rightClick, target: "Track 1", section: nil, opens: .menu)
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: mixer)
        let decision = decide("Fai clic destro su Track 1", [act(evidence())], followed: followed)
        #expect(decision.action == .confirm(remembered, .click(evidence())))
        let other = TurnAdmission.FollowedExperience(
            id: remembered, step: .click(.click, target: "Track 1", section: nil, opens: .menu), context: mixer)
        #expect(decide("Fai clic destro su Track 1", [act(evidence())], followed: other).reason == .admittedSingleClick,
                "a click memory is never confirmed by a right-click")
        let window = TurnAdmission.FollowedExperience(
            id: remembered, step: .click(.rightClick, target: "Track 1", section: nil, opens: .window(title: "Info")),
            context: mixer)
        #expect(decide("Fai clic destro su Track 1", [act(evidence())], followed: window).reason
                == .admittedSingleClick)
        let sectioned = TurnAdmission.FollowedExperience(
            id: remembered, step: .click(.rightClick, target: "Track 1", section: "Mixer", opens: .menu), context: mixer)
        #expect(decide("Fai clic destro su Track 1", [act(evidence())], followed: sectioned).reason
                == .admittedSingleClick, "an unnarrowed call never confirms a memory narrowed to a section")
    }

    @Test("a click never contradicts: a missing effect is uncertain, even after following a memory")
    func neverContradicts() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.click(.rightClick, target: "Track 1", section: nil, opens: .menu)
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: mixer)
        let ghost = evidence(effect: .unattributed(.noChange))
        #expect(decide("Fai clic destro su Track 1", [act(ghost, kind: .actedUnverified)], followed: followed).action
                == .keepAttempt(mixer, .uncertain(.clickEffectUnattributed(.noChange))))
    }

    // MARK: Persistence shape

    @Test("a click step and its proof keep their shape through JSON, beside selects and toggles")
    func coding() throws {
        let steps: [ExperienceStep] = [
            .click(.click, target: "File", section: nil, opens: .menu),
            .click(.doubleClick, target: "Project", section: "Browser", opens: .window(title: "Project 1")),
            .click(.rightClick, target: "Track 1", section: nil, opens: .menu),
            .setToggle(control: "Mute", section: nil, state: .on),
            .select(control: "All Busses", item: "Output Busses"),
        ]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for step in steps {
            #expect(try decoder.decode(ExperienceStep.self, from: encoder.encode(step)) == step)
        }
        let proof = ActEvidence.click(evidence(.doubleClick, effect: .windowOpened(title: "Project 1")))
        #expect(try decoder.decode(ActEvidence.self, from: encoder.encode(proof)) == proof)
        let select = #"{"tool":"select","control":"All Busses","item":"Output Busses"}"#
        #expect(try decoder.decode(ExperienceStep.self, from: Data(select.utf8))
                == .select(control: "All Busses", item: "Output Busses"))
    }
}
