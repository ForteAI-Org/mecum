import Foundation
import CoreGraphics

/// Correlates an AX window (known by bundle id, frame, and optional title) to a captured window,
/// purely from public signals. Frame overlap (IoU) is the primary, reliable key — both AX window
/// frames and `SCWindow.frame` are top-left global points; title and z-order break ties.
public enum WindowCorrelator {

    /// Best matching window, or `nil` if none is geometrically plausible.
    /// - Parameter minIoU: required frame intersection-over-union floor (default 0.5).
    public static func correlate<W: CorrelatableWindow>(
        axWindowFrameGlobalPt: CGRect,
        bundleID: String,
        title: String?,
        among windows: [W],
        minIoU: Double = 0.5
    ) -> W? {
        // 1) Same app, 2) geometrically plausible (IoU floor).
        let plausible = windows.filter {
            $0.bundleID == bundleID && iou(axWindowFrameGlobalPt, $0.frameGlobalPt) >= minIoU
        }
        guard !plausible.isEmpty else { return nil }

        // Score: IoU dominates; exact title match is a strong boost; on-screen + frontmost break ties.
        func score(_ w: W) -> Double {
            var s = iou(axWindowFrameGlobalPt, w.frameGlobalPt)
            if let title, !title.isEmpty, w.title == title { s += 0.25 }
            if w.isOnScreen { s += 0.01 }
            s -= Double(max(w.windowLayer, 0)) * 0.0001   // prefer frontmost (lower layer)
            return s
        }
        return plausible.max { score($0) < score($1) }
    }

    /// Intersection-over-union of two rects (0 if disjoint or degenerate).
    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = Double(inter.width * inter.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - interArea
        return union > 0 ? interArea / union : 0
    }
}
