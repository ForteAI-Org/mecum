import Foundation
import CoreGraphics
import LocatorCore

/// Pure geometry assembly for the descriptor builder. Separated from the live gathering (AX hit-test,
/// capture, OCR, CV) so the resize-tolerant normalization is unit-testable without any OS dependency.
public enum DescriptorAssembler {

    /// The element CENTER as a fraction (0…1) of the window — resize-tolerant. Both rects are in the
    /// same space (global points). Clamped to [0,1] for elements within the window.
    public static func windowRelativeCenter(elementGlobalPt e: CGRect, windowGlobalPt w: CGRect) -> CGPoint {
        let x = w.width > 0 ? (e.midX - w.minX) / w.width : 0
        let y = w.height > 0 ? (e.midY - w.minY) / w.height : 0
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    /// Element size in pixels (points × backing scale).
    public static func sizePx(elementGlobalPt e: CGRect, backingScale: CGFloat) -> CGSize {
        CGSize(width: e.width * backingScale, height: e.height * backingScale)
    }

    /// Anchor tracking the element's offset from the window's nearest corner (in pixels), so it
    /// survives non-uniform window resize better than a single fixed origin.
    public static func anchor(elementGlobalPt e: CGRect, windowGlobalPt w: CGRect, backingScale: CGFloat) -> Anchor {
        // Distance from element top-left to each window corner; pick the nearest.
        let corners: [(name: String, point: CGPoint)] = [
            ("topLeft", CGPoint(x: w.minX, y: w.minY)),
            ("topRight", CGPoint(x: w.maxX, y: w.minY)),
            ("bottomLeft", CGPoint(x: w.minX, y: w.maxY)),
            ("bottomRight", CGPoint(x: w.maxX, y: w.maxY)),
        ]
        let origin = e.origin
        let nearest = corners.min { a, b in
            hypot(origin.x - a.point.x, origin.y - a.point.y) < hypot(origin.x - b.point.x, origin.y - b.point.y)
        }!
        let offset = CGPoint(x: (origin.x - nearest.point.x) * backingScale,
                             y: (origin.y - nearest.point.y) * backingScale)
        return Anchor(type: "window_origin", container: nearest.name, offsetPx: offset)
    }

    /// A CV scroll-region hypothesis ANCHORED ON THE CLICK, for an element that has an AX leaf but no
    /// detectable `AXScrollArea` (Slack / Electron expose the leaf yet no settable scroll bar). A box
    /// centered on the clicked element spanning a generous fraction of the window — so the relocator can
    /// scroll-SEARCH the element back into view and measure movement on the content the user actually
    /// scrolled, and the opaque driver delivers the wheel at that click. Window-normalized (0..1), clamped
    /// to the window so it can't spill off an edge. Pure → unit-tested.
    public static func clickAnchoredRegionNorm(elementGlobalPt e: CGRect, windowGlobalPt w: CGRect,
                                               widthFrac: CGFloat = 0.5, heightFrac: CGFloat = 0.6) -> CGRect {
        guard w.width > 0, w.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let width = min(1, max(0.1, widthFrac)), height = min(1, max(0.1, heightFrac))
        let cx = (e.midX - w.minX) / w.width
        let cy = (e.midY - w.minY) / w.height
        let x = min(max(0, cx - width / 2), 1 - width)
        let y = min(max(0, cy - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Assemble the geometry descriptor from element + window frames.
    public static func geometry(elementGlobalPt e: CGRect, windowGlobalPt w: CGRect, backingScale: CGFloat,
                                scrollState: [String: Double]? = nil) -> GeometryDescriptor {
        GeometryDescriptor(
            windowRelative: windowRelativeCenter(elementGlobalPt: e, windowGlobalPt: w),
            sizePx: sizePx(elementGlobalPt: e, backingScale: backingScale),
            anchor: anchor(elementGlobalPt: e, windowGlobalPt: w, backingScale: backingScale),
            scrollStateAtCapture: scrollState
        )
    }

    /// A self-heal update: the descriptor re-pointed at where a lower stage just found the element in
    /// the current window. Conservative — updates only `windowRelative` (drift correction) + bumps
    /// `version` and `lastVerified`; the crops/edge-hash are left intact so a marginal match can't
    /// poison the visual reference. `now` is injected for deterministic testing.
    public static func healed(_ d: Descriptor, foundRectPx: CGRect, currentWindowPx: CGSize, now: Date) -> Descriptor {
        var updated = d
        let cx = currentWindowPx.width > 0 ? foundRectPx.midX / currentWindowPx.width : d.geometry.windowRelative.x
        let cy = currentWindowPx.height > 0 ? foundRectPx.midY / currentWindowPx.height : d.geometry.windowRelative.y
        updated.geometry.windowRelative = CGPoint(x: min(1, max(0, cx)), y: min(1, max(0, cy)))
        updated.version += 1
        updated.lastVerified = now
        return updated
    }

    /// Expected element pixel rect for the CURRENT window, used by stage 2 to seed its NCC search
    /// region. The center comes from the scale-independent window-relative position scaled to the
    /// current window pixels; the stored `sizePx` (capture-time pixels) is rescaled by the
    /// current/capture window-pixel ratio so it stays correct across window resize AND a backing-scale
    /// change (e.g. moving the window to a non-Retina display). When capture == current, this is identity.
    public static func expectedRectImagePx(geometry g: GeometryDescriptor,
                                           captureWindowPixelSize capture: CGSize,
                                           currentWindowPixelSize current: CGSize) -> CGRect {
        let cx = g.windowRelative.x * current.width
        let cy = g.windowRelative.y * current.height
        let sx = capture.width > 0 ? current.width / capture.width : 1
        let sy = capture.height > 0 ? current.height / capture.height : 1
        let w = g.sizePx.width * sx
        let h = g.sizePx.height * sy
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
