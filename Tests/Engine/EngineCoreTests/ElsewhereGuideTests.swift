//
//  ElsewhereGuideTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

@Suite("Elsewhere guide")
struct ElsewhereGuideTests {

    private func verdict(_ number: Int, layer: Int = 0, title: String? = "Doc", kind: SurfaceKind = .window,
                         w: CGFloat = 800, h: CGFloat = 600) -> SurfaceVerdict {
        SurfaceVerdict(row: WindowRow(layer: layer, frame: CGRect(x: 0, y: 0, width: w, height: h), title: title, number: number),
                       kind: kind, why: "")
    }

    @Test("a pop-up that appeared is the effect")
    func popupAppeared() {
        let before = [verdict(1)]
        let after = [verdict(9, layer: 101, title: nil, kind: .popupLayer, w: 220, h: 56), verdict(1)]
        let guide = ElsewhereGuide.forUnverifiedAct(app: "Premiere", before: before, after: after)
        #expect(guide.changed)
        #expect(guide.sentence.contains("pop-up menu opened"))
    }

    @Test("a new window is named, by title or by size")
    func windowAppeared() {
        let titled = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(1)], after: [verdict(2, title: "Export"), verdict(1)])
        #expect(titled.sentence.contains("\"Export\""))
        let untitled = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(1)], after: [verdict(2, title: nil, w: 300, h: 200), verdict(1)])
        #expect(untitled.sentence.contains("300×200pt"))
    }

    @Test("a pop-up or window that closed is named")
    func closed() {
        let popup = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(9, layer: 101, kind: .popupLayer), verdict(1)], after: [verdict(1)])
        #expect(popup.changed)
        #expect(popup.sentence.contains("pop-up menu closed"))
        let window = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(2, title: "Sheet"), verdict(1)], after: [verdict(1)])
        #expect(window.sentence.contains("\"Sheet\" closed"))
    }

    @Test("a retitle is a navigation; a resize alone is nothing")
    func retitleAndResize() {
        let retitled = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(1, title: "A")], after: [verdict(1, title: "B")])
        #expect(retitled.changed)
        #expect(retitled.sentence.contains("now titled \"B\""))
        let resized = ElsewhereGuide.forUnverifiedAct(app: "X", before: [verdict(1)], after: [verdict(1, w: 900)])
        #expect(!resized.changed)
        #expect(resized.sentence.contains("Nothing else in X changed"))
    }
}
