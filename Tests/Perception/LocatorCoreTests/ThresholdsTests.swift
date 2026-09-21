import XCTest
@testable import LocatorCore

final class ThresholdsTests: XCTestCase {
    func testDefaults() {
        let t = Thresholds.defaults
        XCTAssertEqual(t.nccMin, 0.85)
        XCTAssertEqual(t.edgeHashMaxDist, 10)
        XCTAssertEqual(t.stage4ScoreFloor, 0.62)
        XCTAssertEqual(t.ambiguityMargin, 0.10)
    }

    func testDecodeMissingKeysFallsBackToDefaults() throws {
        // A thresholds object with only one key present — the rest must default.
        let json = Data(#"{"nccMin": 0.9}"#.utf8)
        let t = try JSONDecoder().decode(Thresholds.self, from: json)
        XCTAssertEqual(t.nccMin, 0.9)
        XCTAssertEqual(t.edgeHashMaxDist, 10)
        XCTAssertEqual(t.stage4ScoreFloor, 0.62)
        XCTAssertEqual(t.ambiguityMargin, 0.10)
    }

    func testEmptyObjectDecodesToAllDefaults() throws {
        let t = try JSONDecoder().decode(Thresholds.self, from: Data("{}".utf8))
        XCTAssertEqual(t, .defaults)
    }

    func testRelocationTuningWeightsAreNormalized() {
        XCTAssertTrue(RelocationTuning.defaults.weightsAreNormalized)
        let sum = RelocationTuning.defaults.weightVisual
            + RelocationTuning.defaults.weightText
            + RelocationTuning.defaults.weightNeighbors
            + RelocationTuning.defaults.weightGeometry
            + RelocationTuning.defaults.weightClassSize
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9)
    }
}
