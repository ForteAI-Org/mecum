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

    private let guideRequest = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."
    private let recallRequest = "Seleziona Output Busses nel filtro della scheda Bus in Pro Tools. Prima dimmi se "
        + "hai un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
        + "controllo è presente."
    private let preparation: [TurnAdmission.Attempt] = [
        .preparation("status"), .preparation("windows"), .preparation("open_session"), .preparation("observe"),
    ]

    private func evidence(
        before  : String = "All Busses",
        readback: DropdownReadback = .window("Output Busses"),
        bundle  : String = "test.synthetic.mixer"
    ) -> DropdownEvidence {
        DropdownEvidence(bundleID: bundle, windowTitle: "Synthetic Routing", control: before,
                         controlRole: "AXPopUpButton", section: nil, valueBefore: before,
                         requestedItem: "Output Busses", readback: readback, menuClosedByChoice: true)
    }

    private func select(
        _ proof : DropdownEvidence?,
        control : String = "All Busses",
        kind    : ActOutcomeKind? = nil
    ) -> TurnAdmission.Attempt {
        .select(control: control, item: "Output Busses",
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
        #expect(draft.step == ExperienceStep(tool: .select, control: "All Busses", item: "Output Busses"))
        #expect(proof == evidence())
        let event = try #require(decision.event(id: "turn-1", at: Date(timeIntervalSince1970: 0)))
        #expect(event.subject == .step(draft))
        #expect(event.outcome == .verified(evidence()))
    }

    @Test("other single-selection phrasings are promoted, including an item named like a verb")
    func otherSinglePhrasings() {
        #expect(decide("Cambia il filtro da All Busses a Output Busses").reason == .admittedSingleSelection)
        #expect(decide(recallRequest).reason == .admittedSingleSelection)
        #expect(decide("Select Output Busses in the filter, then check the value").reason == .admittedSingleSelection)
        #expect(SelectionGoal.classify("Seleziona Open nel menu Vista", item: "Open", control: "Closed") == .single)
    }

    // MARK: The goal

    @Test("a compound goal with one successful select is not promoted, and its select stays history")
    func compoundGoal() {
        let decision = decide("Seleziona Output Busses e poi esporta la sessione")
        #expect(decision.reason == .compoundGoal)
        #expect(decision.action == .keepAttempt(
            WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!, .verified(evidence())
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
        #expect(decide(nil, preparation + [.act(.foundActed), select(evidence())]).reason == .actUsed)
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
        #expect(noOp.action == .keepAttempt(context, .noChange(already)))
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
        #expect(SelectionGoal.classify(recall, item: "HTML 4.01 Transitional", control: "HTML 4.01 Strict") == .single)
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

    @Test("a verified repetition of the followed step in its context confirms that memory, whatever the wording")
    func confirmation() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep(tool: .select, control: "All Busses", item: "Output Busses")
        let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
        let followed = TurnAdmission.FollowedExperience(id: remembered, step: step, context: routing)
        let confirmed = decide("Seleziona Output Busses nel filtro della scheda Bus", followed: followed)
        #expect(confirmed.reason == .confirmsFollowedExperience)
        #expect(confirmed.action == .confirm(remembered, evidence()))
        let elsewhere = TurnAdmission.FollowedExperience(
            id: remembered, step: step, context: WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Mix")!)
        #expect(decide(followed: elsewhere).reason == .admittedSingleSelection)
        let unconfirmed = TurnAdmission.FollowedExperience(id: remembered, step: step)
        #expect(decide(followed: unconfirmed).reason == .admittedSingleSelection)
        #expect(decide(ending: .interrupted, followed: followed).reason == .turnInterrupted)
    }

    // MARK: Contradiction

    @Test("another value after following a remembered step contradicts that memory, and only that one")
    func contradiction() {
        let remembered = ExperienceID("experience-1")
        let step = ExperienceStep(tool: .select, control: "All Busses", item: "Output Busses")
        let other = evidence(readback: .window("All Busses"))
        let attempts = preparation + [select(other)]
        let followed = decide(nil, attempts, followed: TurnAdmission.FollowedExperience(id: remembered, step: step))
        #expect(followed.reason == .contradictsFollowedExperience)
        #expect(followed.action == .contradict(remembered, .readbackShowed("All Busses")))
        let unrelated = TurnAdmission.FollowedExperience(
            id: remembered, step: ExperienceStep(tool: .select, control: "Inputs", item: "Mono"))
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
