//
//  RouteEarningTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
@testable import Memory
import Testing

/// A route is a belief: only a proof may create one and a contradiction retracts it. These tests
/// assert the two decisions that law needs, whether a turn earned a procedure and whether a user turn
/// contradicts the last one, against the real turns that minted the garbage.
@Suite("Route earning")
struct RouteEarningTests {

    private func outcome(_ tool: String, _ kind: ActOutcomeKind) -> RouteEarning.Outcome {
        RouteEarning.Outcome(tool: tool, kind: kind)
    }

    // MARK: The corpus as data

    @Test("every case carries provenance and a reason")
    func provenance() throws {
        let corpus = try RouteCorpus.load()
        #expect(corpus.schema == 1)
        var ids = Set<String>()
        for turn in corpus.turns {
            #expect(ids.insert(turn.id).inserted, "duplicate case id \(turn.id)")
            #expect(!turn.why.isEmpty && !turn.answer.isEmpty && turn.steps > 0 && !turn.tape.isEmpty, Comment(rawValue: turn.id))
            #expect(turn.outcomes.count == turn.tape.count, "\(turn.id): an unknown outcome kind in the tape")
            #expect(!turn.provenance.isEmpty, Comment(rawValue: turn.id))
            for entry in turn.provenance {
                #expect(["session", "live-store", "derived"].contains(entry.source), Comment(rawValue: turn.id))
                #expect(!entry.quote.isEmpty, Comment(rawValue: turn.id))
            }
        }
        for correction in corpus.corrections {
            #expect(ids.insert(correction.id).inserted, "duplicate case id \(correction.id)")
            #expect(!correction.why.isEmpty && !correction.provenance.isEmpty, Comment(rawValue: correction.id))
        }
    }

    @Test("the corpus covers both directions in both languages")
    func bothDirections() throws {
        let corpus = try RouteCorpus.load()
        #expect(corpus.turns.filter { $0.expected == .withheld }.count >= 3)
        #expect(corpus.turns.filter { $0.expected == .recorded }.count >= 3)
        #expect(corpus.corrections.filter(\.isCorrection).count >= 3)
        #expect(corpus.corrections.filter { !$0.isCorrection }.count >= 3)
        #expect(corpus.corrections.contains { $0.language == "it" && $0.isCorrection })
        #expect(corpus.corrections.contains { $0.language == "it" && !$0.isCorrection })
    }

    // MARK: What the engine decides

    @Test("every real turn gets the verdict it deserved")
    func verdicts() throws {
        for turn in try RouteCorpus.load().turns {
            #expect(turn.recorded == (turn.expected == .recorded), "\(turn.id) (\(turn.phrase)): \(turn.why)")
        }
    }

    @Test("each turn is caught by the guard the corpus names")
    func guards() throws {
        for turn in try RouteCorpus.load().turns {
            switch turn.caughtBy {
                case .outcomes:
                    guard case .withheld = turn.outcomeVerdict else {
                        Issue.record("\(turn.id): the outcome span must withhold this turn: \(turn.why)")
                        continue
                    }
                case .answer:
                    guard case .earned = turn.outcomeVerdict else {
                        Issue.record("\(turn.id): its outcomes were clean; this case tests the answer guard")
                        continue
                    }
                    #expect(!turn.answerEarns, "\(turn.id): the answer guard must catch this turn: \(turn.why)")
                case .none:
                    guard case .earned = turn.outcomeVerdict else {
                        Issue.record("\(turn.id): a genuine success was withheld by the outcome span: \(turn.why)")
                        continue
                    }
                    #expect(turn.answerEarns, "\(turn.id): a genuine success was withheld by the answer guard: \(turn.why)")
            }
        }
    }

    @Test("every real correction is seen and every ordinary turn is not")
    func corrections() throws {
        for correction in try RouteCorpus.load().corrections {
            let got = RouteEarning.correction(in: correction.text) != nil
            #expect(got == correction.isCorrection, "\(correction.id) (\(correction.text)): \(correction.why)")
        }
    }

