import XCTest
import CoreGraphics
import LocatorCore
@testable import Relocation

/// The "Destinations" panel case: a column of VISUALLY IDENTICAL on/off toggles whose only identity is the
/// row label beside them. Proves row-aware neighbor capture stores the SAME-ROW label (not adjacent rows),
/// and that the existing constellation matcher then pins the correct row.
final class RowAnchorTests: XCTestCase {
    // A faithful mini-Destinations layout (top-left px). Each row: label on the left, an identical toggle on
    // the right at x≈480. Section headers PUBLISH / CLOUD. Toggles are NOT text → no runs for them.
    private let runs: [(text: String, box: CGRect)] = [
        ("Media File", CGRect(x: 110, y: 92, width: 120, height: 22)),
        ("PUBLISH",    CGRect(x: 90,  y: 182, width: 90,  height: 18)),
        ("Behance",    CGRect(x: 110, y: 258, width: 100, height: 22)),
        ("Facebook",   CGRect(x: 110, y: 330, width: 110, height: 22)),
        ("TikTok",     CGRect(x: 110, y: 402, width: 90,  height: 22)),
        ("Vimeo",      CGRect(x: 110, y: 474, width: 80,  height: 22)),
        ("YouTube",    CGRect(x: 110, y: 618, width: 110, height: 22)),
        ("CLOUD",      CGRect(x: 90,  y: 700, width: 70,  height: 18)),
        ("FTP",        CGRect(x: 110, y: 786, width: 50,  height: 22)),
    ]
    // The TikTok toggle: same row (y≈402), far right.
    private let tikTokToggle = CGRect(x: 480, y: 398, width: 56, height: 30)

    func testRowAwareCapturePicksSameRowLabelNotAdjacentRows() {
        let n = DescriptorBuilder.rowAwareNeighbors(runs: runs, elementPx: tikTokToggle, limit: 6)
        // The PRIMARY (first) anchor must be this row's label — never Facebook (above) or Vimeo (below).
        XCTAssertEqual(n.first?.text, "TikTok")
        XCTAssertFalse(n.prefix(1).contains { $0.text == "Facebook" || $0.text == "Vimeo" })
        // The section header is captured as a coarse anchor.
        XCTAssertTrue(n.contains { $0.text == "PUBLISH" })
    }

    func testConstellationPinsTheCorrectRowFromRowAwareNeighbors() {
        // Capture row-aware neighbors for the TikTok toggle, then relocate against the WHOLE frame.
        let neighbors = DescriptorBuilder.rowAwareNeighbors(runs: runs, elementPx: tikTokToggle, limit: 6)
        // A globally-unique row label sitting at its expected offset is the trust gate — it must pass for
        // the TikTok toggle's true box and identify the right row.
        XCTAssertTrue(TextConstellation.hasUniqueNeighborSupport(
            box: tikTokToggle, neighbors: neighbors, offsetScale: 1, tolerancePadPx: 6, runs: runs))

        // locateByNeighbors triangulates the toggle origin from the (clean, same-row) anchors → the TikTok row.
        let located = TextConstellation.locateByNeighbors(
            neighbors: neighbors, offsetScale: 1, tolerancePadPx: 6,
            elementSizePx: tikTokToggle.size, minAgree: 1, runs: runs)
        XCTAssertNotNil(located)
        // It lands on the TikTok row (y≈398), NOT Facebook (y≈398-72) or Vimeo (y≈398+72).
        XCTAssertEqual(located!.box.minY, tikTokToggle.minY, accuracy: 16)
        XCTAssertEqual(located!.box.minX, tikTokToggle.minX, accuracy: 16)
    }

    func testIsRowLabelAndSectionHeaderHeuristics() {
        XCTAssertTrue(DescriptorBuilder.isRowLabel("TikTok", box: CGRect(x: 0, y: 0, width: 90, height: 22)))
        XCTAssertFalse(DescriptorBuilder.isRowLabel("•", box: CGRect(x: 0, y: 0, width: 8, height: 8)))     // decoration → not a label
        XCTAssertFalse(DescriptorBuilder.isRowLabel("⋯", box: CGRect(x: 0, y: 0, width: 18, height: 6)))    // menu glyph → not a label
        XCTAssertTrue(DescriptorBuilder.isSectionHeader("PUBLISH"))
        XCTAssertTrue(DescriptorBuilder.isSectionHeader("CLOUD"))
        XCTAssertFalse(DescriptorBuilder.isSectionHeader("Facebook"))   // not all-caps → a row label, not a header
    }
}
