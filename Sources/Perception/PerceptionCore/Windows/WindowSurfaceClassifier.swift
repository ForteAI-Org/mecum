//
//  WindowSurfaceClassifier.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// WindowSurfaceClassifier decides, in one pass over one window list, which windows are open
/// pop-ups and which single window is the interaction surface.
///
/// One decision answers both questions on purpose. Two separate walks once disagreed: a dropdown
/// drawn as an ordinary window was captured as the scene and reported as "no pop-up open" at the
/// same time, and every pop-up path sat behind a gate that said there was none.
public enum WindowSurfaceClassifier {

    // MARK: Gates

    /// A pop-up is at least this wide; below it a "menu" is a drag shadow or a sliver.
    public static let popupMinSide: CGFloat = 60
    /// A menu-layer pop-up is at least this tall: one row. A two-item list measured 220 by 56
    /// points; under a square floor it was filed as a sliver and the engine clicked through it.
    /// The square floor stays for the window-layer guess, where an untitled sliver is usually chrome.
    public static let popupMinHeight: CGFloat = 20
    /// A list is never much wider than tall; a short wide modal of the same containment is not one.
    public static let listMaxAspect: CGFloat = 1.35
    /// A dropdown is a fraction of what it hangs over; a dialog over its main window is not.
    public static let parentAreaRatio: CGFloat = 3
    public static let parentWidthShare: CGFloat = 0.5
    /// A dropdown is drawn over its parent, even when it overflows the parent's bottom edge.
    public static let parentOverlap: CGFloat = 0.75
    /// A docked palette shares two or three of its parent's edges; a list hanging off a control
    /// shares none.
    public static let maxSharedEdges = 1
    private static let edgeSlop: CGFloat = 2

    /// Layers where a toolkit parks an open pop-up menu, bounded well below cursor and screensaver
    /// layers. Not the only way a pop-up is recognized: see `floatingList`.
    public static func isPopupLayer(_ layer: Int) -> Bool { (21...200).contains(layer) }

    /// Layers worth driving: documents, and the floating layers pro apps park modals and palettes on.
    public static func isWindowLayer(_ layer: Int) -> Bool { (0...20).contains(layer) }

    /// Big enough to be a window a person works in rather than a tooltip, badge or drag shadow.
    public static func isSubstantialWindow(_ rect: CGRect) -> Bool {
        rect.width >= 200 && rect.height >= 90 && rect.width * rect.height >= 40_000
    }

    // MARK: Classification

    /// Classifies a front-to-back window list. `allowFloatingLists` turns the window-layer dropdown
    /// rule off, leaving menu-layer detection exactly as it is.
    public static func classify(_ rows: [WindowRow], allowFloatingLists: Bool = true) -> WindowSurfaces {
        let titlesLegible = rows.contains { !$0.isUntitled }
        var verdicts: [SurfaceVerdict] = []
        var popups: [CGRect] = []
        // The picker's three candidates: an open pop-up wins outright, else the frontmost substantial
        // window, else the largest layer-zero window.
        var interaction: WindowRow?
        var frontSubstantial: WindowRow?
        var largest: WindowRow?
        var largestArea: CGFloat = 0
        var realWindowInFront: WindowRow?

        for (index, row) in rows.enumerated() {
            let rect = row.frame
            if isPopupLayer(row.layer) {
                if rect.width >= popupMinSide, rect.height >= popupMinHeight {
                    verdicts.append(SurfaceVerdict(row: row, kind: .popupLayer, why: "menu layer \(row.layer)"))
                    popups.append(rect)
                    if interaction == nil { interaction = row }
                } else {
                    let why = String(
                        format: "menu layer %d but %.0f×%.0f, a sliver", row.layer, rect.width, rect.height
                    )
                    verdicts.append(SurfaceVerdict(row: row, kind: .chrome, why: why))
                }
                continue
            }
            guard isWindowLayer(row.layer) else {
                verdicts.append(SurfaceVerdict(row: row, kind: .chrome, why: "layer \(row.layer) is chrome"))
                continue
            }
            if allowFloatingLists, realWindowInFront == nil {
                switch floatingList(row, behind: Array(rows[(index + 1)...]), titlesLegible: titlesLegible) {
                    case .yes(let why):
                        verdicts.append(SurfaceVerdict(row: row, kind: .floatingList, why: why))
                        popups.append(rect)
                        if interaction == nil { interaction = row }
                        continue
                    case .no(let why):
                        verdicts.append(SurfaceVerdict(row: row, kind: classifyOrdinary(rect), why: why))
                }
            } else if let front = realWindowInFront {
                let name = front.title.flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "the front window"
                verdicts.append(SurfaceVerdict(
                    row : row,
                    kind: classifyOrdinary(rect),
                    why : "behind \(name), only the frontmost surface can be an open pop-up"
                ))
            } else {
                verdicts.append(SurfaceVerdict(row: row, kind: classifyOrdinary(rect), why: "ordinary window"))
            }
            guard rect.width > 50, rect.height > 50 else { continue }
            if realWindowInFront == nil { realWindowInFront = row }
            if row.layer == 0, area(rect) > largestArea {
                largestArea = area(rect)
                largest = row
            }
            if frontSubstantial == nil, isSubstantialWindow(rect) { frontSubstantial = row }
        }
        return WindowSurfaces(
            verdicts   : verdicts,
            popups     : popups,
            interaction: interaction ?? frontSubstantial ?? largest
        )
    }

