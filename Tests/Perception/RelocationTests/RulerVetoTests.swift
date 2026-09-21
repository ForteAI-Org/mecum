import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// Pins the ruler veto with the EXACT frame that produced the false positive: supervising Premiere
/// live, the audio meter's dB ladder (0, -6 … -54) carried ScrollScout's full aligned-list +
/// clipped-edge signature and the scene advertised "likely scrolls ↓" on a strip nothing can scroll.
final class RulerVetoTests: XCTestCase {
    func el(_ label: String, x: Double, y: Double, w: Double = 0.02, h: Double = 0.012,
            section: String, unlabeled: Bool? = nil) -> SceneElement {
        var e = SceneElement(id: label, kind: "text", label: label,
                             pos: [x, y, w, h], state: nil, unlabeled: unlabeled)
        e.section = section
        return e
    }

    /// The meter strip from the live Premiere frame: narrow (0.06 wide), numeric ladder, last tick
    /// clipped by the section edge — must NOT advertise scrolling.
    func testAudioMeterRulerIsVetoed() {
        let sec = "zero counter"
        var sections = [SceneSection(name: sec, pos: [0.94, 0.58, 0.06, 0.35])]
        let ladder = ["0", "-6", "-12", "-18", "-24", "-30", "-36", "-42", "--48", "-54"]
        var elements = ladder.enumerated().map { i, l in
            el(l, x: 0.965, y: 0.60 + Double(i) * 0.032, section: sec)
        }
        elements.append(el(":dB", x: 0.965, y: 0.925, section: sec))   // clipped by the bottom edge
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: "test.ruler.veto")
        XCTAssertNil(sections[0].scrolls, "a dB ladder must never advertise scrolling, got \(sections[0].scrolls ?? "")")
    }

    /// Same geometry with NAME labels (a real sidebar list) keeps its evidence — the veto is about
    /// rulers, not lists.
    func testNamedListKeepsItsEvidence() {
        let sec = "sidebar"
        var sections = [SceneSection(name: sec, pos: [0.94, 0.58, 0.06, 0.35])]
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet"]
        let elements = names.enumerated().map { i, l in
            el(l, x: 0.945, y: 0.60 + Double(i) * 0.0332, w: 0.05, section: sec)
        }
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: "test.ruler.veto")
        XCTAssertNotNil(sections[0].scrolls, "an aligned NAME list clipped at the edge should keep scroll evidence")
    }

    /// A WIDE pane full of numbers (spreadsheet-like) is content, not a ruler — width gate holds.
    func testWideNumericContentIsNotVetoed() {
        let sec = "content"
        var sections = [SceneSection(name: sec, pos: [0.3, 0.1, 0.5, 0.8])]
        let elements = (0..<12).map { i in
            el("\(i * 100)", x: 0.32, y: 0.12 + Double(i) * 0.066, w: 0.45, h: 0.03, section: sec)
        }
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: "test.ruler.veto")
        XCTAssertNotNil(sections[0].scrolls, "wide numeric content keeps its evidence (spreadsheets scroll)")
    }
}
