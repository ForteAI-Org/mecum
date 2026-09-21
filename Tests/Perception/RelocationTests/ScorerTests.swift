import XCTest
@testable import Relocation
import LocatorCore

final class ScorerTests: XCTestCase {
    let scorer = Scorer()   // spec defaults

    // MARK: Sub-scores

    func testVisualMapping() {
        XCTAssertEqual(scorer.visualSubScore(ncc: 1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(scorer.visualSubScore(ncc: 0.85), 0.0, accuracy: 1e-9)   // == nccMin → 0
        XCTAssertEqual(scorer.visualSubScore(ncc: 0.925), 0.5, accuracy: 1e-9)  // halfway
        XCTAssertEqual(scorer.visualSubScore(ncc: 0.5), 0.0)                    // below floor
        XCTAssertEqual(scorer.visualSubScore(ncc: -0.3), 0.0)
    }

    func testTextScoreNoTextFloor() {
        XCTAssertEqual(scorer.textSubScore(hasText: false, exact: false, fuzzy: 0), 0.5)
        XCTAssertEqual(scorer.textSubScore(hasText: true, exact: true, fuzzy: 0), 1.0)
        XCTAssertEqual(scorer.textSubScore(hasText: true, exact: false, fuzzy: 0.7), 0.7, accuracy: 1e-9)
    }

    func testGeometryGaussian() {
        XCTAssertEqual(scorer.geometrySubScore(distanceFraction: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(scorer.geometrySubScore(distanceFraction: 0.08), exp(-0.5), accuracy: 1e-6)  // d == σ
    }

    func testClassSizeScore() {
        XCTAssertEqual(scorer.classSizeSubScore(classMatches: true, sizeRatio: 1.0), 1.0)
        XCTAssertEqual(scorer.classSizeSubScore(classMatches: true, sizeRatio: 1.5), 0.5)   // size off
        XCTAssertEqual(scorer.classSizeSubScore(classMatches: false, sizeRatio: 1.1), 0.5)  // class off, size ok
    }

    // MARK: Accept / ambiguity gate

    func testAmbiguousPairFailsLoudly() {
        let d = scorer.decide(scores: [0.65, 0.64])   // margin 0.01 < 0.10
        XCTAssertFalse(d.accepted)
        XCTAssertNil(d.bestIndex)
    }

    func testTopTieIsAmbiguous() {
        let d = scorer.decide(scores: [0.80, 0.80, 0.30])   // two-way tie at the top
        XCTAssertFalse(d.accepted)
    }

    func testClearWinnerAccepted() {
        let d = scorer.decide(scores: [0.80, 0.40])
        XCTAssertTrue(d.accepted)
        XCTAssertEqual(d.bestIndex, 0)
    }

    func testSingleCandidateBelowFloorRejected() {
        XCTAssertFalse(scorer.decide(scores: [0.50]).accepted)
    }

    func testSingleCandidateAboveFloorAccepted() {
        let d = scorer.decide(scores: [0.70])
        XCTAssertTrue(d.accepted)
        XCTAssertEqual(d.bestIndex, 0)
    }

    func testEmptyRejected() {
        XCTAssertFalse(scorer.decide(scores: []).accepted)
    }

    // MARK: End-to-end via features

    func testEvaluatePicksSeparatedWinner() {
        let strong = CandidateFeatures(visualNCC: 0.98, elementHasText: true, textExactMatch: true,
                                       neighborFraction: 1, positionDistanceFraction: 0, classMatches: true, sizeRatio: 1)
        let weak = CandidateFeatures(visualNCC: 0.4, elementHasText: false,
                                     neighborFraction: 0, positionDistanceFraction: 0.5, classMatches: false, sizeRatio: 2)
        let d = scorer.evaluate([weak, strong])
        XCTAssertTrue(d.accepted)
        XCTAssertEqual(d.bestIndex, 1)
    }

    func testUnnormalizedWeightsKeepScoreInUnitRange() {
        // A tuning-loop misconfig: weights summing to 1.5. Score must still be ≤ 1 (normalized), so
        // the fixed 0.62 floor / 0.10 margin stay meaningful.
        let badTuning = RelocationTuning(weightVisual: 0.6, weightText: 0.5, weightNeighbors: 0.4,
                                         weightGeometry: 0.3, weightClassSize: 0.2)  // sum 2.0
        let s = Scorer(tuning: badTuning)
        let perfect = CandidateFeatures(visualNCC: 1, elementHasText: true, textExactMatch: true,
                                        neighborFraction: 1, positionDistanceFraction: 0, classMatches: true, sizeRatio: 1)
        XCTAssertLessThanOrEqual(s.score(perfect), 1.0 + 1e-9)
    }

    func testEvaluateTwoIdenticalCandidatesFails() {
        // Two indistinguishable "solo buttons": identical features → identical scores → ambiguous.
        let f = CandidateFeatures(visualNCC: 0.95, elementHasText: false, neighborFraction: 0.5,
                                  positionDistanceFraction: 0.05, classMatches: true, sizeRatio: 1)
        XCTAssertFalse(scorer.evaluate([f, f]).accepted)
    }
}
