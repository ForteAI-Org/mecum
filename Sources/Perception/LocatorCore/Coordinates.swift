import Foundation
import CoreGraphics

/// The single home for all coordinate-space conversions. **Never do ad-hoc coordinate arithmetic
/// elsewhere** — most bugs in this project are coordinate bugs.
///
/// Three conventions are in play:
///
/// | Space               | Origin       | Units  |
/// |---------------------|--------------|--------|
/// | AX global           | top-left     | points |
/// | Image pixel         | top-left     | pixels |
/// | Vision normalized   | bottom-left  | 0..1   |
///
/// AX-global and image-pixel are both top-left, so converting between them is a translate-and-scale.
/// Only Vision needs the Y-flip.
public struct WindowCoordinateContext: Equatable, Sendable {
    /// The window's `kAXPositionAttribute` (top-left, global points).
    public let axWindowOriginGlobalPt: CGPoint
    /// The window's display `backingScaleFactor` (2.0 on Retina).
    public let backingScale: CGFloat
    /// The captured `CGImage` size in pixels.
    public let imagePixelSize: CGSize

    public init(axWindowOriginGlobalPt: CGPoint, backingScale: CGFloat, imagePixelSize: CGSize) {
        // A non-positive / non-finite scale would silently produce NaN/inf coordinates that only
        // surface much later (e.g. as a JSON-encode failure). A display backing scale is always a
        // positive finite value (1.0/2.0/3.0); a bad one here is a bug at the construction site.
        precondition(backingScale.isFinite && backingScale > 0, "backingScale must be positive and finite; got \(backingScale)")
        self.axWindowOriginGlobalPt = axWindowOriginGlobalPt
        self.backingScale = backingScale
        self.imagePixelSize = imagePixelSize
    }

    // MARK: AX global point ⇄ image pixel (top-left both, translate + scale)

    /// AX global point → image pixel.
    public func axGlobalToImagePx(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - axWindowOriginGlobalPt.x) * backingScale,
                y: (p.y - axWindowOriginGlobalPt.y) * backingScale)
    }

    /// Image pixel → AX global point (for clicking what CV found).
    public func imagePxToAXGlobal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / backingScale + axWindowOriginGlobalPt.x,
                y: p.y / backingScale + axWindowOriginGlobalPt.y)
    }

    // MARK: AX global rect ⇄ image pixel rect (no flip — both top-left)

    public func axGlobalToImagePx(_ r: CGRect) -> CGRect {
        let origin = axGlobalToImagePx(r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width * backingScale, height: r.height * backingScale)
    }

    public func imagePxToAXGlobal(_ r: CGRect) -> CGRect {
        let origin = imagePxToAXGlobal(r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width / backingScale, height: r.height / backingScale)
    }

    // MARK: Vision normalized (bottom-left) → image pixel (top-left)

    /// Vision `boundingBox` (bottom-left normalized) → image pixel rect (top-left). Note the Y-flip.
    public func visionNormToImagePx(_ box: CGRect) -> CGRect {
        let w = imagePixelSize.width, h = imagePixelSize.height
        return CGRect(x: box.minX * w,
                      y: (1 - box.maxY) * h,            // bottom-left → top-left
                      width: box.width * w,
                      height: box.height * h)
    }
}

/// AX global (top-left) → Cocoa/AppKit screen (bottom-left) conversion, kept here so `LocatorCore`
/// stays AppKit-free. Pass the *global* display-space height (e.g. the union of all `NSScreen`s, or
/// the main display height for the single-display case). Pure, so it's testable without a display.
public func axGlobalToCocoaScreen(_ p: CGPoint, globalHeightPt: CGFloat) -> CGPoint {
    CGPoint(x: p.x, y: globalHeightPt - p.y)
}

/// Rect variant of ``axGlobalToCocoaScreen(_:globalHeightPt:)``. Flipping only a rect's origin is a
/// trap: a top-left rect origin maps to the Cocoa *bottom*-left, so the Cocoa origin's y is
/// `globalHeightPt - maxY`, not `globalHeightPt - minY`. Use this instead of flipping the origin.
public func axGlobalToCocoaScreen(_ r: CGRect, globalHeightPt: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: globalHeightPt - r.maxY, width: r.width, height: r.height)
}
