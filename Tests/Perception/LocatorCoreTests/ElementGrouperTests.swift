import XCTest
@testable import LocatorCore

final class ElementGrouperTests: XCTestCase {
    typealias T = ElementGrouper.TextRun
    typealias I = ElementGrouper.Icon

    // MARK: text-line merging

    func testFragmentsOnOneBaselineMerge() {
        let out = ElementGrouper.mergeLines([
            T(rect: CGRect(x: 10, y: 100, width: 40, height: 14), text: "Save"),
            T(rect: CGRect(x: 56, y: 101, width: 30, height: 14), text: "As…"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Save As…")
        XCTAssertEqual(out[0].rect, CGRect(x: 10, y: 100, width: 76, height: 15))
    }

    func testLeftFragmentJoinsInReadingOrder() {   // sorted-by-x guarantee doesn't hold across midY jitter
        let out = ElementGrouper.mergeLines([
            T(rect: CGRect(x: 60, y: 100, width: 40, height: 14), text: "name"),
            T(rect: CGRect(x: 10, y: 103, width: 44, height: 14), text: "Track"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Track name")
    }

    func testColumnsDoNotMerge() {   // gap of 3x line height = a table column boundary
        let out = ElementGrouper.mergeLines([
            T(rect: CGRect(x: 10, y: 100, width: 40, height: 14), text: "Vocals"),
            T(rect: CGRect(x: 100, y: 100, width: 40, height: 14), text: "-12.0"),
        ])
        XCTAssertEqual(out.count, 2)
    }

    func testDifferentRowsDoNotMerge() {
        let out = ElementGrouper.mergeLines([
            T(rect: CGRect(x: 10, y: 100, width: 40, height: 14), text: "Import"),
            T(rect: CGRect(x: 10, y: 130, width: 40, height: 14), text: "Export"),
        ])
        XCTAssertEqual(out.count, 2)
    }

    func testTitleNeverMergesIntoBodyText() {   // height ratio > 1.8 blocks font-size mixing
        let out = ElementGrouper.mergeLines([
            T(rect: CGRect(x: 10, y: 100, width: 80, height: 30), text: "Export"),
            T(rect: CGRect(x: 95, y: 112, width: 40, height: 12), text: "beta"),
        ])
        XCTAssertEqual(out.count, 2)
    }

    // MARK: icon + text pairing

    func testIconWithRightLabelBecomesOneControl() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 30, y: 101, width: 52, height: 16), text: "Export")],
            icons: [I(rect: CGRect(x: 8, y: 100, width: 18, height: 18))])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "control")
        XCTAssertEqual(out[0].label, "Export")                   // unlabeled icon INHERITS the caption
        XCTAssertFalse(out[0].unlabeled)
        XCTAssertEqual(out[0].rect, CGRect(x: 8, y: 100, width: 74, height: 18))
    }

