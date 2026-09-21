import CoreGraphics
import Foundation

/// Geometry for drawing diagnostics only on the visible parts of a captured app window.
public enum WindowVisibility {
    public static func pieces(of region: CGRect, excluding occluders: [CGRect]) -> [CGRect] {
        guard !region.isNull, !region.isEmpty, !region.isInfinite else { return [] }
        var pieces = [region]
        for occluder in occluders {
            pieces = pieces.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(occluder)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                    CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                    CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
        }
        return pieces
    }

    /// The list is front to back. Stop at the actual captured window and subtract everything above
    /// it, except our own click-through overlays. A vanished window cannot own a visible overlay.
    public static func visibleRegions(window frame: CGRect, pid: pid_t, within region: CGRect) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return visibleRegions(window: frame, pid: pid, within: region, windowInfo: windows,
            ownPID: ProcessInfo.processInfo.processIdentifier, displayFrames: displays.map(CGDisplayBounds))
    }

    /// Injectable WindowServer snapshot so visibility policy is tested as well as rectangle subtraction.
    static func visibleRegions(window frame: CGRect, pid: pid_t, within region: CGRect,
                               windowInfo windows: [[String: Any]], ownPID: pid_t,
                               displayFrames: [CGRect]) -> [CGRect] {
        var occluders: [CGRect] = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  owner != ownPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if owner == pid, abs(rect.minX - frame.minX) < 1, abs(rect.minY - frame.minY) < 1,
               abs(rect.width - frame.width) < 1, abs(rect.height - frame.height) < 1 {
                return pieces(of: region.intersection(frame), excluding: occluders)
            }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            // Dock's screen-sized layer-20 surface is a transparent desktop canvas. WindowServer's
            // alpha=1 describes window opacity, not per-pixel coverage; subtracting its bounding box
            // hides every diagnostic. Keep real Dock windows and other floating windows as occluders.
            let displayUnion = displayFrames.reduce(CGRect.null) { $0.union($1) }
            let isDockCanvas = window[kCGWindowOwnerName as String] as? String == "Dock"
                && layer == 20 && (displayFrames + [displayUnion]).contains(rect)
            if !isDockCanvas, (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
               layer >= 0 { occluders.append(rect) }
        }
        return []
    }
}
