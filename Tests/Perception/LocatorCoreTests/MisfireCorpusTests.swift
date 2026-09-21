import XCTest
@testable import LocatorCore

/// The misfire corpus is DATA, and these tests are what make it trustworthy data.
///
/// The recall path's failure history lived in session transcripts: the phrase Ron said, what fired,
/// and whether it was right. `Fixtures/misfire-corpus.json` turns that into a fixture, and the suite
/// below asserts three things about it — that every case is attributable to a source, that both
/// directions are represented (a corpus of only failures would push the next fix into refusing
/// everything), and that the recorded `today` column is what the engine ACTUALLY answers.
///
/// The last one is the load-bearing test. A regression corpus whose baseline was written from memory
/// is a corpus that proves nothing; this one is measured, so if `imitate` changes and the file does
/// not, the file loses.
final class MisfireCorpusTests: XCTestCase {
    private func corpus() throws -> MisfireCorpus { try MisfireCorpus.load() }

    // MARK: the corpus as data

    func testEveryCaseCarriesProvenanceAndAReason() throws {
        let c = try corpus()
        XCTAssertEqual(c.schema, 1)
        XCTAssertFalse(c.cases.isEmpty)
        var ids = Set<String>()
        for k in c.cases {
            XCTAssertTrue(ids.insert(k.id).inserted, "duplicate case id \(k.id)")
            XCTAssertFalse(k.input.isEmpty, "\(k.id): no input phrase")
            XCTAssertFalse(k.why.isEmpty, "\(k.id): a verdict without a reason is an opinion")
            XCTAssertFalse(k.memory.phrase.isEmpty, "\(k.id): no remembered phrase to generalise from")
            XCTAssertFalse(k.memory.args.isEmpty, "\(k.id): the remembered call has no arguments")
            XCTAssertFalse(k.provenance.isEmpty,
                           "\(k.id): a disputed case must be re-checkable — record where it came from")
            for p in k.provenance {
                XCTAssertTrue(["session", "live-store", "measurement", "derived"].contains(p.source),
                              "\(k.id): unknown provenance source '\(p.source)'")
                XCTAssertFalse(p.ref.isEmpty, "\(k.id): provenance with no ref")
                XCTAssertFalse(p.quote.isEmpty, "\(k.id): provenance with nothing quoted")
            }
        }
    }

    /// `fire` means tool + arguments; `abstain` means neither. A decision that carries both, or
    /// neither, cannot be asserted against.
    func testEveryDecisionIsWellFormed() throws {
        for k in try corpus().cases {
            for (label, d) in [("expected", k.expected), ("today", k.today)] {
                switch d.decision {
                case .fire:
                    XCTAssertNotNil(d.tool, "\(k.id).\(label): fires without naming a tool")
                    XCTAssertFalse(d.args?.isEmpty ?? true, "\(k.id).\(label): fires with no arguments")
                case .abstain:
                    XCTAssertNil(d.tool, "\(k.id).\(label): abstains but names a tool")
                    XCTAssertNil(d.args, "\(k.id).\(label): abstains but carries arguments")
                }
            }
            switch k.verdict {
            case .wrong:
                XCTAssertEqual(k.expected.decision, .abstain, "\(k.id): a wrong case must expect abstention")
            case .correct:
                XCTAssertEqual(k.expected.decision, .fire, "\(k.id): a correct case must keep firing")
            case .watch:
                XCTAssertEqual(k.today.decision, .abstain, "\(k.id): a watch case is one that misses today")
                XCTAssertEqual(k.expected.decision, .fire, "\(k.id): a watch case is one we WANT to fire")
            }
        }
    }

