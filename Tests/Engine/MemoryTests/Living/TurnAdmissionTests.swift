//
//  TurnAdmissionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// Synthetic turns; the Italian requests are the ones the task's guide uses.
@Suite("Which turns may teach a single-selection experience")
struct TurnAdmissionTests {

    private let guideRequest = "Seleziona Output Busses nel filtro e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recallRequest = "Seleziona Output Busses nel filtro. Prima dimmi se "
        + "hai un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."
    private let preparation: [TurnAdmission.Attempt] = [
        .preparation("status"), .preparation("windows"), .preparation("open_session"), .preparation("observe"),
    ]

    private func evidence(
        before  : String = "All Busses",
        item    : String = "Output Busses",
        readback: DropdownReadback? = nil,
        bundle  : String = "test.synthetic.mixer"
    ) -> DropdownEvidence {
        DropdownEvidence(bundleID: bundle, windowTitle: "Synthetic Routing", control: before,
                         controlRole: "AXPopUpButton", section: nil, valueBefore: before,
                         requestedItem: item, readback: readback ?? .window(item), menuClosedByChoice: true)
    }

    private func select(
        _ proof : DropdownEvidence?,
        control : String = "All Busses",
        item    : String = "Output Busses",
        kind    : ActOutcomeKind? = nil
    ) -> TurnAdmission.Attempt {
        .select(control: control, item: item,
                kind: kind ?? ((proof?.isVerified ?? true) ? .foundActed : .actedUnverified), evidence: proof)
    }

    private func decide(
        _ request : String? = nil,
        _ attempts: [TurnAdmission.Attempt]? = nil,
        ending    : TurnAdmission.Ending = .completed,
        followed  : TurnAdmission.FollowedExperience? = nil
    ) -> TurnAdmission.Decision {
        TurnAdmission.decide(TurnAdmission.Turn(
            request : request ?? guideRequest,
            attempts: attempts ?? preparation + [select(evidence()), .preparation("observe")],
            ending  : ending,
            followed: followed
        ))
    }

    // MARK: Promotion

    @Test("the guide's request with preparation and one verified change is promoted")
    func guideRequestPromoted() throws {
        let decision = decide()
        #expect(decision.reason == .admittedSingleSelection)
        guard case .promote(let draft, let proof) = decision.action else { Issue.record("not promoted"); return }
        #expect(draft.phrase == guideRequest)
        #expect(draft.step == ExperienceStep.select(control: "All Busses", item: "Output Busses"))
        #expect(proof == .dropdown(evidence()))
        let event = try #require(decision.event(id: "turn-1", at: Date(timeIntervalSince1970: 0)))
        #expect(event.subject == .step(draft))
        #expect(event.outcome == .verified(.dropdown(evidence())))
    }

