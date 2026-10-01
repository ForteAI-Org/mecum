//
//  ToggleAdmissionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// Synthetic toggle turns and requests; no application, store or provider is involved.
@Suite("Which turns may teach a single-toggle experience")
struct ToggleAdmissionTests {

    private let request = "Attiva Mute e verifica che sia attivo."
    private let preparation: [TurnAdmission.Attempt] = [
        .preparation("status"), .preparation("open_session"), .preparation("observe"),
    ]
    private let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer")!

    private func evidence(
        wanted: ControlState = .on,
        before: ToggleEvidence.Reading = .read(.off, .resolvedElement),
        click : ToggleEvidence.Click = .sent,
        after : ToggleEvidence.Reading? = .read(.on, .sameElement),
        window: String = "Synthetic Mixer",
        section: String? = nil,
        container: String? = nil
    ) -> ToggleEvidence {
        ToggleEvidence(bundleID: "test.synthetic.mixer", windowTitle: window, control: "Mute", controlRole: "AXCheckBox",
                       section: section, container: container, desiredState: wanted, stateBefore: before,
                       click: click, stateAfter: after)
    }

    private func toggle(
        _ proof : ToggleEvidence?,
        wanted  : ControlState = .on,
        target  : String = "Mute",
        section : String? = nil,
        kind    : ActOutcomeKind? = nil
    ) -> TurnAdmission.Attempt {
        let arguments = ActionArguments(target: target, verb: .setToggle, section: section, desiredState: wanted)
        let derived: ActOutcomeKind = switch proof?.change {
            case .changed?   : .foundActed
            case .alreadySet?: .actedNoop
            default          : proof?.click == ToggleEvidence.Click.none ? .refused : .actedUnverified
        }
        return .act(arguments, kind: kind ?? derived, evidence: proof.map(ActEvidence.toggle))
    }

    private func decide(
        _ request : String? = nil,
        _ attempts: [TurnAdmission.Attempt]? = nil,
        ending    : TurnAdmission.Ending = .completed,
        followed  : TurnAdmission.FollowedExperience? = nil
    ) -> TurnAdmission.Decision {
        TurnAdmission.decide(TurnAdmission.Turn(
            request : request ?? self.request,
            attempts: attempts ?? preparation + [toggle(evidence())],
            ending  : ending,
            followed: followed
        ))
    }

    // MARK: Goals