    /// Both directions, with real weight on each side. The wrong half is the bug; the correct half is
    /// what stops the fix from becoming "refuse everything".
    func testBothClassesAreRepresented() throws {
        let cases = try corpus().cases
        let wrong = cases.filter { $0.verdict == .wrong }
        let correct = cases.filter { $0.verdict == .correct }
        XCTAssertGreaterThanOrEqual(wrong.count, 5, "not enough wrong substitutions to be a regression suite")
        XCTAssertGreaterThanOrEqual(correct.count, 5, "not enough correct substitutions to keep a fix honest")
        let wrongKinds = Set(wrong.map(\.classKind))
        XCTAssertTrue(wrongKinds.contains("deictic"), "the pronoun class is the reason this corpus exists")
        XCTAssertTrue(wrongKinds.contains("junk"), "the junk-token class ('continue') is missing")
        let correctKinds = Set(correct.map(\.classKind))
        XCTAssertTrue(correctKinds.contains("exact-replay"), "the zero-substitution replay must be protected")
        XCTAssertTrue(correctKinds.contains("app-swap") || correctKinds.contains("entity-swap"),
                      "at least one LEGITIMATE substitution must be protected")
    }

    /// Ron speaks both languages, and the known trap is Italian: an enclitic pronoun fuses into the
    /// verb ("aprilo" = "open it") and the part-of-speech check tags the whole word as a Noun.
    func testItalianPhrasingsAreIncluded() throws {
        let italian = try corpus().cases.filter { $0.language == "it" }
        XCTAssertGreaterThanOrEqual(italian.count, 2)
        XCTAssertTrue(italian.contains { $0.verdict == .wrong && $0.classKind == "deictic" },
                      "the Italian clitic deictic is the case a Pronoun-only gate cannot see")
    }

    // MARK: the corpus as a measurement

    /// THE HONESTY TEST. Every `today` column is replayed against the live `imitate` implementation.
    /// It passes as of the corpus's `measured` date, which means it goes RED the moment recall's
    /// behaviour changes — deliberately: the ticket that changes recall (04) is the ticket that owns
    /// updating this file, and it cannot do so by accident.
    func testCorpusIsFaithfulToTodaysEngine() throws {
        let c = try corpus()
        for k in c.cases {
            let got = k.askRecall()
            XCTAssertEqual(got.decision, k.today.decision,
                           "\(k.id): corpus says recall \(k.today.decision) today, engine says \(got.decision) — corpus measured \(c.measured)")
            if k.today.decision == .fire {
                XCTAssertEqual(got.tool, k.today.tool, "\(k.id): fires a different tool than recorded")
                XCTAssertEqual(got.args, k.today.args, "\(k.id): fires different arguments than recorded")
            }
        }
    }

    /// Every case seen in the FIELD is still measured against what the field actually saw — which is
    /// what lets a fix be proven against production history instead of against a story about it. The
    /// two verdicts now diverge, deliberately: a field case judged `correct` must still reproduce its
    /// call exactly, while a field MISFIRE must no longer reproduce (that is ticket 04's win), and its
    /// recorded call is kept as the thing recall now refuses.
    func testFieldObservationsAreStillMeasuredAgainstTheField() throws {
        var reproduced = 0, refused = 0
        for k in try corpus().cases {
            guard let observed = k.observed, let tool = observed.tool, let args = observed.args else { continue }
            switch k.verdict {
            case .correct:
                XCTAssertEqual(k.today.decision, .fire, "\(k.id): the field saw a call; offline recall refuses it")
                XCTAssertEqual(k.today.tool, tool, "\(k.id): offline tool differs from the field's")
                XCTAssertEqual(k.today.args, args, "\(k.id): offline arguments differ from the field's")
                reproduced += 1
            case .wrong:
                XCTAssertEqual(k.today.decision, .abstain,
                               "\(k.id): the field's misfire still fires — the gate did not close it")
                XCTAssertNotEqual(k.expected.args, args, "\(k.id): a misfire's call cannot also be expected")
                refused += 1
            case .watch:
                continue
            }
        }
        XCTAssertGreaterThanOrEqual(reproduced + refused, 8,
                                    "most of the corpus should be field-anchored, not theory")
        XCTAssertGreaterThanOrEqual(refused, 3, "the three field misfires are the reason this corpus exists")
    }