    /// A dropdown the accessibility tree describes has a name apart from the value it shows. The proof keeps
    /// both as read; the call and the request may name the dropdown by either, and by no other name.
    @Test("a dropdown named by its label or by the value it showed is admitted, by another name it is not")
    func dropdownNamedByLabelOrShownValue() {
        let proof = DropdownEvidence(bundleID: "test.synthetic.editor", windowTitle: "Synthetic Document",
                                     control: "style", controlRole: "AXPopUpButton", section: nil,
                                     valueBefore: "Regular", requestedItem: "Bold", readback: .window("Bold"),
                                     menuClosedByChoice: true)
        func attempts(_ control: String) -> [TurnAdmission.Attempt] {
            preparation + [select(proof, control: control, item: "Bold")]
        }
        let byValue = decide("Select Bold in the Regular dropdown", attempts("Regular"))
        #expect(byValue.reason == .admittedSingleSelection)
        guard case .promote(let draft, _) = byValue.action else { Issue.record("not promoted"); return }
        #expect(draft.step == .select(control: "style", item: "Bold"), "the step keeps the name the proof read")
        #expect(decide("Select Bold in the style dropdown", attempts("style")).reason == .admittedSingleSelection)
        #expect(decide("Select Bold in the Regular dropdown", attempts("Italic")).reason
                == .argumentsDoNotMatchEvidence)
        #expect(decide("Select Bold in the Italic dropdown", attempts("Regular")).reason == .qualifierNotInStep)
    }

    @Test("other single-selection phrasings are promoted, including an item named like a verb")
    func otherSinglePhrasings() {
        #expect(decide("Cambia il filtro da All Busses a Output Busses").reason == .admittedSingleSelection)
        #expect(decide(recallRequest).reason == .admittedSingleSelection)
        #expect(decide("Select Output Busses in the filter, then check the value").reason == .admittedSingleSelection)
        #expect(SelectionGoal.classify("Seleziona Open nel menu Vista", item: "Open", control: "Vista") == .single)
        // A menu the step does not name is not represented: the control here reads its value, "Closed".
        #expect(SelectionGoal.classify("Seleziona Open nel menu Vista", item: "Open", control: "Closed")
                == .unexplained("vista"))
    }

    // MARK: The goal

    @Test("a compound goal with one successful select is not promoted, and its select stays history")
    func compoundGoal() {
        let decision = decide("Seleziona Output Busses e poi esporta la sessione")
        #expect(decision.reason == .compoundGoal)
        #expect(decision.action == .keepAttempt(
            WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!, .verified(.dropdown(evidence()))
        ))
        #expect(decide("Seleziona Output Busses e seleziona Input").reason == .compoundGoal)
    }

    @Test("an uncertain goal, a goal without the item, or no selection clause is not promoted")
    func uncertainGoals() {
        #expect(decide("Seleziona Output Busses e basta").reason == .uncertainGoal)
        #expect(decide("Output Busses. Fatto").reason == .uncertainGoal)
        #expect(decide("Seleziona Input Busses nel filtro").reason == .itemNotInGoal)
        #expect(decide("Verifica il filtro").reason == .uncertainGoal)
    }

    /// A select that really changed the dropdown labelled "Output" from "Speakers" to "Headphones", the
    /// proof a provider would bring back had it acted on a request it should not have. The label is the
    /// accessibility title, so a request that names the Output dropdown names the step's control.
    private func headphones() -> (attempt: TurnAdmission.Attempt, evidence: DropdownEvidence) {
        let proof = DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Output",
                                     control: "Output", controlRole: "AXPopUpButton", section: nil,
                                     valueBefore: "Speakers", requestedItem: "Headphones",
                                     readback: .window("Headphones"), menuClosedByChoice: true)
        return (.select(control: "Output", item: "Headphones", kind: .foundActed, evidence: proof), proof)
    }

    @Test("a negated selection is not promoted by a verified change, and its select stays history")
    func negatedGoal() {
        let (attempt, proof) = headphones()
        let negated = "Non selezionare Headphones nel dropdown Output"
        #expect(SelectionGoal.classify(negated, item: "Headphones", control: "Speakers")
                == .hedged("non selezionare headphones nel dropdown output"))
        let decision = decide(negated, preparation + [attempt])
        #expect(decision.reason == .uncertainGoal)
        let output = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Output")!
        #expect(decision.action == .keepAttempt(output, .verified(.dropdown(proof))))
        for request in ["Don't select Headphones in the Output dropdown", "Seleziona Headphones o Speakers",
                        "Seleziona Headphones, non Speakers", "Seleziona Headphones e non Speakers",
                        "Never pick Headphones"] {
            #expect(decide(request, preparation + [attempt]).reason == .uncertainGoal, "\(request)")
        }
    }

    @Test("two selections in one sentence are not one goal, with or without a sequencing word")
    func twoSelectionsInOneSentence() {
        let (attempt, _) = headphones()
        let listed = "Seleziona Headphones, seleziona Speakers"
        #expect(SelectionGoal.classify(listed, item: "Headphones", control: "Speakers") == .severalSelections)
        #expect(decide(listed, preparation + [attempt]).reason == .compoundGoal)
        #expect(SelectionGoal.classify("Seleziona Headphones seleziona Speakers", item: "Headphones",
                                       control: "Speakers") == .severalSelections)
        #expect(decide("Seleziona Headphones seleziona Speakers", preparation + [attempt]).reason == .compoundGoal)
        #expect(decide("Select Headphones, then select Speakers", preparation + [attempt]).reason == .compoundGoal)
    }

    @Test("the item is named only by its whole words")
    func itemNamedByWholeWords() {
        #expect(SelectionGoal.classify("Seleziona Headphones nel dropdown Output", item: "Head", control: "Speakers")
                == .itemNotNamed)
        #expect(SelectionGoal.classify("Seleziona Track 10", item: "Track 1", control: "Track 2") == .itemNotNamed)
        #expect(SelectionGoal.classify("Seleziona Track 1", item: "Track 1", control: "Track 2") == .single)
    }

    @Test("a negation outside the selection, courtesy, and items named like verbs or negations stay single")
    func validRequestsAroundTheSelection() {
        let (attempt, _) = headphones()
        for request in [
            "Seleziona Headphones nel dropdown Output e verifica che non cambi altro",
            "Osserva la finestra, poi seleziona Headphones nel dropdown Output. Fermati se il dropdown non è univoco.",
            "Non procedere se il dropdown Output non è visibile; seleziona Headphones",
            "Per favore, seleziona Headphones nel dropdown Output",
            "Seleziona Headphones nel dropdown Output, poi dimmi il nuovo valore",
        ] {
            #expect(SelectionGoal.classify(request, item: "Headphones", control: "Output") == .single, "\(request)")
            #expect(decide(request, preparation + [attempt]).reason == .admittedSingleSelection, "\(request)")
            // A dropdown read from pixels is labelled by its value: its name in the selection clause is then
            // not represented. In a guard clause it narrows nothing the step does.
            let pixelLabelled = SelectionGoal.classify(request, item: "Headphones", control: "Speakers")
            #expect(pixelLabelled == (request.hasPrefix("Non procedere") ? .single : .unexplained("output")),
                    "\(request)")
        }
        #expect(SelectionGoal.classify("Seleziona No Output nel menu Uscita", item: "No Output", control: "Uscita")
                == .single)
        #expect(SelectionGoal.classify("Seleziona Select All nel menu Modifica", item: "Select All", control: "Modifica")
                == .single)
    }

    // MARK: The item's identity and direction

    @Test("an item named with a qualifier the step lacks is not learned, nor confirms the generic memory")
    func qualifiedItem() {
        let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
        for (request, qualifier) in [("Seleziona Output Busses 2 nel filtro della scheda Bus", "2"),
                                     ("Seleziona Stereo Output Busses", "stereo"),
                                     ("Select Output Busses 2 in the filter", "2")] {
            #expect(SelectionGoal.classify(request, item: "Output Busses", control: "All Busses")
                    == .qualified(qualifier), "\(request)")
            let decision = decide(request)
            #expect(decision.reason == .qualifierNotInStep, "\(request)")
            #expect(decision.action == .keepAttempt(routing, .verified(.dropdown(evidence()))), "\(request)")
        }
        let generic = TurnAdmission.FollowedExperience(
            id: ExperienceID("experience-1"), step: .select(control: "All Busses", item: "Output Busses"),
            context: routing)
        let qualified = decide("Seleziona Output Busses 2 nel filtro della scheda Bus", followed: generic)
        #expect(qualified.reason == .qualifierNotInStep)
        #expect(qualified.action == .keepAttempt(routing, .verified(.dropdown(evidence()))))
    }

    @Test("the item's own qualified name, or a before value that extends it, is still one selection")
    func qualifiedNamePositive() {
        let two = evidence(item: "Output Busses 2")
        #expect(decide("Seleziona Output Busses 2 nel filtro",
                       preparation + [select(two, item: "Output Busses 2")]).reason == .admittedSingleSelection)
        let fromTwo = evidence(before: "Output Busses 2")
        #expect(decide("Cambia il filtro da Output Busses 2 a Output Busses",
                       preparation + [select(fromTwo, control: "Output Busses 2")]).reason == .admittedSingleSelection)
        for request in ["Seleziona l'opzione Output Busses dal menu Filtro", "Set the filter to Output Busses",
                        "Imposta il filtro su Output Busses", "Select the Output Busses option"] {
            #expect(decide(request).reason == .admittedSingleSelection, "\(request)")
        }
        // An application name is not represented by a select step.
        #expect(decide("Seleziona Output Busses in Pro Tools").reason == .qualifierNotInStep)
    }

    @Test("an item named as the value to change from is not the value the step reached")
    func itemAsOrigin() {
        let fromInput = evidence(before: "Input")
        for request in ["Cambia il filtro da Output Busses a Mix Busses", "Seleziona da Output Busses a Mix Busses",
                        "Switch the filter from Output Busses to Mix Busses"] {
            #expect(SelectionGoal.classify(request, item: "Output Busses", control: "Input")
                    == .itemIsOrigin(LabelText.tokens(request).joined(separator: " ")), "\(request)")
            #expect(decide(request, preparation + [select(fromInput, control: "Input")]).reason == .itemIsOrigin,
                    "\(request)")
        }
        #expect(decide("Cambia Output Busses in All Busses").reason == .itemIsOrigin)
        #expect(decide("Change Output Busses to the All Busses value").reason == .itemIsOrigin)
        #expect(decide("Imposta Output Busses su All Busses").reason == .itemIsOrigin)
        #expect(decide("Set Output Busses to All Busses").reason == .itemIsOrigin)
        #expect(decide("Metti Output Busses al posto di All Busses").reason == .admittedSingleSelection)
        for request in ["Cambia il filtro da All Busses a Output Busses", "Switch the filter from All Busses to Output Busses",
                        "Cambia All Busses in Output Busses", "Seleziona Output Busses dal menu Filtro"] {
            #expect(decide(request).reason == .admittedSingleSelection, "\(request)")
        }
    }

    // MARK: The turn's shape

    @Test("a provider that completed without proof, or without any select, teaches nothing")
    func completedWithoutProof() {
        let fake = decide(nil, preparation + [select(nil, kind: .foundActed)])
        #expect(fake.reason == .noEvidence)
        #expect(fake.action == .nothing)
        let noSelect = decide(nil, preparation)
        #expect(noSelect.reason == .noSelection)
        #expect(noSelect.action == .nothing)
    }

    @Test("batch, act, other tools, errors and several selects are excluded")
    func excludedShapes() {
        #expect(decide(nil, preparation + [.batch, select(evidence())]).reason == .batchUsed)
        #expect(decide(nil, preparation + [.act(ActionArguments(target: "Export", verb: .click), kind: .foundActed, evidence: nil),
                                            select(evidence())]).reason == .severalSteps)
        #expect(decide(nil, preparation + [select(evidence()), .other("close_session")]).reason == .unexpectedTool)
        #expect(decide(nil, [.preparation("describe_scene"), select(evidence())]).reason == .unexpectedTool)
        #expect(decide(nil, preparation + [.failed("observe"), select(evidence())]).reason == .toolFailed)
        #expect(decide(nil, preparation + [.failed("select")]).reason == .toolFailed)
        #expect(decide(nil, preparation + [select(evidence()), select(evidence())]).reason == .severalSelections)
    }

    @Test("a failed, interrupted or handed-over turn is not promoted")
    func endings() {
        #expect(decide(ending: .failed).reason == .turnFailed)
        #expect(decide(ending: .interrupted).reason == .turnInterrupted)
        #expect(decide(ending: .handedToUser).reason == .handedToUser)
        if case .promote = decide(ending: .interrupted).action { Issue.record("an interrupted turn was promoted") }
    }

    // MARK: The proof

    @Test("already set, unreadable and mismatched proof are not promoted; unreadable is no contradiction")
    func proofRules() {
        let context = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
        let already = evidence(before: "Output Busses")
        let noOp = decide(nil, preparation + [select(already, control: "Output Busses")])
        #expect(noOp.reason == .alreadySet)
        #expect(noOp.action == .keepAttempt(context, .noChange(.dropdown(already))))
        let unreadable = evidence(readback: .unreadable(.nothingAtControl))
        let uncertain = decide(nil, preparation + [select(unreadable)])
        #expect(uncertain.reason == .notVerified)
        #expect(uncertain.action == .keepAttempt(context, .uncertain(.readbackUnavailable(.nothingAtControl))))
        #expect(decide(nil, preparation + [select(evidence(), control: "Input")]).reason
                == .argumentsDoNotMatchEvidence)
        let fallback = decide(nil, preparation + [select(evidence(bundle: "pid.4242"))])
        #expect(fallback.reason == .noAttributableContext)
        #expect(fallback.action == .nothing)
    }

    @Test("punctuation inside a label, as in a version number, does not split the request")
    func punctuationInsideLabels() {
        let request = "Seleziona HTML 4.01 Transitional nel menu HTML 4.01 Strict e verifica il nuovo valore. "
            + "Fermati se il controllo non è univoco."
        #expect(SelectionGoal.classify(request, item: "HTML 4.01 Transitional", control: "HTML 4.01 Strict") == .single)
        let recall = "Seleziona HTML 4.01 Transitional nel menu di TextEdit. Prima dimmi se hai un'esperienza "
            + "verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il controllo è presente."
        // "di TextEdit" names the application, which the step does not keep.
        #expect(SelectionGoal.classify(recall, item: "HTML 4.01 Transitional", control: "HTML 4.01 Strict")
                == .unexplained("textedit"))
        #expect(SelectionGoal.classify(recall, item: "HTML 4.01 Transitional", control: "HTML 4.01 Strict",
                                       windows: ["TextEdit Settings"]) == .single)
        #expect(SelectionGoal.classify("Seleziona 10:30 nel menu Orario", item: "10:30", control: "Orario") == .single)
        #expect(SelectionGoal.classify("Seleziona HTML 4.01 Transitional. Esporta.", item: "HTML 4.01 Transitional",
                                       control: "HTML 4.01 Strict") == .compound("esporta"))
    }

    @Test("an argument copied from the scene with its annotation still names the proven control")
    func annotatedArguments() {
        let annotated = decide(nil, preparation + [select(evidence(), control: "All Busses (Routing#2)")])
        #expect(annotated.reason == .admittedSingleSelection)
        #expect(decide(nil, preparation + [select(evidence(), control: "All Busses [on]")]).reason
                == .admittedSingleSelection)
        #expect(decide(nil, preparation + [select(evidence(), control: "All Busses (Mono)")]).reason
                == .admittedSingleSelection)
        #expect(!TurnAdmission.names("Unicode (UTF-16)", "Unicode (UTF-8)"))
        #expect(TurnAdmission.names("Unicode (UTF-8)", "Unicode (UTF-8)"))
        #expect(!TurnAdmission.names("Input", "All Busses"))
    }

    // MARK: Confirmation

    @Test("a verified repetition of the followed step in its context, under a request for that step, confirms it")
    func confirmation() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.select(control: "All Busses", item: "Output Busses")
        let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: routing)
        let confirmed = decide("Seleziona Output Busses nel filtro", followed: followed)
        #expect(confirmed.reason == .confirmsFollowedExperience)
        #expect(confirmed.action == .confirm(remembered, .dropdown(evidence())))
        let elsewhere = TurnAdmission.FollowedExperience(
            id: remembered, step: step, context: WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Mix")!)
        #expect(decide(followed: elsewhere).reason == .admittedSingleSelection)
        let unconfirmed = TurnAdmission.FollowedExperience(id: remembered, step: step)
        #expect(decide(followed: unconfirmed).reason == .admittedSingleSelection)
        #expect(decide(ending: .interrupted, followed: followed).reason == .turnInterrupted)
    }

    // MARK: Contradiction

    @Test("several steps never promote or confirm, but one reading of another value still contradicts the memory")
    func contradictionAmongSeveralSteps() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.select(control: "All Busses", item: "Output Busses")
        let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: routing)
        let contradicted = select(evidence(readback: .window("All Busses")))
        let otherReading = select(evidence(readback: .window("Input")))
        let unreadable = select(evidence(readback: .unreadable(.nothingAtControl)))
        let verified = select(evidence())
        let click = TurnAdmission.Attempt.act(ActionArguments(target: "Close", verb: .click), kind: .foundActed,
                                              evidence: nil)
        let elsewhere = select(DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Mix",
                                                control: "All Busses", controlRole: "AXPopUpButton", section: nil,
                                                valueBefore: "All Busses", requestedItem: "Output Busses",
                                                readback: .window("Output Busses"), menuClosedByChoice: true))
        let expected = TurnAdmission.Action.contradict(remembered, .readbackShowed("All Busses"))
        for attempts in [[contradicted, click], [click, contradicted], [contradicted, contradicted],
                         [contradicted, unreadable], [unreadable, contradicted], [contradicted, elsewhere]] {
            let decision = decide(nil, preparation + attempts, followed: followed)
            #expect(decision.reason == .contradictsFollowedExperience, "\(attempts)")
            #expect(decision.action == expected, "\(attempts)")
        }
        for attempts in [[contradicted, verified], [verified, contradicted], [contradicted, otherReading],
                         [verified, click], [unreadable, click]] {
            let decision = decide(nil, preparation + attempts, followed: followed)
            #expect(decision.action == .nothing, "\(attempts)")
        }
        #expect(decide(nil, preparation + [contradicted, click]).action == .nothing, "no followed memory")
        let mix = TurnAdmission.FollowedExperience(id: remembered, step: step,
                                                   context: WindowContext(bundleID: "test.synthetic.mixer",
                                                                          windowTitle: "Mix")!)
        #expect(decide(nil, preparation + [contradicted, click], followed: mix).action == .nothing,
                "a reading in another window contradicts nothing")
    }

    @Test("another value after following a remembered step contradicts that memory, and only that one")
    func contradiction() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep.select(control: "All Busses", item: "Output Busses")
        let other = evidence(readback: .window("All Busses"))
        let attempts = preparation + [select(other)]
        let followed = decide(nil, attempts, followed: TurnAdmission.FollowedExperience(id: remembered, step: step))
        #expect(followed.reason == .contradictsFollowedExperience)
        #expect(followed.action == .contradict(remembered, .readbackShowed("All Busses")))
        let unrelated = TurnAdmission.FollowedExperience(
            id: remembered, step: ExperienceStep.select(control: "Inputs", item: "Mono"))
        guard case .keepAttempt = decide(nil, attempts, followed: unrelated).action else {
            Issue.record("an unrelated memory was contradicted"); return
        }
        guard case .keepAttempt(_, .contradicted) = decide(nil, attempts).action else {
            Issue.record("a readback of another value without a followed memory was not kept"); return
        }
        let unreadable = decide(nil, preparation + [select(evidence(readback: .unreadable(.windowResized)))],
                                followed: TurnAdmission.FollowedExperience(id: remembered, step: step))
        #expect(unreadable.reason == .notVerified)
    }
}
