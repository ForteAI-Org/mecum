import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// Pins run-based scroll evidence at the SCENE seam — where the sections, their names and their elements
/// meet, and where the false affordance was actually served to the agent. The frame is DaVinci's Project
/// Settings: SectionDetector cuts ONE aligned category list into two "sidebar (…)" panes, and the
/// invented boundary carried the whole truncation signature, so the map said "scrolls ↓ (more below)"
/// about a pane nothing can scroll — and the lie was learned from there.
final class ScrollSeamRunTests: XCTestCase {
    private func el(_ label: String, y: Double, section: String,
                    x: Double = 0.03, w: Double = 0.14, h: Double = 0.018) -> SceneElement {
        var e = SceneElement(id: "\(section)/\(label)", kind: "text", label: label,
                             pos: [x, y, w, h], state: nil, unlabeled: nil)
        e.section = section
        return e
    }

    private let app = "test.seam.run"
    private let pitch = 0.0421

    /// The measured DaVinci frame: 11 categories at one pitch down the sidebar, ending less than
    /// two-thirds of the way down — and the section cut falling right after the 6th, at y = 0.35.
    private func davinciSidebar() -> (sections: [SceneSection], elements: [SceneElement]) {
        let upper = "sidebar (Blackmagic Cloud)", lower = "sidebar (Subtitles and Transcription)"
        let sections = [
            SceneSection(name: upper, pos: [0.0, 0.08, 0.20, 0.27]),
            SceneSection(name: lower, pos: [0.0, 0.35, 0.20, 0.56]),
            SceneSection(name: "content", pos: [0.20, 0.08, 0.80, 0.84]),
        ]
        let rows = ["Master Settings", "Blackmagic Cloud", "Image Scaling", "Color Management",
                    "General Options", "Camera Raw", "Capture and Playback",
                    "Subtitles and Transcription", "Fusion", "Fairlight", "Path Mapping"]
        let elements = rows.enumerated().map { i, l -> SceneElement in
            let y = 0.105 + Double(i) * pitch
            return el(l, y: y, section: y < 0.35 ? upper : lower)
        }
        return (sections, elements)
    }

    func testSplitSidebarAdvertisesNothing() {
        let frame = davinciSidebar()
        var sections = frame.sections
        SceneBuilder.annotateScrollability(sections: &sections, elements: frame.elements, app: app)
        XCTAssertNil(sections[0].scrolls, "the upper tile's bottom edge is a cut — got \(sections[0].scrolls ?? "")")
        XCTAssertNil(sections[1].scrolls, "the lower tile's top edge is a cut — got \(sections[1].scrolls ?? "")")
    }

    /// The regression this replaces: with the tile treated as a pane in its own right, the cut reads as
    /// truncation and the map lies. Proves the geometry really does carry the false signature — the test
    /// above is not passing for some unrelated reason.
    func testTheSameTileAloneStillReadsAsTruncated() {
        let frame = davinciSidebar()
        var upperOnly = [frame.sections[0]]
        SceneBuilder.annotateScrollability(sections: &upperOnly, elements: frame.elements, app: app)
        XCTAssertNotNil(upperOnly[0].scrolls, "precondition: the tile alone DOES carry the false signature")
    }

    /// A truly truncated sidebar (Finder's, whose last row is clipped by the window bottom) keeps its
    /// claim — the veto is about invented boundaries, not about silencing evidence.
    func testUnsplitTruncatedSidebarKeepsItsClaim() {
        let name = "sidebar (Recents)"
        var sections = [SceneSection(name: name, pos: [0.0, 0.0, 0.17, 1.0]),
                        SceneSection(name: "content", pos: [0.17, 0.0, 0.83, 1.0])]
        let rows = ["Recents", "Shared", "Applications", "Documents", "Desktop", "Downloads",
                    "aaf", "iCloud Drive", "Google Drive", "ronaldozefi"]
        let elements = rows.enumerated().map { i, l in el(l, y: 0.06 + Double(i) * 0.093, section: name) }
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app)
        XCTAssertNotNil(sections[0].scrolls, "a list clipped by the real window edge still scrolls")
    }

    /// A stacked pane of a DIFFERENT family (a sidebar over a bottom bar) is a real boundary, so a list
    /// running into it is real truncation. The run must not swallow "anything below me".
    func testDifferentFamilyBelowIsARealEdge() {
        let name = "sidebar (Recents)"
        var sections = [SceneSection(name: name, pos: [0.0, 0.0, 0.17, 0.5]),
                        SceneSection(name: "bottom bar", pos: [0.0, 0.5, 0.17, 0.5])]
        let rows = ["Recents", "Shared", "Applications", "Documents", "Desktop", "Downloads", "aaf"]
        var elements = rows.enumerated().map { i, l in el(l, y: 0.03 + Double(i) * 0.066, section: name) }
        elements.append(el("Cancel", y: 0.505, section: "bottom bar"))
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app)
        XCTAssertNotNil(sections[0].scrolls, "a real panel boundary below still truncates the list")
    }
}
