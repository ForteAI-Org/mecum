//
//  PopupRowPickRefusalTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

/// Why `PopupRowPick` has no plan: `planning` answers the reason in the order `plan` checks, and `plan` is
/// `planning`'s success, for the painted rows and for the named rows. The labels are synthetic: the menu of
/// the S4 campaign as its message listed it (`Alpha, V Beta, Gamma`), not a replay of what was perceived.
@Suite("Pop-up row pick: why there is no plan")
struct PopupRowPickRefusalTests {

    private static let menu = CGRect(x: 0, y: 0, width: 120, height: 90)

    private static func rows(_ labels: [String]) -> (rows: [[SceneElement]], elements: [SceneElement]) {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "row|\(index)", kind: .text, label: label,
                         bounds: NormalizedRect(x: 0.1, y: 0.05 + Double(index) * 0.3, width: 0.8, height: 0.2))
        }
        let scene = SceneSnapshot(bundleID: "x", appName: "X", windowTitle: "Dropdown",
                                  viewportPixelSize: ViewportPixelSize(width: 240, height: 180), elements: elements)
        return (PopupRowPick.rows(in: scene, windowFrame: menu, popupFrame: menu), elements)
    }

    private static func named(_ titles: [String]) -> [PopupRow] {
        titles.enumerated().map { PopupRow(title: $1, order: $0) }
    }

    @Test("painted rows: each reason, in order, and plan is planning's success")
    func paintedRows() throws {
        let (menu, elements) = Self.rows(["Alpha", "V Beta", "Gamma"])
        let (single, singleElements) = Self.rows(["Alpha"])
        let stranger = SceneElement(id: "elsewhere", kind: .text, label: "Alpha", bounds: NormalizedRect(x: 0, y: 0, width: 0, height: 0))
        #expect(PopupRowPick.planning(rows: single, currentValue: "Alpha", target: singleElements[0]) == .failure(.tooFewRows(1)))
        #expect(PopupRowPick.planning(rows: menu, currentValue: " · ", target: elements[0]) == .failure(.currentValueEmpty))
        #expect(PopupRowPick.planning(rows: menu, currentValue: "Beta", target: elements[0]) == .failure(.currentValueNotAmongRows))
        #expect(PopupRowPick.planning(rows: menu, currentValue: "V Beta", target: stranger) == .failure(.targetNotAmongRows))
        #expect(PopupRowPick.plan(rows: menu, currentValue: "Beta", target: elements[0]) == nil)
        let planned = PopupRowPick.planning(rows: menu, currentValue: "V Beta", target: elements[0], wraps: false)
        #expect(try planned.get().delta == -1)
        #expect(PopupRowPick.plan(rows: menu, currentValue: "V Beta", target: elements[0], wraps: false) == (try? planned.get()))
    }

    @Test("named rows: each reason, in order, and plan is planning's success")
    func namedRows() throws {
        let rows = Self.named(["Alpha", "Beta", "Gamma"])
        #expect(PopupRowPick.planning(rows: Self.named(["Alpha"]), currentValue: "Alpha", target: "Beta") == .failure(.tooFewRows(1)))
        #expect(PopupRowPick.planning(rows: [], currentValue: "Alpha", target: "Beta") == .failure(.tooFewRows(0)))
        #expect(PopupRowPick.planning(rows: rows, currentValue: "", target: "Beta") == .failure(.currentValueEmpty))
        #expect(PopupRowPick.planning(rows: rows, currentValue: "Alpha", target: "··") == .failure(.targetNotAmongRows))
        #expect(PopupRowPick.planning(rows: rows, currentValue: "Delta", target: "Beta") == .failure(.currentValueNotAmongRows))
        #expect(PopupRowPick.planning(rows: rows, currentValue: "Beta", target: "Omega") == .failure(.targetNotAmongRows))
        #expect(try PopupRowPick.planning(rows: rows, currentValue: "Beta", target: "Alpha").get().delta == -1)
        #expect(PopupRowPick.plan(rows: rows, currentValue: "Beta", target: "Alpha")?.delta == -1)
    }
}