    @Test("a correction names its trigger")
    func trigger() {
        let correction = RouteEarning.correction(in: "you went to next, not previous")
        #expect(correction?.trigger == "you went")
        #expect(correction?.text == "you went to next, not previous")
    }

    // MARK: The span

    @Test("the span starts at the first stored step")
    func span() {
        let tape = [outcome("act", .ambiguous), outcome("act", .foundActed), outcome("act", .foundActed)]
        #expect(RouteEarning.span(of: tape, steps: 2).count == 2)
        #expect(RouteEarning.span(of: tape, steps: 3).count == 3)
    }

    @Test("a structural miss inside the span withholds and names what went wrong")
    func structuralMiss() {
        let tape = [outcome("act", .foundActed), outcome("act", .honestMiss), outcome("act", .foundActed)]
        guard case .withheld(let why) = RouteEarning.verdict(over: tape) else {
            Issue.record("a miss inside the span must withhold")
            return
        }
        #expect(why.contains("honest_miss"))
    }

    @Test("an unverified step withholds")
    func unverified() {
        let tape = [outcome("act", .foundActed), outcome("act", .actedUnverified)]
        guard case .withheld = RouteEarning.verdict(over: tape) else {
            Issue.record("an unverified effect is not a proof of success")
            return
        }
    }

    @Test("a refusal anywhere withholds, even off a structural tool")
    func refusal() {
        let tape = [outcome("act", .foundActed), outcome("send_message", .refused), outcome("act", .foundActed)]
        guard case .withheld = RouteEarning.verdict(over: tape) else {
            Issue.record("the engine declined something the user asked for")
            return
        }
    }

    @Test("a non-structural miss does not condemn the route")
    func nonStructural() {
        let tape = [outcome("act", .foundActed), outcome("resolve_page", .honestMiss), outcome("act", .foundActed)]
        guard case .earned = RouteEarning.verdict(over: tape) else {
            Issue.record("an infrastructure miss is not a route failure")
            return
        }
    }

    @Test("one step is not a procedure")
    func oneStep() {
        guard case .withheld = RouteEarning.verdict(over: [outcome("act", .foundActed)]) else {
            Issue.record("a single act is an experience, not a route")
            return
        }
    }

    @Test("an earned verdict carries its proof")
    func proof() {
        let tape = [outcome("act", .foundActed), outcome("run_menu", .foundActed)]
        guard case .earned(let proof) = RouteEarning.verdict(over: tape) else {
            Issue.record("two clean acts earn a route")
            return
        }
        #expect(proof.contains("2"))
    }

    @Test("the outcome kind of a result is read off its head")
    func outcomeKind() {
        #expect(RouteEarning.outcomeKind(ofResult: "found_acted: clicked 'Export'") == .foundActed)
        #expect(RouteEarning.outcomeKind(ofResult: "Scene of Premiere\n- Export") == nil)
    }

    // MARK: The answer guard

    @Test("an answer that claims the work is fine")
    func claims() {
        #expect(RouteEarning.answerEarnsARoute("I've switched to the **Color** page. You can now use the color wheels."))
        #expect(RouteEarning.answerEarnsARoute("The output for Audio 1_L has been successfully changed to Ron 4 (Stereo)."))
        #expect(RouteEarning.answerEarnsARoute("Fatto, ho aperto la cartella Documenti."))
    }

    @Test("an answer that hands the work back does not")
    func handsBack() {
        #expect(!RouteEarning.answerEarnsARoute("…, here is how you can set it:\n1. Increase Temp"))
        #expect(!RouteEarning.answerEarnsARoute("You can easily apply the yellow/warm look yourself in a few clicks:"))
        #expect(!RouteEarning.answerEarnsARoute("I can't drag the color wheels; they are GPU-rendered widgets."))
        #expect(!RouteEarning.answerEarnsARoute("Ecco come puoi impostare il colore: 1. aumenta la temperatura"))
    }
}
