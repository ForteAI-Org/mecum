//
//  PopupRowPickTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

/// The measured geometry: Premiere's AAF dialog at 2608,1437 (367×530), its two-row Sample Rate list
/// at 2725,1691 (220×56), rows 28 points tall.
@Suite("Pop-up row pick")
struct PopupRowPickTests {

    private let window = CGRect(x: 2608, y: 1437, width: 367, height: 530)
    private let popup = CGRect(x: 2725, y: 1691, width: 220, height: 56)

    private func element(_ id: String, _ label: String, globalY: CGFloat, globalX: CGFloat = 2745) -> SceneElement {
        SceneElement(id: id, kind: .text, label: label, bounds: NormalizedRect(
            x: Double((globalX - window.minX) / window.width), y: Double((globalY - window.minY) / window.height),
            width: 0.15, height: Double(14 / window.height)
        ))
    }

    private var scene: SceneSnapshot {
        SceneSnapshot(bundleID: "com.adobe.PremierePro", appName: "Premiere", windowTitle: "AAF Export Settings",
                      viewportPixelSize: ViewportPixelSize(width: 734, height: 1060), elements: [
                          element("control|48000", "48000", globalY: 1661),             // the combo box itself, above the list
                          element("text|check", "✓", globalY: 1698, globalX: 2735),
                          element("text|48000", "48000", globalY: 1698),
                          element("text|96000", "96000", globalY: 1726),
                          element("text|bits", "Bits per Sample:", globalY: 1760, globalX: 2650),
                      ])
    }

    @Test("rows are the elements inside the pop-up, banded, top to bottom")
    func rows() {
        let rows = PopupRowPick.rows(in: scene, windowFrame: window, popupFrame: popup)
        #expect(rows.map { $0.map(\.label) } == [["✓", "48000"], ["96000"]])
    }

    @Test("the plan starts on the control's value and takes the shorter way round")
    func plan() throws {
        let rows = PopupRowPick.rows(in: scene, windowFrame: window, popupFrame: popup)
        let target = try #require(scene.elements.first { $0.id == "text|96000" })
        let down = try #require(PopupRowPick.plan(rows: rows, currentValue: "48000", target: target))
        #expect(down.currentIndex == 0 && down.targetIndex == 1 && down.delta == 1)
        #expect(down.route == "1↓ + Return")
        let current = try #require(scene.elements.first { $0.id == "text|48000" })
        let up = try #require(PopupRowPick.plan(rows: rows, currentValue: "96000", target: current))
        #expect(up.delta == -1)
        #expect(PopupRowPick.plan(rows: rows, currentValue: "44100", target: target) == nil)
        #expect(PopupRowPick.plan(rows: [rows[0]], currentValue: "48000", target: current) == nil)
    }

    @Test("a long list wraps the shorter way")
    func wrap() throws {
        let labels = ["8000", "11025", "16000", "22050", "32000", "44100", "48000", "88200", "96000"]
        let rows = labels.enumerated().map { [element("text|\($1)", $1, globalY: 1698 + CGFloat($0) * 28)] }
        let last = try #require(rows.last?.first)
        let plan = try #require(PopupRowPick.plan(rows: rows, currentValue: "8000", target: last))
        #expect(plan.delta == -1)
    }

    @Test("type-ahead takes the first word after any glyph")
    func typeAhead() {
        #expect(PopupRowPick.typeAheadPrefix(for: "✓ ProRes 422") == "ProRes")
        #expect(PopupRowPick.typeAheadPrefix(for: "96000") == "96000")
        #expect(PopupRowPick.typeAheadPrefix(for: "•••") == "")
    }
}