    /// TICKET 04's ACCEPTANCE BAR, as one test over the whole corpus: every case the corpus judged
    /// `wrong` must abstain, and every case it judged `correct` must still fire with exactly the
    /// recorded arguments. Both halves matter — a fix that only satisfied the first half would be
    /// "refuse everything", which the corpus exists to catch.
    func testEveryWrongCaseAbstainsAndEveryCorrectCaseFires() throws {
        var wrong = 0, correct = 0
        for k in try corpus().cases {
            switch k.verdict {
            case .wrong:
                wrong += 1
                XCTAssertEqual(k.askRecall(), MisfireCorpus.Decision(decision: .abstain, tool: nil, args: nil),
                               "\(k.id): recall must not fire — \(k.why)")
            case .correct:
                correct += 1
                XCTAssertEqual(k.askRecall(), k.expected,
                               "\(k.id): a legitimate substitution stopped firing — \(k.why)")
            case .watch:
                continue
            }
        }
        XCTAssertGreaterThanOrEqual(wrong, 5)
        XCTAssertGreaterThanOrEqual(correct, 5)
    }

    /// The case that started the whole effort, as its own named test. It fired `launch_app(app: "it")`
    /// in the field on 2026-08-12 and offline until the gate landed; now it abstains, and says so.
    func testThePronounCaseAbstains() throws {
        let k = try XCTUnwrap(try corpus().cases.first { $0.id == "deictic-it-en" })
        XCTAssertEqual(k.askRecall(), MisfireCorpus.Decision(decision: .abstain, tool: nil, args: nil),
                       "\"can you open it\" must never become launch_app(app: \"it\") again")
        guard case .abstain(let a) = k.askRecallAnswer() else { return XCTFail("expected an abstention") }
        XCTAssertEqual(a.refused, k.memory.phrase, "the memory it refused is named")
        XCTAssertNotNil(a.narration, "and the refusal is narratable — story 5")
        XCTAssertEqual(k.observed?.args, ["app": "it"], "the field's call stays on the record")
    }

    /// Story 5: "seen but not trusted" must be distinguishable from "never seen it", and only the first
    /// is owed a sentence. Every misfire the gate REFUSES narrates why; a phrase recall simply had no
    /// candidate for stays silent.
    func testRefusalsAreNarratedAndSilenceIsReservedForTheUnknown() throws {
        var narrated = 0, silent = 0
        for k in try corpus().cases where k.verdict == .wrong {
            guard case .abstain(let a) = k.askRecallAnswer() else {
                return XCTFail("\(k.id): expected an abstention")
            }
            if a.refused == nil {
                silent += 1
                XCTAssertNil(a.narration, "\(k.id): nothing was refused, so there is nothing to say")
            } else {
                narrated += 1
                XCTAssertEqual(a.refused, k.memory.phrase, "\(k.id): the refusal names the memory it refused")
                XCTAssertNotNil(a.narration)
                XCTAssertTrue(a.reason.contains(k.memory.phrase),
                              "\(k.id): the reason has to say which memory it came from")
            }
        }
        XCTAssertGreaterThanOrEqual(narrated, 5, "the gate's refusals are the ones worth narrating")
        XCTAssertGreaterThanOrEqual(silent, 1,
                                    "and 'close premiere' never had a candidate to refuse — no sentence owed")
    }

    /// The corpus has to be readable by a human too, and a table that has drifted from the data is
    /// worse than no table.
    func testTheHumanTableCoversEveryCase() throws {
        let doc = try String(contentsOf: MisfireCorpus.docURL, encoding: .utf8)
        for k in try corpus().cases {
            XCTAssertTrue(doc.contains(k.id), "docs/misfire-corpus.md does not list case \(k.id)")
            XCTAssertTrue(doc.contains(k.input), "docs/misfire-corpus.md does not show the phrase \"\(k.input)\"")
        }
    }
}
