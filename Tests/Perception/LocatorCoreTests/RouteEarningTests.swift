import XCTest
@testable import LocatorCore

/// A Route is a Belief (CONTEXT.md), so ADR 0001 governs it: only a Proof may create one, and a
/// Contradiction retracts it. These tests assert the two decisions that law needs — did this turn EARN
/// a procedure, and is this user turn a Contradiction of the last one — against the real turns that
/// minted the garbage (`Fixtures/route-corpus.json`).
final class RouteEarningTests: XCTestCase {

    private func corpus() throws -> RouteCorpus { try RouteCorpus.load() }

    // MARK: the corpus as data

    func testEveryCaseCarriesProvenanceAndAReason() throws {
        let c = try corpus()
        XCTAssertEqual(c.schema, 1)
        var ids = Set<String>()
        for t in c.turns {
            XCTAssertTrue(ids.insert(t.id).inserted, "duplicate case id \(t.id)")
            XCTAssertFalse(t.why.isEmpty, "\(t.id): a verdict without a reason is an opinion")
            XCTAssertFalse(t.answer.isEmpty, "\(t.id): the turn's answer is half the evidence")
            XCTAssertGreaterThan(t.steps, 0, "\(t.id): a route of no steps is not a case")
            XCTAssertFalse(t.tape.isEmpty, "\(t.id): no outcome tape to judge")
            XCTAssertFalse(t.provenance.isEmpty, "\(t.id): a disputed case must be re-checkable")
            for p in t.provenance {
                XCTAssertTrue(["session", "live-store", "derived"].contains(p.source),
                              "\(t.id): unknown provenance source '\(p.source)'")
                XCTAssertFalse(p.quote.isEmpty, "\(t.id): provenance with nothing quoted")
            }
        }
        for k in c.corrections {
            XCTAssertTrue(ids.insert(k.id).inserted, "duplicate case id \(k.id)")
            XCTAssertFalse(k.why.isEmpty, "\(k.id): a verdict without a reason is an opinion")
            XCTAssertFalse(k.provenance.isEmpty, "\(k.id): a disputed case must be re-checkable")
        }
    }

    /// A corpus of only failures would push the fix into withholding everything, and a corpus of only
    /// successes would prove nothing. Both directions must be represented, in both languages.
    func testCorpusCoversBothDirections() throws {
        let c = try corpus()
        XCTAssertGreaterThanOrEqual(c.turns.filter { $0.expected == .withheld }.count, 3)
        XCTAssertGreaterThanOrEqual(c.turns.filter { $0.expected == .recorded }.count, 3)
        XCTAssertGreaterThanOrEqual(c.corrections.filter(\.isCorrection).count, 3)
        XCTAssertGreaterThanOrEqual(c.corrections.filter { !$0.isCorrection }.count, 3)
        XCTAssertTrue(c.corrections.contains { $0.language == "it" && $0.isCorrection })
        XCTAssertTrue(c.corrections.contains { $0.language == "it" && !$0.isCorrection })
    }

    // MARK: what the engine decides

    /// The headline: the three garbage Routes named in the ticket record NOTHING, and the genuine
    /// multi-step successes still record theirs.
    func testEveryRealTurnGetsTheVerdictItDeserved() throws {
        for t in try corpus().turns {
            XCTAssertEqual(t.recorded, t.expected == .recorded,
                           "\(t.id) (“\(t.phrase)”): \(t.why)")
        }
    }

    /// …and it is caught by the guard the corpus says catches it. A withheld turn that only passes
    /// because the OTHER guard fired is a guard that is not doing its job.
    func testEachTurnIsCaughtByTheGuardItNames() throws {
        for t in try corpus().turns {
            switch t.caughtBy {
            case .outcomes:
                guard case .withheld = t.outcomeVerdict else {
                    return XCTFail("\(t.id): the outcome span must withhold this turn — \(t.why)")
                }
            case .answer:
                guard case .earned = t.outcomeVerdict else {
                    return XCTFail("\(t.id): its outcomes were clean — this case exists to test the ANSWER guard")
                }
                XCTAssertFalse(t.answerEarns, "\(t.id): the answer guard must catch this turn — \(t.why)")
            case .none:
                guard case .earned = t.outcomeVerdict else {
                    return XCTFail("\(t.id): a genuine success was withheld by the outcome span — \(t.why)")
                }
                XCTAssertTrue(t.answerEarns, "\(t.id): a genuine success was withheld by the answer guard — \(t.why)")
            }
        }
    }