    /// The verdict on a frontmost ordinary window that may be an open dropdown.
    public enum FloatingListVerdict: Sendable, Equatable {
        /// Why it is one: which parent it hangs over.
        case yes(String)
        /// The first clause that failed, with its numbers.
        case no(String)
    }

    /// Decides whether a frontmost ordinary window is an open dropdown. `titlesLegible` is the
    /// honesty gate: "untitled" is evidence only when titles are readable at all, and without the
    /// Screen Recording grant every title is nil.
    public static func floatingList(
        _ window     : WindowRow,
        behind       : [WindowRow],
        titlesLegible: Bool
    ) -> FloatingListVerdict {
        guard titlesLegible else {
            return .no("window titles unreadable (Screen Recording?), the untitled clause cannot be trusted")
        }
        guard window.isUntitled else {
            let title = window.title ?? ""
            return .no("titled \"\(title.count <= 30 ? title : "…" + title.suffix(27))\", a real window")
        }
        let rect = window.frame
        guard rect.width >= popupMinSide, rect.height >= popupMinSide else {
            return .no(String(
                format: "%.0f×%.0f is under the %.0fpt pop-up floor", rect.width, rect.height, popupMinSide
            ))
        }
        guard rect.width <= listMaxAspect * rect.height else {
            return .no(String(
                format: "w/h %.1f > %.2f, dialog shape, not a list", rect.width / max(rect.height, 1), listMaxAspect
            ))
        }
        let parents = behind.filter { isWindowLayer($0.layer) }
        guard !parents.isEmpty else { return .no("no window of this app behind it to be a dropdown of") }
        var firstFailure: String?
        for parent in parents {
            let bounds = parent.frame
            let ratio = area(bounds) / max(area(rect), 1)
            let overlap = overlapFraction(rect, in: bounds)
            let share = rect.width / max(bounds.width, 1)
            let shared = sharedEdges(rect, bounds)
            if ratio >= parentAreaRatio, overlap >= parentOverlap, share <= parentWidthShare, shared <= maxSharedEdges {
                return .yes(String(
                    format: "list over a %.0f×%.0f parent (%.0f× its area, %.0f%% inside, %.2f of its width)",
                    bounds.width, bounds.height, ratio, overlap * 100, share
                ))
            }
            if firstFailure == nil {
                if ratio < parentAreaRatio {
                    firstFailure = String(
                        format: "only %.1f× smaller than the %.0f×%.0f window behind it (need %.0f×)",
                        ratio, bounds.width, bounds.height, parentAreaRatio
                    )
                } else if overlap < parentOverlap {
                    firstFailure = String(format: "only %.0f%% inside the %.0f×%.0f window behind it (need %.0f%%)",
                                          overlap * 100, bounds.width, bounds.height, parentOverlap * 100)
                } else if share > parentWidthShare {
                    firstFailure = String(format: "width share %.2f > %.2f of the %.0f×%.0f parent",
                                          share, parentWidthShare, bounds.width, bounds.height)
                } else {
                    firstFailure = "hugs \(shared) edges of the window behind it, a docked palette, not a list"
                }
            }
        }
        return .no(firstFailure ?? "no parent qualifies")
    }

    private static func classifyOrdinary(_ rect: CGRect) -> SurfaceKind {
        rect.width > 50 && rect.height > 50 ? .window : .chrome
    }

    // MARK: Geometry

    static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// How much of `rect` lies inside `bounds`, as a fraction of `rect`.
    static func overlapFraction(_ rect: CGRect, in bounds: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        return area(intersection) / max(area(rect), 1)
    }

    /// How many of `bounds`'s four edges `rect` sits flush against.
    static func sharedEdges(_ rect: CGRect, _ bounds: CGRect) -> Int {
        var count = 0
        if abs(rect.minX - bounds.minX) <= edgeSlop { count += 1 }
        if abs(rect.minY - bounds.minY) <= edgeSlop { count += 1 }
        if abs(rect.maxX - bounds.maxX) <= edgeSlop { count += 1 }
        if abs(rect.maxY - bounds.maxY) <= edgeSlop { count += 1 }
        return count
    }
}
