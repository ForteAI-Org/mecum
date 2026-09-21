import CoreGraphics

/// One row of `CGWindowListCopyWindowInfo`, reduced to what "is this a window we drive, or an open
/// pop-up?" actually needs. FRONT-TO-BACK z-order is the ARRAY order, exactly as CGWindowList hands
/// it over. Pure data — so the classifier below is decided by tests, not by a screen.
public struct WindowRow: Sendable, Equatable {
    public let layer: Int
    public let frameGlobalPt: CGRect
    public let title: String?
    public let number: Int          // kCGWindowNumber — only for the diagnostic to name a window

    public init(layer: Int, frameGlobalPt: CGRect, title: String? = nil, number: Int = 0) {
        self.layer = layer; self.frameGlobalPt = frameGlobalPt; self.title = title; self.number = number
    }

    var isUntitled: Bool { (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// What a window IS, for the two questions the engine asks of a window list.
public enum SurfaceKind: String, Sendable {
    case popupLayer     // a pop-up parked on a menu layer (21…200) — AppKit, Premiere, Pro Tools
    case floatingList   // a dropdown drawn as an ORDINARY window (Qt/GPU toolkits — DaVinci Resolve)
    case window         // a window we're willing to drive: document, modal, floating palette
    case chrome         // status items, tooltips, drag shadows, slivers — never the surface
}

/// One window, its verdict, and the clause that decided it. The `why` exists so a MISS carries the
/// next move (ticket 09): `debug-popup --windows` prints it, so "the detector didn't see my dropdown"
/// comes back as "rejected: width share 0.62 > 0.50 of the 1040×736 parent" instead of silence.
public struct SurfaceVerdict: Sendable {
    public let row: WindowRow
    public let kind: SurfaceKind
    public let why: String
}

/// The classifier's answers about ONE app's windows: what is open on top of it, and what we drive.
public struct WindowSurfaces: Sendable {
    public let verdicts: [SurfaceVerdict]                  // front-to-back, every row
    public let popups: [CGRect]                            // front-to-back
    public let interaction: WindowCaptureService.WindowProbe?
}

/// ONE decision, for both questions — because two answers is what ticket 12 was.
///
/// `frontmostWindowFrame` (which window do we capture and click?) and `openPopupFrames` (is a pop-up
/// open?) used to walk CGWindowList separately, each with its own gates. They agreed on menu-layer
/// pop-ups and diverged on everything else, so DaVinci's resolution list — an ORDINARY window as far
/// as CGWindowList is concerned — was captured as the scene AND reported as "no pop-up open". The
/// scene was built from the list's own pixels while every pop-up path (AX items, the zero-AX row cut,
/// the "open menu" section, the "don't activate: it would cancel menu tracking" rule) sat behind a
/// gate that said there was no pop-up. Both answers now come from this one pass.
public enum WindowSurfaceClassifier {

    // MARK: - the gates, named and numbered

    /// A pop-up is at least this big on both sides (below it, a "menu" is a drag shadow or a sliver).
    public static let popupMinSide: CGFloat = 60
    /// A LIST is never much wider than tall. Pro Tools' "New Tracks" modal is 815×124 (w/h 6.6) and is
    /// contained in a far bigger window exactly like a dropdown is — shape is what separates them.
    public static let listMaxAspect: CGFloat = 1.35
    /// A dropdown is a fraction of what it hangs over: DaVinci's resolution list is ~260×420pt over a
    /// 1040×736pt dialog (7×). The dialog itself is only 1.3× smaller than the main window it covers,
    /// so this gate is what stops a dialog reading as a list of the window behind it.
    public static let parentAreaRatio: CGFloat = 3
    /// …and it is narrow against that parent.
    public static let parentWidthShare: CGFloat = 0.5
    /// …and it is DRAWN OVER it (a dropdown that overflows its parent's bottom edge still mostly sits
    /// inside it).
    public static let parentOverlap: CGFloat = 0.75
    /// …without HUGGING it: a docked palette shares two or three of its parent's edges, a list hangs
    /// off a control in the middle and shares none.
    public static let maxSharedEdges = 1
    private static let edgeSlop: CGFloat = 2

    // MARK: - the window-layer pop-up

    public enum FloatingListVerdict: Sendable, Equatable {
        case yes(String)    // why it is one — which parent it hangs over
        case no(String)     // the FIRST clause that failed, with its numbers
    }

    /// Is this frontmost ordinary window actually an open dropdown? Toolkits that draw their own
    /// widgets (Qt in DaVinci Resolve) park a combo's list on a NORMAL window layer, so the layer
    /// number cannot answer it and the geometry has to.
    ///
    /// `titlesLegible` is the honesty gate: "untitled" is only evidence when titles are readable at
    /// all. Without Screen Recording every `kCGWindowName` is nil, and a modal dialog would read as a
    /// dropdown — so with no title anywhere the rule declines and behaviour stays exactly as it was.
    public static func floatingList(_ w: WindowRow, behind: [WindowRow],
                                    titlesLegible: Bool) -> FloatingListVerdict {
        guard titlesLegible else {
            return .no("window titles unreadable (Screen Recording?) — the untitled clause can't be trusted")
        }
        guard w.isUntitled else {
            // Trimmed: document titles are often full paths, and this clause is read in a table.
            let t = w.title ?? ""
            return .no("titled \"\(t.count <= 30 ? t : "…" + t.suffix(27))\" — a real window")
        }
        let r = w.frameGlobalPt
        guard r.width >= popupMinSide, r.height >= popupMinSide else {
            return .no(String(format: "%.0f×%.0f is under the %.0fpt pop-up floor",
                              r.width, r.height, popupMinSide))
        }
        guard r.width <= listMaxAspect * r.height else {
            return .no(String(format: "w/h %.1f > %.2f — dialog shape, not a list",
                              r.width / max(r.height, 1), listMaxAspect))
        }
        let parents = behind.filter { WindowCaptureService.isWindowLayer($0.layer) }
        guard !parents.isEmpty else { return .no("no window of this app behind it to be a dropdown of") }
        var firstFailure: String?
        for p in parents {
            let b = p.frameGlobalPt
            let ratio = area(b) / max(area(r), 1)
            let overlap = overlapFraction(r, in: b)
            let share = r.width / max(b.width, 1)
            let shared = sharedEdges(r, b)
            if ratio >= parentAreaRatio, overlap >= parentOverlap,
               share <= parentWidthShare, shared <= maxSharedEdges {
                return .yes(String(format: "list over a %.0f×%.0f parent (%.0f× its area, %.0f%% inside, %.2f of its width)",
                                   b.width, b.height, ratio, overlap * 100, share))
            }
            if firstFailure == nil {
                if ratio < parentAreaRatio {
                    firstFailure = String(format: "only %.1f× smaller than the %.0f×%.0f window behind it (need %.0f×)",
                                          ratio, b.width, b.height, parentAreaRatio)
                } else if overlap < parentOverlap {
                    firstFailure = String(format: "only %.0f%% inside the %.0f×%.0f window behind it (need %.0f%%)",
                                          overlap * 100, b.width, b.height, parentOverlap * 100)
                } else if share > parentWidthShare {
                    firstFailure = String(format: "width share %.2f > %.2f of the %.0f×%.0f parent",
                                          share, parentWidthShare, b.width, b.height)
                } else {
                    firstFailure = "hugs \(shared) edges of the window behind it — a docked palette, not a list"
                }
            }
        }
        return .no(firstFailure ?? "no parent matched")
    }

    // MARK: - the one pass

    public static func classify(_ rows: [WindowRow], allowFloatingLists: Bool = true) -> WindowSurfaces {
        let titlesLegible = rows.contains { !$0.isUntitled }
        var verdicts: [SurfaceVerdict] = []
        var popups: [CGRect] = []
        // The picker's three candidates, unchanged from the day this file was written: an open pop-up
        // wins outright, else the frontmost SUBSTANTIAL window (a modal beats the document behind it),
        // else the largest layer-0 window (a floating palette must never win the fallback by size).
        var interaction: WindowRow?
        var frontSubstantial: WindowRow?
        var largest: WindowRow?
        var largestArea: CGFloat = 0
        // A window-layer dropdown is only the interaction surface while nothing REAL is in front of it
        // (with a submenu up, two pop-ups can stack — that stays allowed).
        var realWindowInFront: WindowRow?

        for (i, row) in rows.enumerated() {
            let r = row.frameGlobalPt
            if WindowCaptureService.isPopupLayer(row.layer) {
                if r.width >= popupMinSide, r.height >= popupMinSide {
                    verdicts.append(.init(row: row, kind: .popupLayer, why: "menu layer \(row.layer)"))
                    popups.append(r)
                    if interaction == nil { interaction = row }
                } else {
                    verdicts.append(.init(row: row, kind: .chrome,
                                          why: String(format: "menu layer %d but %.0f×%.0f — a sliver",
                                                      row.layer, r.width, r.height)))
                }
                continue
            }
            guard WindowCaptureService.isWindowLayer(row.layer) else {
                verdicts.append(.init(row: row, kind: .chrome, why: "layer \(row.layer) is chrome"))
                continue
            }
            // The floating-list test only makes sense for the front-most ordinary window.
            if allowFloatingLists, realWindowInFront == nil {
                switch floatingList(row, behind: Array(rows[(i + 1)...]), titlesLegible: titlesLegible) {
                case .yes(let why):
                    verdicts.append(.init(row: row, kind: .floatingList, why: why))
                    popups.append(r)
                    if interaction == nil { interaction = row }
                    continue
                case .no(let why):
                    verdicts.append(.init(row: row, kind: classifyOrdinary(r), why: why))
                }
            } else if let front = realWindowInFront {
                verdicts.append(.init(row: row, kind: classifyOrdinary(r),
                                      why: "behind \(front.title.flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "the front window") — only the frontmost surface can be an open pop-up"))
            } else {
                verdicts.append(.init(row: row, kind: classifyOrdinary(r), why: "ordinary window"))
            }
            guard r.width > 50, r.height > 50 else { continue }     // tooltips, badges, drag shadows
            if realWindowInFront == nil { realWindowInFront = row }
            if row.layer == 0, area(r) > largestArea { largestArea = area(r); largest = row }
            if frontSubstantial == nil, WindowCaptureService.isSubstantialWindow(r) { frontSubstantial = row }
        }
        let chosen = interaction ?? frontSubstantial ?? largest
        return WindowSurfaces(verdicts: verdicts, popups: popups,
                              interaction: chosen.map {
                                  WindowCaptureService.WindowProbe(title: $0.title, frameGlobalPt: $0.frameGlobalPt)
                              })
    }

    private static func classifyOrdinary(_ r: CGRect) -> SurfaceKind {
        (r.width > 50 && r.height > 50) ? .window : .chrome
    }

    // MARK: - geometry

    static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// How much of `r` lies inside `b`, as a fraction of `r`.
    static func overlapFraction(_ r: CGRect, in b: CGRect) -> CGFloat {
        let i = r.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        return area(i) / max(area(r), 1)
    }

    /// How many of `b`'s four edges `r` sits flush against. A docked palette shares two or three; a
    /// dropdown hanging off a control shares none.
    static func sharedEdges(_ r: CGRect, _ b: CGRect) -> Int {
        var n = 0
        if abs(r.minX - b.minX) <= edgeSlop { n += 1 }
        if abs(r.minY - b.minY) <= edgeSlop { n += 1 }
        if abs(r.maxX - b.maxX) <= edgeSlop { n += 1 }
        if abs(r.maxY - b.maxY) <= edgeSlop { n += 1 }
        return n
    }
}
