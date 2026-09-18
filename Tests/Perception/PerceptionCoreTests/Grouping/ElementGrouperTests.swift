//
//  ElementGrouperTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// Every rule of the grouper was earned on a real window; the fixtures keep those shapes.
@Suite("Element grouping")
struct ElementGrouperTests {

    typealias Text = ElementGrouper.TextRun
    typealias Icon = ElementGrouper.IconCandidate

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Line merging

    @Test("fragments on one baseline merge")
    func fragmentsMerge() {
        let out = ElementGrouper.mergeLines([Text(rect: box(10, 100, 40, 14), text: "Save"),
                                             Text(rect: box(56, 101, 30, 14), text: "As…")])
        #expect(out.count == 1)
        #expect(out.first?.text == "Save As…")
        #expect(out.first?.rect == box(10, 100, 76, 15))
    }

    @Test("a left fragment joins in reading order")
    func leftFragmentJoins() {
        let out = ElementGrouper.mergeLines([Text(rect: box(60, 100, 40, 14), text: "name"),
                                             Text(rect: box(10, 103, 44, 14), text: "Track")])
        #expect(out.map(\.text) == ["Track name"])
    }

    @Test("columns, rows and font sizes never merge")
    func noMergeAcrossColumnsRowsSizes() {
        #expect(ElementGrouper.mergeLines([Text(rect: box(10, 100, 40, 14), text: "Vocals"),
                                           Text(rect: box(100, 100, 40, 14), text: "-12.0")]).count == 2)
        #expect(ElementGrouper.mergeLines([Text(rect: box(10, 100, 40, 14), text: "Import"),
                                           Text(rect: box(10, 130, 40, 14), text: "Export")]).count == 2)
        #expect(ElementGrouper.mergeLines([Text(rect: box(10, 100, 80, 30), text: "Export"),
                                           Text(rect: box(95, 112, 40, 12), text: "beta")]).count == 2)
    }

    // MARK: Icon and caption pairing

    @Test("an icon with a right label becomes one control")
    func iconWithRightLabel() {
        let out = ElementGrouper.group(texts: [Text(rect: box(30, 101, 52, 16), text: "Export")],
                                       icons: [Icon(rect: box(8, 100, 18, 18))])
        #expect(out.count == 1)
        #expect(out.first?.kind == .control)
        #expect(out.first?.label == "Export")
        #expect(out.first?.isUnlabeled == false)
        #expect(out.first?.rect == box(8, 100, 74, 18))
    }

    @Test("a dropdown caret pairs with the text on its left")
    func caretPairsLeft() {
        let out = ElementGrouper.group(texts: [Text(rect: box(10, 100, 60, 16), text: "H.264")],
                                       icons: [Icon(rect: box(74, 102, 12, 12), label: "dropdown caret")])
        #expect(out.map(\.kind) == [.control])
        #expect(out.first?.label == "H.264")
    }

    @Test("a caption below pairs; far text, paragraphs and list rows do not")
    func captionsAndNonCaptions() {
        let below = ElementGrouper.group(texts: [Text(rect: box(6, 138, 44, 12), text: "Effects")],
                                         icons: [Icon(rect: box(10, 100, 36, 36))])
        #expect(below.map(\.kind) == [.control])
        let far = ElementGrouper.group(texts: [Text(rect: box(200, 100, 52, 16), text: "Export")],
                                       icons: [Icon(rect: box(8, 100, 18, 18))])
        #expect(Set(far.map(\.kind)) == [.text, .icon])
        #expect(far.first { $0.kind == .icon }?.isUnlabeled == true)
        let paragraph = ElementGrouper.group(
            texts: [Text(rect: box(30, 100, 300, 16), text: String(repeating: "word ", count: 12))],
            icons: [Icon(rect: box(8, 100, 18, 18))]
        )
        #expect(paragraph.count == 2)
        let listRow = ElementGrouper.group(texts: [Text(rect: box(40, 140, 326, 24), text: "premiere_agent_assets")],
                                           icons: [Icon(rect: box(4, 100, 32, 32))])
        #expect(Set(listRow.map(\.kind)) == [.text, .icon])
        let centered = ElementGrouper.group(texts: [Text(rect: box(0, 140, 120, 20), text: "Show View Options")],
                                            icons: [Icon(rect: box(42, 100, 36, 36))])
        #expect(centered.map(\.kind) == [.control])
    }

    @Test("competing icons: the closest wins")
    func closestIconWins() {
        let out = ElementGrouper.group(texts: [Text(rect: box(30, 100, 40, 16), text: "Mute")],
                                       icons: [Icon(rect: box(12, 100, 16, 16)), Icon(rect: box(74, 100, 16, 16))])
        let controls = out.filter { $0.kind == .control }
        #expect(controls.count == 1)
        #expect(controls.first?.label == "Mute")
        #expect(controls.first?.rect.minX == 12)
        #expect(out.filter { $0.kind == .icon }.count == 1)
    }

    @Test("a fragmented caption merges, then pairs")
    func fragmentedCaptionPairs() {
        let out = ElementGrouper.group(texts: [Text(rect: box(30, 101, 40, 14), text: "Record"),
                                               Text(rect: box(74, 101, 30, 14), text: "Arm")],
                                       icons: [Icon(rect: box(8, 100, 16, 16))])
        #expect(out.map(\.label) == ["Record Arm"])
        #expect(out.first?.kind == .control)
    }

    // MARK: Row toggles

    @Test("a toggle far on the same row pairs and keeps the switch rect")
    func toggleRowPairs() {
        let out = ElementGrouper.group(texts: [Text(rect: box(20, 100, 70, 16), text: "Facebook")],
                                       icons: [Icon(rect: box(400, 99, 36, 18), isToggle: true, state: .on)])
        #expect(out.count == 1)
        #expect(out.first?.kind == .control)
        #expect(out.first?.label == "Facebook")
        #expect(out.first?.state == .on)
        #expect(out.first?.rect == box(400, 99, 36, 18))
    }

    @Test("only toggles row-pair, only on their own row")
    func rowPairingLimits() {
        let plainIcon = ElementGrouper.group(texts: [Text(rect: box(20, 100, 70, 16), text: "Facebook")],
                                             icons: [Icon(rect: box(400, 99, 18, 18))])
        #expect(plainIcon.count == 2)
        let otherRow = ElementGrouper.group(texts: [Text(rect: box(20, 100, 70, 16), text: "Facebook")],
                                            icons: [Icon(rect: box(400, 160, 36, 18), isToggle: true, state: .off)])
        #expect(otherRow.count == 2)
        #expect(otherRow.first { $0.kind == .icon }?.state == .off)
    }

    @Test("two rows: each toggle takes its own label; an adjacent toggle keeps its state")
    func twoRowsAndAdjacent() {
        let out = ElementGrouper.group(
            texts: [Text(rect: box(20, 100, 70, 16), text: "Facebook"), Text(rect: box(20, 140, 60, 16), text: "YouTube")],
            icons: [Icon(rect: box(400, 99, 36, 18), isToggle: true, state: .on),
                    Icon(rect: box(400, 139, 36, 18), isToggle: true, state: .off)]
        )
        let controls = out.filter { $0.kind == .control }.sorted { $0.rect.minY < $1.rect.minY }
        #expect(controls.map(\.label) == ["Facebook", "YouTube"])
        #expect(controls.map(\.state) == [.on, .off])
        let adjacent = ElementGrouper.group(texts: [Text(rect: box(20, 100, 50, 16), text: "VIDEO")],
                                            icons: [Icon(rect: box(76, 99, 36, 18), isToggle: true, state: .on)])
        #expect(adjacent.count == 1)
        #expect(adjacent.first?.state == .on)
    }

    @Test("a switch never takes a right-side caption")
    func switchNeverTakesRightCaption() {
        let out = ElementGrouper.group(texts: [Text(rect: box(50, 100, 200, 24), text: "premiere_agent_assets.zip")],
                                       icons: [Icon(rect: box(4, 96, 40, 22), isToggle: true, state: .on)])
        #expect(out.first { $0.kind == .text }?.label == "premiere_agent_assets.zip")
        #expect(out.first { $0.kind == .control } == nil)
    }

    @Test("punctuation never names a control")
    func punctuationNeverNames() {
        let out = ElementGrouper.group(
            texts: [Text(rect: box(20, 100, 80, 16), text: "Media File"), Text(rect: box(340, 100, 40, 16), text: "••.")],
            icons: [Icon(rect: box(400, 99, 36, 18), isToggle: true, state: .off)]
        )
        let control = out.first { $0.kind == .control }
        #expect(control?.label == "Media File")
        #expect(control?.state == .off)
    }

    // MARK: Switch detection

    private let pillShaped: (CGRect) -> Bool = { rect in
        let aspect = rect.width / rect.height
        return rect.height >= 12 && aspect >= 1.5 && aspect <= 2.3
    }

    @Test("a fragmented switch coalesces into a pill")
    func fragmentedSwitchCoalesces() {
        let switches = ElementGrouper.toggleCandidates(
            segments: [box(100, 50, 20, 20), box(123, 52, 12, 16)], isToggleShaped: pillShaped
        )
        #expect(switches.count == 1)
        #expect(switches.first?.rect == box(100, 50, 35, 20))
        #expect(switches.first?.inferredState == nil)
    }

    @Test("a knob-only square in a pill column is a switch with a geometric state")
    func knobOnlyInColumn() {
        let switches = ElementGrouper.toggleCandidates(
            segments: [box(611, 601, 58, 34), box(611, 673, 34, 34), box(635, 745, 34, 34)], isToggleShaped: pillShaped
        )
        #expect(switches.count == 3)
        #expect(switches[1].rect == box(611, 673, 58, 34))
        #expect(switches[1].inferredState == .off)
        #expect(switches[2].inferredState == .on)
    }

    @Test("a lone square is not a switch; an all-off column is recovered as assumed")
    func loneSquareAndAllOffColumn() {
        #expect(ElementGrouper.toggleCandidates(segments: [box(100, 50, 34, 34)], isToggleShaped: pillShaped).isEmpty)
        let column = ElementGrouper.toggleCandidates(
            segments: [box(611, 529, 34, 34), box(611, 601, 34, 34), box(611, 673, 34, 34)], isToggleShaped: pillShaped
        )
        #expect(column.count == 3)
        #expect(column.first?.rect.width == 1.7 * 34)
        #expect(column.first?.inferredState == nil)
        #expect(column.first?.isAssumed == true)
    }

    // MARK: Marks

    private let markShaped: (CGRect) -> Bool = { rect in
        let aspect = rect.width / rect.height
        return rect.height >= 10 && rect.height <= 60 && aspect >= 0.8 && aspect <= 1.25
    }

    @Test("square unions are mark candidates, pills are not, frames coalesce with their tick")
    func markCandidates() {
        let out = ElementGrouper.markCandidates(
            segments: [box(917, 321, 20, 20), box(917, 1259, 20, 20), box(611, 601, 58, 34)], isMarkShaped: markShaped
        )
        #expect(out == [box(917, 321, 20, 20), box(917, 1259, 20, 20)])
        let framed = ElementGrouper.markCandidates(
            segments: [box(100, 50, 28, 4), box(110, 58, 8, 8), box(100, 70, 28, 4)], isMarkShaped: markShaped
        )
        #expect(framed == [box(100, 50, 28, 24)])
        #expect(ElementGrouper.markCandidates(segments: [box(100, 50, 24, 24)], isMarkShaped: markShaped).count == 1)
    }

    // MARK: Guards

    @Test("chrome glyphs never veto a switch, real words do")
    func switchVeto() {
        let switchRect = box(100, 50, 58, 34)
        #expect(!ElementGrouper.switchVetoedByText(switchRect, runs: [("C", switchRect), ("CC", switchRect), ("...", switchRect)]))
        #expect(ElementGrouper.switchVetoedByText(switchRect, runs: [("Export", switchRect.insetBy(dx: 4, dy: 8))]))
        #expect(!ElementGrouper.switchVetoedByText(switchRect, runs: [("Export", box(400, 50, 60, 20))]))
    }

    @Test("knob glyphs")
    func knobGlyphs() {
        #expect(ElementGrouper.isKnobGlyph("O"))
        #expect(ElementGrouper.isKnobGlyph("0"))
        #expect(ElementGrouper.isKnobGlyph("•"))
        #expect(!ElementGrouper.isKnobGlyph("X"))
        #expect(!ElementGrouper.isKnobGlyph("OK"))
    }

    @Test("a text glyph on a baseline is not an icon")
    func textGlyphs() {
        let runs = [box(60, 100, 200, 24)]
        #expect(ElementGrouper.isTextGlyph(box(40, 106, 10, 11), ocrBoxes: runs, lineHeight: 24))
        #expect(ElementGrouper.isTextGlyph(box(44, 101, 8, 22), ocrBoxes: runs, lineHeight: 24))
        #expect(!ElementGrouper.isTextGlyph(box(20, 94, 36, 36), ocrBoxes: runs, lineHeight: 24))
        #expect(!ElementGrouper.isTextGlyph(box(40, 103, 20, 20), ocrBoxes: runs, lineHeight: 24))
        #expect(!ElementGrouper.isTextGlyph(box(40, 400, 10, 11), ocrBoxes: runs, lineHeight: 24))
    }

    @Test("a thumbnail has a centered caption beneath it")
    func thumbnails() {
        let tile = box(485, 620, 335, 190)
        #expect(ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [box(588, 825, 130, 24)]))
        #expect(!ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [box(400, 825, 600, 24)]))
        #expect(!ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [box(485, 825, 60, 24)]))
        #expect(!ElementGrouper.hasCaptionBelow(tile, ocrBoxes: [box(588, 900, 130, 24)]))
    }

    @Test("the next list line is not a caption; a captioned tile still pairs")
    func nextListLine() {
        let orange = Text(rect: box(891, 318, 44, 16), text: "Orange")
        let apricot = Text(rect: box(891, 342, 44, 16), text: "Apricot")
        let blob = Icon(rect: box(889, 317, 46, 18))
        let grouped = ElementGrouper.group(texts: [orange, apricot], icons: [blob])
        #expect(grouped.filter { $0.kind == .control }.isEmpty)
        #expect(grouped.filter { $0.kind == .text }.map(\.label) == ["Orange", "Apricot"])
        let tile = Icon(rect: box(485, 620, 335, 190))
        let inner = Text(rect: box(500, 700, 150, 20), text: "My Presentation")
        let caption = Text(rect: box(588, 825, 130, 20), text: "Basic White")
        let tiled = ElementGrouper.group(texts: [inner, caption], icons: [tile])
        #expect(tiled.filter { $0.kind == .control }.map(\.label) == ["Basic White"])
    }

    @Test("output is deterministic")
    func deterministic() {
        let texts = [Text(rect: box(30, 100, 40, 16), text: "A"), Text(rect: box(30, 200, 40, 16), text: "B")]
        let icons = [Icon(rect: box(8, 100, 16, 16)), Icon(rect: box(8, 200, 16, 16))]
        #expect(ElementGrouper.group(texts: texts, icons: icons) == ElementGrouper.group(texts: texts, icons: icons))
    }
}
