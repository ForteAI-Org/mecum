import XCTest
@testable import LocatorCore

/// Issue 14. The sweep finds a knee; the freeze rule REFUSES to move it. The refusal is the feature —
/// without it "re-derive from the harness" becomes "tune until green" (ADR 0011).
final class HarnessSweepTests: XCTestCase {

    private func sweep(_ name: String, _ pts: [(Double, Double)], _ dir: SweepScore = .minimise,
                       corpus: [String] = ["t1"]) -> SweepResult {
        SweepResult(parameter: name, direction: dir,
                    points: pts.map { SweepPoint(value: $0.0, score: $0.1, n: 100) }, corpus: corpus)
    }

    // MARK: the knee

    func testTheKneeIsTheLastSettingThatStillBuysSomething() {
        // Shape of a real K sweep: early-settle collapses from K=1 to K=2, then barely moves.
        let s = sweep("settle.K", [(1, 0.40), (2, 0.08), (3, 0.06), (4, 0.05)])
        XCTAssertEqual(s.knee()?.value, 2)
    }

    func testTheKneeIsNotTheOptimum() {
        // The optimum of a minimised score is always the extreme — K=4 settles early least often
        // because it barely settles at all. Taking it is how "measured" becomes degenerate.
        let s = sweep("settle.K", [(1, 0.40), (2, 0.08), (3, 0.06), (4, 0.05)])
        XCTAssertNotEqual(s.knee()?.value, 4)
    }

    func testAFlatCurveHasNoKnee() {
        // A parameter that changes nothing has not earned a value, and saying so beats inventing one.
        XCTAssertNil(sweep("restless.floor", [(5, 0.2), (10, 0.2), (15, 0.2), (20, 0.2)]).knee())
    }

    func testTooFewPointsIsNotASweep() {
        XCTAssertNil(sweep("settle.K", [(1, 0.4), (2, 0.1)]).knee())
    }

    func testMaximisedScoresFindTheirKneeToo() {
        // Jaccard separation: more is better.
        let s = sweep("identity.jaccard", [(0.4, 2.0), (0.5, 6.5), (0.6, 7.3), (0.7, 7.4)], .maximise)
        XCTAssertEqual(s.knee()?.value, 0.6)
    }

    // MARK: the freeze rule

    func testFreezingTakesTheKneeAndRecordsItsProvenance() throws {
        var ledger = FreezeLedger()
        let v = try ledger.freeze(from: sweep("settle.K", [(1, 0.40), (2, 0.08), (3, 0.06), (4, 0.05)]), corpusSize: 4)
        XCTAssertEqual(v.value, 2)
        XCTAssertTrue(v.derivation.contains("knee"))
        XCTAssertEqual(v.corpusSize, 4)
    }

    func testAFrozenNumberRefusesToMoveOnTheSameCorpus() throws {
        var ledger = FreezeLedger()
        let s = sweep("settle.K", [(1, 0.40), (2, 0.08), (3, 0.06), (4, 0.05)])
        _ = try ledger.freeze(from: s, corpusSize: 4)

        // The exact failure this exists to prevent: a change fails the gate, so someone re-sweeps and
        // re-freezes on the same corpus until the number is convenient.
        XCTAssertThrowsError(try ledger.freeze(from: sweep("settle.K", [(1, 0.9), (2, 0.9), (3, 0.9), (4, 0.1)]), corpusSize: 4)) { err in
            guard case let FreezeLedger.Refusal.alreadyFrozen(p, _, v, n)? = err as? FreezeLedger.Refusal else {
                return XCTFail("expected alreadyFrozen, got \(err)")
            }
            XCTAssertEqual(p, "settle.K"); XCTAssertEqual(v, 2); XCTAssertEqual(n, 4)
            XCTAssertTrue("\(err)".contains("never because a change would otherwise fail"))
        }
        XCTAssertEqual(ledger.frozen["settle.K"]?.value, 2, "the frozen value must be untouched by a refused re-freeze")
    }

    func testAGrownCorpusMayReDerive() throws {
        var ledger = FreezeLedger()
        _ = try ledger.freeze(from: sweep("settle.K", [(1, 0.40), (2, 0.08), (3, 0.06), (4, 0.05)]), corpusSize: 4)
        let again = try ledger.freeze(from: sweep("settle.K", [(1, 0.50), (2, 0.30), (3, 0.05), (4, 0.04)]), corpusSize: 9)
        XCTAssertEqual(again.value, 3, "a bigger corpus is the legitimate reason to move a frozen number")
    }

    func testABudgetIsP95TimesOnePointTwo() throws {
        var ledger = FreezeLedger()
        let v = try ledger.freezeBudget(parameter: "pull.window.p95", baselineP95: 250, corpus: ["t1"], corpusSize: 1)
        XCTAssertEqual(v.value, 300, accuracy: 0.0001)
        XCTAssertTrue(v.derivation.contains("p95"))
    }

    func testABudgetIsAlsoFrozenAgainstConvenientReDerivation() throws {
        var ledger = FreezeLedger()
        _ = try ledger.freezeBudget(parameter: "pull.window.p95", baselineP95: 250, corpus: ["t1"], corpusSize: 1)
        XCTAssertThrowsError(try ledger.freezeBudget(parameter: "pull.window.p95", baselineP95: 900, corpus: ["t1"], corpusSize: 1))
        XCTAssertEqual(ledger.frozen["pull.window.p95"]?.value, 300)
    }

    func testAFlatSweepCannotBeFrozen() {
        var ledger = FreezeLedger()
        XCTAssertThrowsError(try ledger.freeze(from: sweep("x", [(1, 0.2), (2, 0.2), (3, 0.2)]), corpusSize: 5)) { err in
            XCTAssertTrue("\(err)".contains("no knee"))
        }
    }

    // MARK: the falsification door

    func testRetractionNeedsAWrittenReason() {
        var ledger = FreezeLedger(frozen: ["settle.K": .init(parameter: "settle.K", value: 2,
                                                             derivation: "knee", corpus: ["t1"], corpusSize: 4)])
        XCTAssertFalse(ledger.retract(parameter: "settle.K", becauseRuleFalsified: "nope"),
                       "a one-word excuse is not a falsification")
        XCTAssertNotNil(ledger.frozen["settle.K"])
        XCTAssertTrue(ledger.retract(parameter: "settle.K",
                                     becauseRuleFalsified: "K=2 fires early on Premiere's async render completion"))
        XCTAssertNil(ledger.frozen["settle.K"])
    }
}