    func testEveryRealCorrectionIsSeenAndEveryOrdinaryTurnIsNot() throws {
        for k in try corpus().corrections {
            let got = RouteEarning.correction(in: k.text) != nil
            XCTAssertEqual(got, k.isCorrection, "\(k.id) (“\(k.text)”): \(k.why)")
        }
    }

    /// The narration and the stored cause both quote what the user actually said, so a demotion can be
    /// argued with later.
    func testACorrectionNamesItsTrigger() {
        let c = RouteEarning.correction(in: "you went to next, not previous")
        XCTAssertEqual(c?.trigger, "you went")
        XCTAssertEqual(c?.text, "you went to next, not previous")
    }

    // MARK: the span

    /// The span is the outcomes the ROUTE covers, not the turn's whole history: it starts at the first
    /// step the route stores. A false start before that belongs to the model's search, not the procedure.
    func testSpanStartsAtTheFirstStoredStep() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "ambiguous"),
                    RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "act", kind: "found_acted")]
        XCTAssertEqual(RouteEarning.span(of: tape, steps: 2).count, 2)
        XCTAssertEqual(RouteEarning.span(of: tape, steps: 3).count, 3)   // more steps than acts → all of it
    }

    func testAStructuralMissInsideTheSpanWithholds() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "act", kind: "honest_miss"),
                    RouteEarning.Outcome(tool: "act", kind: "found_acted")]
        guard case .withheld(let why) = RouteEarning.verdict(over: tape) else {
            return XCTFail("a miss inside the span must withhold")
        }
        XCTAssertTrue(why.contains("honest_miss"), "the reason must name what went wrong: \(why)")
    }

    /// `acted_unverified` is a failure to VERIFY, and verification is the whole basis of the write.
    func testAnUnverifiedStepWithholds() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "act", kind: "acted_unverified")]
        guard case .withheld = RouteEarning.verdict(over: tape) else {
            return XCTFail("an unverified effect is not a proof of success")
        }
    }

    func testARefusalAnywhereWithholdsEvenOffAStructuralTool() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "send_message", kind: "refused"),
                    RouteEarning.Outcome(tool: "act", kind: "found_acted")]
        guard case .withheld = RouteEarning.verdict(over: tape) else {
            return XCTFail("the engine declined something the user asked for — the goal was not met")
        }
    }

    /// An API probe that missed says the API is off, not that the procedure is wrong. Only the tools a
    /// route is MADE of can condemn it.
    func testANonStructuralMissDoesNotCondemnTheRoute() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "resolve_page", kind: "honest_miss"),
                    RouteEarning.Outcome(tool: "act", kind: "found_acted")]
        guard case .earned = RouteEarning.verdict(over: tape) else {
            return XCTFail("an infrastructure miss is not a route failure")
        }
    }

    func testOneStepIsNotAProcedure() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted")]
        guard case .withheld = RouteEarning.verdict(over: tape) else {
            return XCTFail("a single act is an Experience, not a Route")
        }
    }

    /// The proof is stored on the Route, so any Belief can later be asked what earned it (ADR 0001).
    func testAnEarnedVerdictCarriesItsProof() {
        let tape = [RouteEarning.Outcome(tool: "act", kind: "found_acted"),
                    RouteEarning.Outcome(tool: "run_menu", kind: "found_acted")]
        guard case .earned(let proof) = RouteEarning.verdict(over: tape) else {
            return XCTFail("two clean acts earn a route")
        }
        XCTAssertTrue(proof.contains("2"), "the proof should say how many verified steps earned it: \(proof)")
    }

    // MARK: the answer guard

    func testAnAnswerThatClaimsTheWorkIsFine() {
        XCTAssertTrue(RouteEarning.answerEarnsARoute("I've switched to the **Color** page. You can now use the color wheels."))
        XCTAssertTrue(RouteEarning.answerEarnsARoute("The output for Audio 1_L has been successfully changed to Ron 4 (Stereo)."))
        XCTAssertTrue(RouteEarning.answerEarnsARoute("Fatto — ho aperto la cartella Documenti."))
    }

    func testAnAnswerThatHandsTheWorkBackDoesNot() {
        XCTAssertFalse(RouteEarning.answerEarnsARoute("…, here is how you can set it:\n1. Increase Temp"))
        XCTAssertFalse(RouteEarning.answerEarnsARoute("You can easily apply the yellow/warm look yourself in a few clicks:"))
        XCTAssertFalse(RouteEarning.answerEarnsARoute("I can't drag the color wheels — they are GPU-rendered widgets."))
        XCTAssertFalse(RouteEarning.answerEarnsARoute("Ecco come puoi impostare il colore: 1. aumenta la temperatura"))
    }
}