    @Test("a toggle goal reads its state from the request, in Italian and English")
    func goals() {
        #expect(ToggleGoal.classify("Attiva Mute", control: "Mute") == .single(.on))
        #expect(ToggleGoal.classify("Disattiva Mute e verifica.", control: "Mute") == .single(.off))
        #expect(ToggleGoal.classify("Imposta Mute su on", control: "Mute") == .single(.on))
        #expect(ToggleGoal.classify("metti Mute su spento, poi dimmi com'è", control: "Mute") == .single(.off))
        #expect(ToggleGoal.classify("Turn Mute off", control: "Mute") == .single(.off))
        #expect(ToggleGoal.classify("Enable Mute on the master panel", control: "Mute", section: "Master")
                == .single(.on))
        #expect(ToggleGoal.classify("Attiva Mute. Fermati se non è univoco.", control: "Mute") == .single(.on))
        #expect(ToggleGoal.classify("Attiva On Air", control: "On Air") == .single(.on), "a control's name is no state")
    }

    @Test("an unclear state, another action or a second toggle is not a single toggle goal")
    func notSingleGoals() {
        #expect(ToggleGoal.classify("Imposta Mute", control: "Mute") == .uncertain("imposta mute"))
        #expect(ToggleGoal.classify("Disable Mute on track 1", control: "Mute") == .uncertain("disable mute on track 1"))
        #expect(ToggleGoal.classify("Attiva Mute e poi esporta il mix", control: "Mute") == .compound("esporta il mix"))
        #expect(ToggleGoal.classify("Seleziona Output Busses e attiva Mute", control: "Mute")
                == .compound("seleziona output busses"))
        #expect(ToggleGoal.classify("Attiva Mute e disattiva Solo", control: "Mute") == .severalSteps)
        #expect(ToggleGoal.classify("Attiva Solo", control: "Mute") == .targetNotNamed)
        #expect(ToggleGoal.classify("Clicca Mute", control: "Mute") == .compound("clicca mute"))
        #expect(ToggleGoal.classify("Verifica Mute", control: "Mute") == .noStep)
    }

    @Test("a negation, an alternative, a second action or another name is never a single toggle goal")
    func contestedGoals() {
        #expect(ToggleGoal.classify("Non attivare Mute", control: "Mute") == .uncertain("non attivare mute"))
        #expect(ToggleGoal.classify("Non disattivare Mute", control: "Mute") == .uncertain("non disattivare mute"))
        #expect(ToggleGoal.classify("Don't enable Mute", control: "Mute") == .uncertain("don t enable mute"))
        #expect(ToggleGoal.classify("Attiva Mute, attiva Solo", control: "Mute") == .severalSteps)
        #expect(ToggleGoal.classify("Attiva Mute attiva Solo", control: "Mute") == .uncertain("attiva mute attiva solo"))
        #expect(ToggleGoal.classify("Attiva Mute, Solo", control: "Mute") == .uncertain("solo"))
        #expect(ToggleGoal.classify("Attiva Mute oppure Solo", control: "Mute") == .uncertain("attiva mute oppure solo"))
        #expect(ToggleGoal.classify("Attiva anche Mute", control: "Mute") == .uncertain("attiva anche mute"))
        #expect(ToggleGoal.classify("Attiva Unmute", control: "Mute") == .targetNotNamed)
        #expect(ToggleGoal.classify("Per favore, attiva Mute", control: "Mute") == .single(.on))
        #expect(ToggleGoal.classify("Imposta il guadagno a 0,5 e attiva Mute", control: "Mute")
                == .uncertain("imposta il guadagno a 0 5"), "a decimal comma does not end a clause")
        #expect(ToggleGoal.classify("Attiva Mute. Non procedere se non è univoco.", control: "Mute") == .single(.on))
    }

    @Test("a section is named by its whole words in the toggle clause, or the goal is not that toggle")
    func sectionGoals() {
        #expect(ToggleGoal.classify("Attiva Mute in Track 1", control: "Mute", section: "Track 1") == .single(.on))
        #expect(ToggleGoal.classify("Attiva Mute in Track 2", control: "Mute", section: "Track 1") == .sectionNotNamed)
        #expect(ToggleGoal.classify("Attiva Mute in Track 10", control: "Mute", section: "Track 1") == .sectionNotNamed)
        #expect(ToggleGoal.classify("Attiva Mute", control: "Mute", section: "Track 1") == .sectionNotNamed)
    }

    @Test("a toggle narrowed to a section the request does not name is kept, never promoted or confirmed")
    func sectionAdmission() {
        let proof = evidence(section: "Track 1")
        let step = ExperienceStep.setToggle(control: "Mute", section: "Track 1", state: .on)
        let followed = TurnAdmission.FollowedExperience(id: ExperienceID("track-1"), step: step, context: mixer)
        let wrong = decide("Attiva Mute in Track 2", preparation + [toggle(proof, section: "Track 1")], followed: followed)
        #expect(wrong.reason == .sectionNotInGoal)
        #expect(wrong.action == .keepAttempt(mixer, .verified(.toggle(proof))))
        let right = decide("Attiva Mute in Track 1", preparation + [toggle(proof, section: "Track 1")], followed: followed)
        #expect(right.action == .confirm(ExperienceID("track-1"), .toggle(proof)))
        for request in ["Non attivare Mute", "Attiva Mute, attiva Solo", "Attiva Unmute"] {
            #expect(decide(request).action != decide().action, "'\(request)' was learned")
        }
    }

    // MARK: Promotion

    @Test("a request that narrows the control further than the step keeps is qualified, never single")
    func qualifiedGoals() {
        #expect(ToggleGoal.classify("Attiva Mute in Track 2", control: "Mute") == .qualified("track 2"))
        #expect(ToggleGoal.classify("Enable Mute on the master track", control: "Mute") == .qualified("master track"))
        #expect(ToggleGoal.classify("Enable Mute on the master track", control: "Mute", section: "Master")
                == .qualified("track"), "a track is one application's panel, not a noun of every interface")
        #expect(ToggleGoal.classify("Attiva il Mute del pannello Track 2", control: "Mute", section: "Track 2")
                == .single(.on), "a panel noun of any interface joins the section")
        #expect(ToggleGoal.classify("Attiva il Mute della traccia Track 2", control: "Mute", section: "Track 2")
                == .qualified("traccia"), "a noun of one application's domain is not represented by the step")
        #expect(ToggleGoal.classify("Attiva Mute in Synthetic Mixer", control: "Mute") == .qualified("synthetic mixer"))
        #expect(ToggleGoal.classify("Attiva Mute in Synthetic Mixer", control: "Mute", windows: ["Synthetic Mixer"])
                == .single(.on), "the proof's own window names the context, not the control")
        #expect(ToggleGoal.classify("Attiva il pulsante Mute, per favore", control: "Mute") == .single(.on))
    }

    @Test("a memory without a section is never learned or confirmed by a request about another section")
    func genericMemoryAndSection() {
        let remembered = ExperienceID("experience-1")
        let generic = TurnAdmission.FollowedExperience(
            id: remembered, step: .setToggle(control: "Mute", section: nil, state: .on), context: mixer)
        let inTrack1 = evidence(section: "Track 1")
        let unnarrowed = decide("Attiva Mute in Track 2", preparation + [toggle(inTrack1)], followed: generic)
        #expect(unnarrowed.reason == .qualifierNotInStep)
        #expect(unnarrowed.action == .keepAttempt(mixer, .verified(.toggle(inTrack1))))
        let narrowed = decide("Attiva Mute in Track 2", preparation + [toggle(inTrack1, section: "Track 1")],
                              followed: generic)
        #expect(narrowed.reason == .sectionNotInGoal)
        let inTrack2 = evidence(section: "Track 2")
        let unique = decide("Attiva Mute in Track 2", preparation + [toggle(inTrack2)], followed: generic)
        #expect(unique.reason == .qualifierNotInStep, "an unnarrowed call proves no section, even the right one")
        let named = decide("Attiva Mute in Track 2", preparation + [toggle(inTrack2, section: "Track 2")],
                           followed: generic)
        guard case .promote(let draft, _) = named.action else {
            Issue.record("the narrowed toggle was not learned as its own experience: \(named)"); return
        }
        #expect(draft.step == .setToggle(control: "Mute", section: "Track 2", state: .on))
    }

    @Test("a verified off to on under a single toggle goal is promoted with the state as the step")
    func promoted() throws {
        let decision = decide()
        #expect(decision.reason == .admittedSingleToggle)
        guard case .promote(let draft, let proof) = decision.action else { Issue.record("not promoted"); return }
        #expect(draft.step == .setToggle(control: "Mute", section: nil, state: .on))
        #expect(draft.step.arguments == ["target": "Mute", "value": "on"])
        #expect(draft.context == mixer)
        #expect(proof == .toggle(evidence()))
        let event = try #require(decision.event(id: "turn-1", at: Date(timeIntervalSince1970: 0)))
        #expect(event.outcome == .verified(.toggle(evidence())))
        let offProof = evidence(wanted: .off, before: .read(.on, .resolvedElement), after: .read(.off, .sameLabel))
        let off = decide("Disattiva Mute", preparation + [toggle(offProof, wanted: .off)])
        guard case .promote(let offDraft, _) = off.action else { Issue.record("on to off not promoted"); return }
        #expect(offDraft.step == .setToggle(control: "Mute", section: nil, state: .off))
        #expect(offDraft.naturalKey != draft.naturalKey)
    }

    @Test("a section the request named is kept and must be the one the control resolved in")
    func section() {
        let proof = evidence(section: "Track 1")
        let named = decide("Attiva Mute nel pannello Track 1", preparation + [toggle(proof, section: "Track 1")])
        guard case .promote(let draft, _) = named.action else { Issue.record("not promoted"); return }
        #expect(draft.step == .setToggle(control: "Mute", section: "Track 1", state: .on))
        let unnamed = decide(nil, preparation + [toggle(proof)])
        guard case .promote(let plain, _) = unnamed.action else { Issue.record("not promoted"); return }
        #expect(plain.step == .setToggle(control: "Mute", section: nil, state: .on))
        #expect(decide(nil, preparation + [toggle(proof, section: "Track 2")]).reason == .argumentsDoNotMatchEvidence)
    }

    /// The proof keeps the control's section and container as the scene showed them. A call's panel is
    /// matched against those two observations; the call's own words are never what the proof holds.
    @Test("a panel the call named is kept as the section or container the proof observed, and nothing else")
    func panelObservedByTheProof() {
        let proof = evidence(section: "Strip", container: "Track 2")
        let byContainer = decide("Attiva Mute in track 2", preparation + [toggle(proof, section: "track 2")])
        guard case .promote(let draft, _) = byContainer.action else {
            Issue.record("not promoted: \(byContainer)"); return
        }
        #expect(draft.step == .setToggle(control: "Mute", section: "Track 2", state: .on))
        let bySection = decide("Attiva Mute in Strip", preparation + [toggle(proof, section: "Strip")])
        guard case .promote(let strip, _) = bySection.action else { Issue.record("not promoted: \(bySection)"); return }
        #expect(strip.step == .setToggle(control: "Mute", section: "Strip", state: .on))
        #expect(decide("Attiva Mute in Track 3", preparation + [toggle(proof, section: "Track 3")]).reason
                == .argumentsDoNotMatchEvidence, "a panel the proof did not observe is not the control's")
    }

    @Test("a toggle already in the requested state is kept as no change and never learned")
    func alreadySet() {
        let already = evidence(before: .read(.on, .resolvedElement), click: .none, after: nil)
        let decision = decide(nil, preparation + [toggle(already)])
        #expect(decision.reason == .alreadySet)
        #expect(decision.action == .keepAttempt(mixer, .noChange(.toggle(already))))
        let followed = TurnAdmission.FollowedExperience(
            id: ExperienceID("experience-1"), step: .setToggle(control: "Mute", section: nil, state: .on), context: mixer)
        #expect(decide(nil, preparation + [toggle(already)], followed: followed).action
                == .keepAttempt(mixer, .noChange(.toggle(already))), "no change never confirms the followed memory")
        #expect(decide(nil, preparation + [toggle(already, kind: .foundActed)]).reason == .notVerified)
    }

    @Test("an unknown start or an ambiguous end is kept as uncertain and never learned")
    func uncertain() {
        let unknown = evidence(before: .unreadable(.indefinite), click: .none, after: nil)
        let refused = decide(nil, preparation + [toggle(unknown)])
        #expect(refused.reason == .notVerified)
        #expect(refused.action == .keepAttempt(mixer, .uncertain(.toggleStateUnreadable(.indefinite))))
        let ambiguous = evidence(after: .unreadable(.severalMatches))
        #expect(decide(nil, preparation + [toggle(ambiguous)]).action
                == .keepAttempt(mixer, .uncertain(.toggleStateUnreadable(.severalMatches))))
        let unprovenStart = evidence(before: .unreadable(.noScene), after: .read(.on, .sameElement))
        #expect(unprovenStart.change == .unverified, "a correct end after an unknown start proves no transition")
        #expect(decide(nil, preparation + [toggle(unprovenStart, kind: .foundActed)]).reason == .notVerified)
        let failed = evidence(click: .failed, after: nil)
        #expect(decide(nil, preparation + [toggle(failed)]).action
                == .keepAttempt(mixer, .uncertain(.failureNotAttributable)))
    }

    @Test("the other state after the click contradicts only the followed toggle in its own context")
    func contradiction() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.setToggle(control: "Mute", section: nil, state: .on)
        let stuck = evidence(after: .read(.off, .sameElement))
        let attempts = preparation + [toggle(stuck)]
        let here = decide(nil, attempts,
                          followed: TurnAdmission.FollowedExperience(id: remembered, step: step, context: mixer))
        #expect(here.action == .contradict(remembered, .readbackShowed("off")))
        let master = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Master")!
        let elsewhere = decide(nil, attempts,
                               followed: TurnAdmission.FollowedExperience(id: remembered, step: step, context: master))
        #expect(elsewhere.action == .keepAttempt(mixer, .contradicted(.readbackShowed("off"))))
        let otherState = TurnAdmission.FollowedExperience(
            id: remembered, step: .setToggle(control: "Mute", section: nil, state: .off), context: mixer)
        guard case .keepAttempt = decide(nil, attempts, followed: otherState).action else {
            Issue.record("a memory of the other state was contradicted"); return
        }
    }

    @Test("a verified repetition of the followed toggle in its context confirms it; elsewhere it is new")
    func confirmation() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.setToggle(control: "Mute", section: nil, state: .on)
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: mixer)
        #expect(decide("Attiva Mute", followed: followed).action == .confirm(remembered, .toggle(evidence())))
        let master = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Master")!
        #expect(decide(followed: .init(id: remembered, step: step, context: master)).reason == .admittedSingleToggle)
    }

    // MARK: Exclusions

    @Test("a compound goal, another state, other tools, a batch and an incomplete turn are not promoted")
    func exclusions() {
        #expect(decide("Attiva Mute e poi esporta il mix").reason == .compoundGoal)
        #expect(decide("Disattiva Mute").reason == .stateNotInGoal)
        #expect(decide("Attiva Solo").reason == .controlNotInGoal)
        #expect(decide("Mute").reason == .uncertainGoal)
        let click = TurnAdmission.Attempt.act(ActionArguments(target: "Export", verb: .click), kind: .foundActed,
                                              evidence: nil)
        #expect(decide(nil, preparation + [click, toggle(evidence())]).reason == .severalSteps)
        #expect(decide(nil, preparation + [.batch, toggle(evidence())]).reason == .batchUsed)
        #expect(decide(nil, preparation + [toggle(evidence()), toggle(evidence())]).reason == .severalSteps)
        let select = TurnAdmission.Attempt.select(control: "All Busses", item: "Output Busses", kind: .foundActed,
                                                  evidence: nil)
        #expect(decide(nil, preparation + [select, toggle(evidence())]).reason == .severalSteps)
        #expect(decide(nil, preparation + [toggle(evidence()), .failed("observe")]).reason == .toolFailed)
        #expect(decide(ending: .interrupted).reason == .turnInterrupted)
        #expect(decide(ending: .handedToUser).reason == .handedToUser)
        #expect(decide(nil, preparation + [toggle(nil)]).reason == .noEvidence)
        #expect(decide(nil, preparation + [toggle(evidence(), target: "Solo")]).reason == .argumentsDoNotMatchEvidence)
        #expect(decide(nil, preparation + [toggle(evidence(window: "12:30"))]).reason == .noAttributableContext)
        let failed = ActionArguments(target: "Mute", verb: .setToggle, desiredState: .on)
        #expect(decide(nil, preparation + [.failed("act", act: failed)]).reason == .toolFailed)
    }
}
