//
//  PopupRowPick.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import PerceptionCore

/// PopupRowPick plans how to choose a row of an open pop-up list with the keyboard: which row the
/// highlight starts on, which row is wanted, and the shortest way between them.
///
/// It exists because on a background seat every mouse path failed: a prepared click's restore
/// dismisses the list, an unprepared one never arrives, and a hover needs a pointer the fence keeps
/// off that display. A menu opens with the current value highlighted, the arrows move the highlight
/// and wrap at both ends, Return chooses. All of that was measured on Premiere's Sample Rate list.
/// Pure geometry over a scene and two frames, so a test decides it without a screen.
public enum PopupRowPick {

    /// The plan: rows top to bottom, the highlight's row, the wanted row, and the signed number of
    /// arrow presses (negative means up), already the shorter way round the wrap.
    public struct Plan: Sendable, Equatable {
        public let rowLabels: [[String]]
        public let currentIndex: Int
        public let targetIndex: Int
        public let delta: Int

        public init(rowLabels: [[String]], currentIndex: Int, targetIndex: Int, delta: Int) {
            self.rowLabels    = rowLabels
            self.currentIndex = currentIndex
            self.targetIndex  = targetIndex
            self.delta        = delta
        }

        /// The route as a person would say it: "1↓ + Return".
        public var route: String { "\(abs(delta))\(delta >= 0 ? "↓" : "↑") + Return" }
    }

    /// The scene's elements whose centers lie inside the pop-up, grouped into rows by their vertical
    /// band (a state glyph and its label share a row), top to bottom.
    public static func rows(in scene: SceneSnapshot, windowFrame: CGRect, popupFrame: CGRect) -> [[SceneElement]] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        let inside = scene.elements.filter { element in
            let center = element.bounds.center
            let global = CGPoint(
                x: windowFrame.minX + center.x * windowFrame.width,
                y: windowFrame.minY + center.y * windowFrame.height
            )
            return popupFrame.insetBy(dx: -2, dy: -2).contains(global)
        }.sorted { $0.bounds.midY < $1.bounds.midY }
        var rows: [[SceneElement]] = []
        for element in inside {
            let y = element.bounds.midY * windowFrame.height
            if let reference = rows.last?.first, abs(y - reference.bounds.midY * windowFrame.height) < 8 {
                rows[rows.count - 1].append(element)
            } else {
                rows.append([element])
            }
        }
        return rows
    }

    /// Plans the keys from the control's current value and the wanted element, or nil when either row
    /// cannot be found among the pop-up's rows or the list has a single row.
    public static func plan(rows: [[SceneElement]], currentValue: String, target: SceneElement) -> Plan? {
        guard rows.count >= 2 else { return nil }
        let want = LabelText.normalize(currentValue)
        guard !want.isEmpty,
              let currentIndex = rows.firstIndex(where: { $0.contains { LabelText.normalize($0.label) == want } }),
              let targetIndex = rows.firstIndex(where: { $0.contains { $0.id == target.id } })
        else { return nil }
        var delta = targetIndex - currentIndex
        if abs(delta) > rows.count / 2 { delta += delta > 0 ? -rows.count : rows.count }
        return Plan(
            rowLabels   : rows.map { $0.map(\.label) },
            currentIndex: currentIndex,
            targetIndex : targetIndex,
            delta       : delta
        )
    }

    /// The typeable head of a label for a menu's own type-ahead: leading glyphs dropped, first word
    /// only, because a space dismisses some menus without selecting.
    public static func typeAheadPrefix(for label: String) -> String {
        let glyphless = label.drop(while: { !$0.isLetter && !$0.isNumber })
        return String(glyphless.prefix(while: { $0 != " " }))
    }
}
