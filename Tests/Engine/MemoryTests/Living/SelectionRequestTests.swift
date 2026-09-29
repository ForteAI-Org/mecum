//
//  SelectionRequestTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The whole request against one verified select, read by `SelectionGoal`, `TurnAdmission` and `Recall`
/// alike. The proof is invented: a dropdown showing "Input" was changed to "Output Busses" in a
/// synthetic routing window. The requests are the ones the step 3 review executed, plus their
/// neighbours, and the positives the rule must keep.
@Suite("A select is learned and recalled only for the whole request it answers")
struct SelectionRequestTests {

    private let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!

    private func proof(control: String = "Input") -> DropdownEvidence {
        DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing", control: control,
                         controlRole: "AXPopUpButton", section: nil, valueBefore: control,
                         requestedItem: "Output Busses", readback: .window("Output Busses"),
                         menuClosedByChoice: true)
    }

    private func decide(_ request: String, control: String = "Input",
                        followed: TurnAdmission.FollowedExperience? = nil) -> TurnAdmission.Decision {
        TurnAdmission.decide(TurnAdmission.Turn(
            request : request,
            attempts: [.preparation("observe"),
                       .select(control: control, item: "Output Busses", kind: .foundActed,
                               evidence: proof(control: control))],
            ending  : .completed,
            followed: followed
        ))
    }

    private func record(control: String = "Input", phrase: String = "Seleziona Output Busses nel filtro")
        -> ExperienceRecord {
        let draft = ExperienceDraft(phrase: phrase, step: .select(control: control, item: "Output Busses"),
                                    context: routing)!
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return ExperienceRecord(id: ExperienceID("experience-1"), draft: draft, createdAt: at, successCount: 1,
                                latestProof: .dropdown(proof(control: control)), lastVerifiedAt: at)
    }

    private func recall(_ request: String, _ record: ExperienceRecord) -> Recall.SuggestionAnswer {
        Recall.suggest(input: request, in: Recall.World(records: [record], sightings: [], context: Recall.Context()))
    }

    private func isSuggested(_ answer: Recall.SuggestionAnswer) -> Bool {
        if case .suggest = answer { true } else { false }
    }

    // MARK: A clause the reader cannot parse hides nothing after it (R1)

    @Test("a negation, a second selection or another item after an unparsed clause still decides the request")
    func laterClauseStillDecides() {
        let learned = "Seleziona Output Busses nel filtro e verifica il nuovo valore. Fermati se il controllo non è univoco."
        let remembered = record(phrase: learned)
        for (request, expected) in [
            ("Filtro: non seleziona Output Busses e verifica il nuovo valore. Fermati se il controllo è univoco.",
             SelectionGoal.Classification.hedged("non seleziona output busses")),
            ("Ciao. Non selezionare Output Busses nel filtro e verifica il nuovo valore. "
                + "Fermati se il controllo non è univoco.", .hedged("non selezionare output busses nel filtro")),
            ("Ciao. Seleziona Output Busses nel filtro, seleziona Input e verifica il nuovo valore.",
             .severalSelections),
            ("Ciao. Seleziona Output Busses 2 nel filtro e verifica il nuovo valore.", .qualified("2")),
            ("Seleziona Mix Busses, non Output Busses nel filtro e verifica il nuovo valore.",
             .hedged("non output busses nel filtro")),
            ("Non toccare Output Busses nel filtro e verifica il nuovo valore. Fermati se il controllo non è univoco.",
             .hedged("non toccare output busses nel filtro")),
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "Input")
            #expect(goal == expected, "\(request)")
            #expect(goal.asksForAnotherStep, "\(request)")
            #expect(decide(request).reason != .admittedSingleSelection, "\(request)")
            #expect(recall(request, remembered) == .abstain(nil, considered: [
                Recall.Consideration(experienceID: ExperienceID("experience-1"), match: nil, verdict: "no match"),
            ]), "\(request)")
        }
    }

    @Test("a request that shares the phrase but is not one selection is history at most, never operational")
    func lexicalMatchIsOnlyHistory() {
        let learned = "Seleziona Output Busses nel filtro e verifica il nuovo valore. Fermati se il controllo non è univoco."
        let remembered = record(phrase: learned)
        for request in [
            "Verifica che il filtro mostri Output Busses, fermati se il controllo non è univoco e verifica il valore",
            "Output Busses nel filtro: verifica il nuovo valore, fermati se il controllo non è univoco.",
            "Ciao. Seleziona Output Busses nel filtro e verifica il nuovo valore. Fermati se il controllo non è univoco.",
        ] {
            let answer = recall(request, remembered)
            #expect(!isSuggested(answer), "\(request)")
            guard case .historical(let suggestion, .goalNotSingle, _) = answer else {
                Issue.record("not kept as history: \(request) → \(answer)"); continue
            }
            #expect(suggestion.match == .partialPhrase || suggestion.match == .exactPhrase)
            #expect(answer.decisionRecord(id: "d", at: Date(), phrase: request, context: nil).verdict == .refused)
            #expect(RecallBriefing(answer, records: [remembered])?.contextLine
                    == "memory context: historical select 'Output Busses' in 'Input' (verified ×1, goalNotSingle)")
        }
    }

    // MARK: Words away from the item that change the request (R2)

    @Test("an avoided, replaced or left item is never the value reached")
    func replacedOrLeftItem() {
        for (request, expected) in [
            ("Evita di selezionare Output Busses", SelectionGoal.Classification.hedged("evita di selezionare output busses")),
            ("Evita di selezionare Output Busses nel filtro", .hedged("evita di selezionare output busses nel filtro")),
            ("Avoid selecting Output Busses", .hedged("avoid selecting output busses")),
            ("Seleziona Mix Busses invece di Output Busses", .itemIsOrigin("seleziona mix busses invece di output busses")),
            ("Seleziona Mix Busses al posto di Output Busses", .itemIsOrigin("seleziona mix busses al posto di output busses")),
            ("Seleziona Mix Busses piuttosto che Output Busses",
             .itemIsOrigin("seleziona mix busses piuttosto che output busses")),
            ("Seleziona Mix Busses anziché Output Busses", .itemIsOrigin("seleziona mix busses anziché output busses")),
            ("Select Mix Busses instead of Output Busses", .itemIsOrigin("select mix busses instead of output busses")),
            ("Select Mix Busses rather than Output Busses", .itemIsOrigin("select mix busses rather than output busses")),
            ("Metti Input al posto di Output Busses", .itemIsOrigin("metti input al posto di output busses")),
            ("Cambia Output Busses con Mix Busses", .itemIsOrigin("cambia output busses con mix busses")),
            ("Cambia Output Busses in Mix Busses", .itemIsOrigin("cambia output busses in mix busses")),
            ("Switch Output Busses for Mix Busses", .itemIsOrigin("switch output busses for mix busses")),
            ("Set Output Busses to Mix Busses", .itemIsOrigin("set output busses to mix busses")),
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "Input")
            #expect(goal == expected, "\(request)")
            #expect(goal.asksForAnotherStep, "\(request)")
            let decision = decide(request)
            #expect(decision.reason != .admittedSingleSelection, "\(request)")
            #expect(decision.action == .keepAttempt(routing, .verified(.dropdown(proof()))), "\(request)")
            #expect(!isSuggested(recall(request, record())), "\(request)")
        }
    }

    /// The requests the 03-r2 review executed against a dropdown that showed "All Busses", the value the
    /// request keeps: each leaves Output Busses, or keeps All Busses in its place.
    static let leavingTheItem: [String] = [
        "Seleziona All Busses invece che Output Busses",
        "Scegli All Busses al posto delle Output Busses",
        "Seleziona All Busses invece delle Output Busses",
        "Seleziona All Busses piuttosto di Output Busses",
        "Switch the filter from the Output Busses",
    ]

    @Test("an origin or a replacement with an article or inflection leaves the item: never learned or offered")
    func leftItemWithArticles() {
        let generic = TurnAdmission.FollowedExperience(id: ExperienceID("experience-1"),
                                                       step: .select(control: "All Busses", item: "Output Busses"),
                                                       context: routing)
        let inflected = [
            "Seleziona All Busses invece dell'Output Busses",
            "Scegli All Busses anziché le Output Busses",
            "Metti All Busses al posto dello Output Busses",
            "Select All Busses instead of the Output Busses",
            "Select All Busses rather than the Output Busses",
            "Choose All Busses in place of the Output Busses",
            "Seleziona All Busses piuttosto che il valore Output Busses",
            "Change the filter from the Output Busses to the value All Busses",
            "Cambia il filtro dal valore Output Busses a All Busses",
            "Cambia Output Busses con il valore All Busses",
        ]
        for request in Self.leavingTheItem + inflected {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "All Busses",
                                              windows: ["Synthetic Routing"])
            #expect(goal == .itemIsOrigin(LabelText.tokens(request).joined(separator: " ")), "\(request) → \(goal)")
            let decision = decide(request, control: "All Busses")
            #expect(decision.reason == .itemIsOrigin, "\(request)")
            #expect(decision.action == .keepAttempt(routing, .verified(.dropdown(proof(control: "All Busses")))),
                    "\(request)")
            if case .confirm = decide(request, control: "All Busses", followed: generic).action {
                Issue.record("confirmed the generic memory: \(request)")
            }
            #expect(recall(request, record(control: "All Busses")) == .abstain(nil, considered: [
                Recall.Consideration(experienceID: ExperienceID("experience-1"), match: nil, verdict: "no match"),
            ]), "\(request)")
        }
    }

    @Test("a replacement word whose direction cannot be read is not a single selection either")
    func replacementWithoutDirection() {
        for (request, expected) in [
            ("Seleziona invece Output Busses", SelectionGoal.Classification.unexplained("invece")),
            ("Seleziona Output Busses piuttosto", .unexplained("piuttosto")),
            ("Select Output Busses instead", .unexplained("instead")),
            ("Seleziona All Busses invece del filtro Output Busses",
             .uncertain("seleziona all busses invece del filtro output busses")),
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "All Busses")
            #expect(goal == expected, "\(request) → \(goal)")
            #expect(decide(request, control: "All Busses").reason != .admittedSingleSelection, "\(request)")
            #expect(!isSuggested(recall(request, record(control: "All Busses"))), "\(request)")
        }
    }

    @Test("the item before the replacement, or after the value left, is still the value reached")
    func replacedValueBeforeOrAfter() {
        for request in [
            "Seleziona Output Busses invece che All Busses",
            "Scegli Output Busses al posto delle All Busses",
            "Seleziona Output Busses piuttosto di All Busses",
            "Select Output Busses instead of the All Busses",
            "Switch the filter from the All Busses to Output Busses",
            "Cambia il filtro dal valore All Busses a Output Busses",
            "Seleziona Output Busses dal menu",
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "All Busses",
                                              windows: ["Synthetic Routing"])
            #expect(goal == .single, "\(request) → \(goal)")
            #expect(decide(request, control: "All Busses").reason == .admittedSingleSelection, "\(request)")
            #expect(isSuggested(recall(request, record(control: "All Busses"))), "\(request)")
        }
    }

    @Test("an unknown word in the selection clause fails closed: never learned, confirmed or suggested")
    func unexplainedWordFailsClosed() {
        let generic = TurnAdmission.FollowedExperience(id: ExperienceID("experience-1"),
                                                       step: .select(control: "Input", item: "Output Busses"),
                                                       context: routing)
        for (request, words) in [
            ("Seleziona Output Busses nel filtro di Track 2", "track 2"),
            ("Seleziona Output Busses nel filtro della scheda Bus", "bus"),
            ("Seleziona Output Busses in Pro Tools", "pro tools"),
            ("Sostituisci Output Busses con Mix Busses nel filtro, poi seleziona Output Busses", nil),
            ("Seleziona Output Busses se possibile", "possibile"),
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: "Input")
            if let words { #expect(goal == .unexplained(words), "\(request)") }
            #expect(goal != .single, "\(request)")
            let decision = decide(request)
            #expect(decision.reason != .admittedSingleSelection, "\(request)")
            if case .promote = decision.action { Issue.record("promoted: \(request)") }
            let followed = decide(request, followed: generic)
            if case .confirm = followed.action { Issue.record("confirmed the generic memory: \(request)") }
            #expect(!isSuggested(recall(request, record())), "\(request)")
        }
        #expect(decide("Seleziona Output Busses nel filtro di Track 2").reason == .qualifierNotInStep)
    }

    // MARK: What stays one selection

    @Test("full names, the control's own name, the window's, courtesy, observing and guards stay one selection")
    func positivesStay() {
        for (request, control) in [
            ("Seleziona Output Busses", "Input"),
            ("Seleziona Output Busses nel filtro", "Input"),
            ("Per favore, seleziona Output Busses nel filtro e verifica il nuovo valore. "
                + "Fermati se il controllo non è univoco.", "Input"),
            ("Osserva la finestra, poi seleziona Output Busses nel menu. Agisci solo se il controllo è presente.",
             "Input"),
            ("Seleziona Output Busses nella finestra Synthetic Routing", "Input"),
            ("Cambia il filtro da All Busses a Output Busses", "All Busses"),
            ("Cambia All Busses in Output Busses", "All Busses"),
            ("Metti Output Busses al posto di All Busses", "All Busses"),
            ("Seleziona Output Busses invece di All Busses", "All Busses"),
            ("Select Output Busses instead of All Busses", "All Busses"),
            ("Imposta il filtro su Output Busses", "Input"),
            ("Set the filter to Output Busses", "Input"),
            ("Select the Output Busses option", "Input"),
            ("Seleziona l'opzione Output Busses dal menu", "Input"),
            ("Seleziona Output Busses nel dropdown Input", "Input"),
        ] {
            let goal = SelectionGoal.classify(request, item: "Output Busses", control: control,
                                              windows: ["Synthetic Routing"])
            #expect(goal == .single, "\(request) → \(goal)")
            #expect(decide(request, control: control).reason == .admittedSingleSelection, "\(request)")
            #expect(isSuggested(recall(request, record(control: control))), "\(request)")
        }
    }

    // MARK: The former demo requests

    @Test("the former demo requests name the Bus tab and Pro Tools, which a select step keeps neither of")
    func formerDemoRequests() {
        let learning = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
            + "Fermati se il controllo non è univoco."
        let recalling = "Seleziona Output Busses nel filtro della scheda Bus in Pro Tools. Prima dimmi se hai "
            + "un’esperienza verificata che può aiutare; poi osserva la finestra attuale e agisci solo se il "
            + "controllo è presente."
        #expect(SelectionGoal.classify(learning, item: "Output Busses", control: "Input") == .unexplained("bus"))
        #expect(SelectionGoal.classify(recalling, item: "Output Busses", control: "Input")
                == .unexplained("bus pro tools"))
        #expect(decide(learning).reason == .qualifierNotInStep)
        let remembered = record(phrase: learning)
        guard case .historical(_, .goalNotSingle, _) = recall(learning, remembered) else {
            Issue.record("a record learned before this rule is operational for its own unrepresented phrase"); return
        }
        #expect(!isSuggested(recall(recalling, remembered)))
    }

    // MARK: Stop as a word, not a guard (R7)

    @Test("stop is a guard only as a condition: 'poi Stop' is a second target, 'stop if' still guards")
    func stopAsTarget() {
        #expect(ClickGoal.classify("Clicca Play e poi Stop", target: "Play") != .single(.click, opens: nil))
        #expect(ClickGoal.classify("Clicca Play. Stop.", target: "Play") != .single(.click, opens: nil))
        #expect(ClickGoal.classify("Right-click Play to open the menu. Stop if it is not unique.", target: "Play")
                == .single(.rightClick, opens: .menu))
        #expect(ClickGoal.classify("Clicca Play. Fermati se non è univoco.", target: "Play") == .single(.click, opens: nil))
        #expect(ToggleGoal.classify("Attiva Mute e poi Stop", control: "Mute") != .single(.on))
        #expect(SelectionGoal.classify("Seleziona Output Busses e poi Stop", item: "Output Busses", control: "Input")
                != .single)
        #expect(ClickGoal.classify("Clicca Stop", target: "Stop") == .single(.click, opens: nil))
    }
}