    func testDropdownCaretPairsWithTextOnItsLeft() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 10, y: 100, width: 60, height: 16), text: "H.264")],
            icons: [I(rect: CGRect(x: 74, y: 102, width: 12, height: 12), label: "dropdown caret")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "control")
        XCTAssertEqual(out[0].label, "H.264")                    // the visible value names the control
    }

    func testCaptionBelowIconPairs() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 6, y: 138, width: 44, height: 12), text: "Effects")],
            icons: [I(rect: CGRect(x: 10, y: 100, width: 36, height: 36))])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "control")
        XCTAssertEqual(out[0].label, "Effects")
    }

    func testFarTextDoesNotPair() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 200, y: 100, width: 52, height: 16), text: "Export")],
            icons: [I(rect: CGRect(x: 8, y: 100, width: 18, height: 18))])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.kind)), ["text", "icon"])
        XCTAssertTrue(out.first { $0.kind == "icon" }!.unlabeled)
    }

    func testParagraphNeverBecomesACaption() {   // >48 chars = body text, not a label
        let long = String(repeating: "word ", count: 12)
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 30, y: 100, width: 300, height: 16), text: long)],
            icons: [I(rect: CGRect(x: 8, y: 100, width: 18, height: 18))])
        XCTAssertEqual(out.count, 2)
    }

    func testCompetingIconsClosestWins() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 30, y: 100, width: 40, height: 16), text: "Mute")],
            icons: [I(rect: CGRect(x: 12, y: 100, width: 16, height: 16)),      // gap 2 → wins
                    I(rect: CGRect(x: 74, y: 100, width: 16, height: 16))])     // gap 4 → stays bare
        let controls = out.filter { $0.kind == "control" }
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls[0].label, "Mute")
        XCTAssertEqual(controls[0].rect.minX, 12)
        XCTAssertEqual(out.filter { $0.kind == "icon" }.count, 1)
    }

    func testFragmentedCaptionMergesThenPairs() {   // both passes compose
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 30, y: 101, width: 40, height: 14), text: "Record"),
                    T(rect: CGRect(x: 74, y: 101, width: 30, height: 14), text: "Arm")],
            icons: [I(rect: CGRect(x: 8, y: 100, width: 16, height: 16))])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].label, "Record Arm")
        XCTAssertEqual(out[0].kind, "control")
    }

    // MARK: row-toggle pairing (settings rows: "Facebook ………… [switch]")

    func testToggleFarOnSameRowPairsAndKeepsSwitchRect() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 70, height: 16), text: "Facebook")],
            icons: [I(rect: CGRect(x: 400, y: 99, width: 36, height: 18), isToggle: true, state: "on")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "control")
        XCTAssertEqual(out[0].label, "Facebook")
        XCTAssertEqual(out[0].state, "on")
        XCTAssertEqual(out[0].rect, CGRect(x: 400, y: 99, width: 36, height: 18))   // the actionable hotspot
    }

    func testNonToggleIconNeverRowPairs() {   // a toolbar icon must not grab the row's distant text
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 70, height: 16), text: "Facebook")],
            icons: [I(rect: CGRect(x: 400, y: 99, width: 18, height: 18))])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains { $0.kind == "icon" })
    }

    func testToggleOnDifferentRowDoesNotPair() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 70, height: 16), text: "Facebook")],
            icons: [I(rect: CGRect(x: 400, y: 160, width: 36, height: 18), isToggle: true, state: "off")])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first { $0.kind == "icon" }?.state, "off")   // state still surfaces on the bare icon
    }

    func testTwoRowsEachToggleTakesItsOwnLabel() {
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 70, height: 16), text: "Facebook"),
                    T(rect: CGRect(x: 20, y: 140, width: 60, height: 16), text: "YouTube")],
            icons: [I(rect: CGRect(x: 400, y: 99, width: 36, height: 18), isToggle: true, state: "on"),
                    I(rect: CGRect(x: 400, y: 139, width: 36, height: 18), isToggle: true, state: "off")])
        let controls = out.filter { $0.kind == "control" }.sorted { $0.rect.minY < $1.rect.minY }
        XCTAssertEqual(controls.count, 2)
        XCTAssertEqual(controls[0].label, "Facebook"); XCTAssertEqual(controls[0].state, "on")
        XCTAssertEqual(controls[1].label, "YouTube"); XCTAssertEqual(controls[1].state, "off")
    }

    func testAdjacentToggleStillPairsViaCaptionPassWithState() {   // close label → pass 2 wins, state carried
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 50, height: 16), text: "VIDEO")],
            icons: [I(rect: CGRect(x: 76, y: 99, width: 36, height: 18), isToggle: true, state: "on")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "control")
        XCTAssertEqual(out[0].state, "on")
    }

    // MARK: switch detection (coalescing + knob-only column inference)

    private let pillShaped: (CGRect) -> Bool = { r in
        let a = r.width / r.height
        return r.height >= 12 && a >= 1.5 && a <= 2.3
    }

    func testFragmentedSwitchCoalescesIntoPill() {   // knob + track end, 3px apart → one pill
        let sw = ElementGrouper.toggleCandidates(
            segments: [CGRect(x: 100, y: 50, width: 20, height: 20),
                       CGRect(x: 123, y: 52, width: 12, height: 16)],
            isToggleShaped: pillShaped)
        XCTAssertEqual(sw.count, 1)
        XCTAssertEqual(sw[0].rect, CGRect(x: 100, y: 50, width: 35, height: 20))
        XCTAssertNil(sw[0].inferredState)                  // full pill → caller reads pixels
    }

    func testKnobOnlySquareInPillColumnBecomesSwitchWithGeometricState() {
        let sw = ElementGrouper.toggleCandidates(
            segments: [CGRect(x: 611, y: 601, width: 58, height: 34),    // known pill (e.g. the ON one)
                       CGRect(x: 611, y: 673, width: 34, height: 34),    // knob at LEFT edge → off
                       CGRect(x: 635, y: 745, width: 34, height: 34)],   // knob at RIGHT edge → on
            isToggleShaped: pillShaped)
        XCTAssertEqual(sw.count, 3)
        XCTAssertEqual(sw[1].rect, CGRect(x: 611, y: 673, width: 58, height: 34))   // pill-sized, column x
        XCTAssertEqual(sw[1].inferredState, "off")
        XCTAssertEqual(sw[2].inferredState, "on")
    }

    func testLoneSquareWithoutPillColumnIsNotASwitch() {
        let sw = ElementGrouper.toggleCandidates(
            segments: [CGRect(x: 100, y: 50, width: 34, height: 34)],
            isToggleShaped: pillShaped)
        XCTAssertTrue(sw.isEmpty)
    }

    func testAllOffColumnRecoveredWithoutAnyPill() {   // every switch off → no pill anywhere to anchor
        let sw = ElementGrouper.toggleCandidates(
            segments: [CGRect(x: 611, y: 529, width: 34, height: 34),
                       CGRect(x: 611, y: 601, width: 34, height: 34),
                       CGRect(x: 611, y: 673, width: 34, height: 34)],
            isToggleShaped: pillShaped)
        XCTAssertEqual(sw.count, 3)
        XCTAssertEqual(sw[0].rect.width, 1.7 * 34)         // assumed standard pill ratio
        XCTAssertNil(sw[0].inferredState)                  // pixels decide (knob-left + dark track → off)
    }

    // MARK: checkbox / radio candidates (square unions — the caller confirms them with pixels)

    private let markShaped: (CGRect) -> Bool = { r in
        let a = r.width / r.height
        return r.height >= 10 && r.height <= 60 && a >= 0.8 && a <= 1.25
    }

    func testSquareUnionsAreMarkCandidatesAndPillsAreNot() {
        let out = ElementGrouper.markCandidates(
            segments: [CGRect(x: 917, y: 321, width: 20, height: 20),     // DaVinci's selected radio dot
                       CGRect(x: 917, y: 1259, width: 20, height: 20),    // …and the one 900px below it
                       CGRect(x: 611, y: 601, width: 58, height: 34)],    // a switch PILL — not a mark
            isMarkShaped: markShaped)
        XCTAssertEqual(out, [CGRect(x: 917, y: 321, width: 20, height: 20),
                             CGRect(x: 917, y: 1259, width: 20, height: 20)])   // top-to-bottom
    }

    func testMarkCandidateCoalescesAFrameWithItsTick() {   // frame + mark segment apart, union is the control
        let out = ElementGrouper.markCandidates(
            segments: [CGRect(x: 100, y: 50, width: 28, height: 4),       // the box's top edge
                       CGRect(x: 110, y: 58, width: 8, height: 8),        // the tick between them
                       CGRect(x: 100, y: 70, width: 28, height: 4)],      // …and its bottom edge
            isMarkShaped: markShaped)
        XCTAssertEqual(out, [CGRect(x: 100, y: 50, width: 28, height: 24)])
    }

    func testLoneSquareIsStillAMarkCandidate() {   // unlike a switch knob, a checkbox needs no column
        let out = ElementGrouper.markCandidates(segments: [CGRect(x: 100, y: 50, width: 24, height: 24)],
                                                isMarkShaped: markShaped)
        XCTAssertEqual(out.count, 1)
    }

    func testChromeGlyphsNeverVetoASwitchButRealWordsDo() {
        let sw = CGRect(x: 100, y: 50, width: 58, height: 34)
        // Vision misreads over switch chrome (measured on Premiere: "C", "CC", "…") must not veto.
        XCTAssertFalse(ElementGrouper.switchVetoedByText(sw, runs: [("C", sw), ("CC", sw), ("...", sw)]))
        // A real word covering the box means it's text, not a switch.
        XCTAssertTrue(ElementGrouper.switchVetoedByText(sw, runs: [("Export", sw.insetBy(dx: 4, dy: 8))]))
        // A real word far away vetoes nothing.
        XCTAssertFalse(ElementGrouper.switchVetoedByText(sw, runs: [("Export", CGRect(x: 400, y: 50, width: 60, height: 20))]))
    }

    // MARK: OCR-misread guards

    func testKnobGlyphs() {
        XCTAssertTrue(ElementGrouper.isKnobGlyph("O"))
        XCTAssertTrue(ElementGrouper.isKnobGlyph("0"))
        XCTAssertTrue(ElementGrouper.isKnobGlyph("•"))
        XCTAssertFalse(ElementGrouper.isKnobGlyph("X"))    // the platform X is a real label
        XCTAssertFalse(ElementGrouper.isKnobGlyph("OK"))
        XCTAssertFalse(ElementGrouper.isKnobGlyph("••."))  // multi-char → handled by isNameworthy instead
    }

    func testPunctuationNeverNamesAControl() {   // "••." misread must not beat the real row label
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 20, y: 100, width: 80, height: 16), text: "Media File"),
                    T(rect: CGRect(x: 340, y: 100, width: 40, height: 16), text: "••.")],
            icons: [I(rect: CGRect(x: 400, y: 99, width: 36, height: 18), isToggle: true, state: "off")])
        let control = out.first { $0.kind == "control" }
        XCTAssertEqual(control?.label, "Media File")
        XCTAssertEqual(control?.state, "off")
    }

    func testDeterministicOrder() {
        let texts = [T(rect: CGRect(x: 30, y: 100, width: 40, height: 16), text: "A"),
                     T(rect: CGRect(x: 30, y: 200, width: 40, height: 16), text: "B")]
        let icons = [I(rect: CGRect(x: 8, y: 100, width: 16, height: 16)),
                     I(rect: CGRect(x: 8, y: 200, width: 16, height: 16))]
        let a = ElementGrouper.group(texts: texts, icons: icons)
        let b = ElementGrouper.group(texts: texts, icons: icons)
        XCTAssertEqual(a, b)
    }

    // MARK: false groups on real UI (the benchmark pass, 2026-09-05)

    func testListRowLabelUnderIconIsNotACaption() {   // Finder: next row's filename is NOT this icon's caption
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 40, y: 140, width: 326, height: 24), text: "premiere_agent_assets")],
            icons: [I(rect: CGRect(x: 4, y: 100, width: 32, height: 32))])
        XCTAssertEqual(Set(out.map(\.kind)), ["text", "icon"], "left-aligned wide text below a small icon is another row")
    }

    func testCenteredCaptionUnderIconStillPairs() {   // grid / toolbar captions are centered
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 0, y: 140, width: 120, height: 20), text: "Show View Options")],
            icons: [I(rect: CGRect(x: 42, y: 100, width: 36, height: 36))])
        XCTAssertEqual(out.count, 1); XCTAssertEqual(out[0].kind, "control")
    }

    func testSwitchNeverTakesARightSideCaption() {   // a settings switch is labelled on its LEFT
        let out = ElementGrouper.group(
            texts: [T(rect: CGRect(x: 50, y: 100, width: 200, height: 24), text: "premiere_agent_assets.zip")],
            icons: [I(rect: CGRect(x: 4, y: 96, width: 40, height: 22), isToggle: true, state: "on")])
        XCTAssertEqual(out.first { $0.kind == "text" }?.label, "premiere_agent_assets.zip")
        XCTAssertNil(out.first { $0.kind == "control" }, "the filename to the right must not name the switch")
    }

    func testTextGlyphOnABaselineIsNotAnIcon() {
        let runs = [CGRect(x: 60, y: 100, width: 200, height: 24)]
        XCTAssertTrue(ElementGrouper.isTextGlyph(CGRect(x: 40, y: 106, width: 10, height: 11), ocrBoxes: runs, lineHeight: 24))  // "•"
        XCTAssertTrue(ElementGrouper.isTextGlyph(CGRect(x: 44, y: 101, width: 8, height: 22), ocrBoxes: runs, lineHeight: 24))   // "("
        XCTAssertFalse(ElementGrouper.isTextGlyph(CGRect(x: 20, y: 94, width: 36, height: 36), ocrBoxes: runs, lineHeight: 24))  // real icon beside a caption
        XCTAssertFalse(ElementGrouper.isTextGlyph(CGRect(x: 40, y: 103, width: 20, height: 20), ocrBoxes: runs, lineHeight: 24))  // an expander chevron (0.83 of a line)
        XCTAssertFalse(ElementGrouper.isTextGlyph(CGRect(x: 40, y: 400, width: 10, height: 11), ocrBoxes: runs, lineHeight: 24))  // small but on no baseline
    }

    func testThumbnailWithCentredCaptionBelow() {
        let tile = CGRect(x: 485, y: 620, width: 335, height: 190)               // Keynote theme tile
        let caption = CGRect(x: 588, y: 825, width: 130, height: 24)             // "Basic White", centred
        XCTAssertTrue(ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [caption]))
        // A paragraph wider than the box under a photo is not a caption; a left-aligned far line neither.
        XCTAssertFalse(ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [CGRect(x: 400, y: 825, width: 600, height: 24)]))
        XCTAssertFalse(ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [CGRect(x: 485, y: 825, width: 60, height: 24)]))
        XCTAssertFalse(ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [CGRect(x: 588, y: 900, width: 130, height: 24)]))
    }

    /// Resolve's Clip Color menu: the 'Orange' word blob passes as an icon; 'Apricot' beneath it, same
    /// font, same left edge, is the NEXT ROW — not its caption.
    func testNextListLineIsNotACaption() {
        let orange = ElementGrouper.TextRun(rect: CGRect(x: 891, y: 318, width: 44, height: 16), text: "Orange")
        let apricot = ElementGrouper.TextRun(rect: CGRect(x: 891, y: 342, width: 44, height: 16), text: "Apricot")
        let blob = ElementGrouper.Icon(rect: CGRect(x: 889, y: 317, width: 46, height: 18))   // 'Orange' + row hook
        let g = ElementGrouper.group(texts: [orange, apricot], icons: [blob])
        XCTAssertEqual(g.filter { $0.kind == "control" }.map(\.label), [], "two list lines never fuse")
        XCTAssertEqual(g.filter { $0.kind == "text" }.map(\.label), ["Orange", "Apricot"])
        // A centred caption under a picture-like box with text inside (Keynote tile) still pairs.
        let tile = ElementGrouper.Icon(rect: CGRect(x: 485, y: 620, width: 335, height: 190))
        let inner = ElementGrouper.TextRun(rect: CGRect(x: 500, y: 700, width: 150, height: 20), text: "My Presentation")
        let cap = ElementGrouper.TextRun(rect: CGRect(x: 588, y: 825, width: 130, height: 20), text: "Basic White")
        let g2 = ElementGrouper.group(texts: [inner, cap], icons: [tile])
        XCTAssertEqual(g2.filter { $0.kind == "control" }.map(\.label), ["Basic White"])
    }
}
