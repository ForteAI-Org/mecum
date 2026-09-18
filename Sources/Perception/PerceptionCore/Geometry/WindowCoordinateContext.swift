//
//  WindowCoordinateContext.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// WindowCoordinateContext is the single home of coordinate conversion between the three spaces
/// perception meets: global points (top-left origin), image pixels (top-left origin), and the
/// bottom-left normalized boxes a vision framework reports. Ad hoc coordinate arithmetic anywhere
/// else is where most perception bugs come from.
public struct WindowCoordinateContext: Sendable, Equatable {

    /// The window's top-left corner in global points.
    public let windowOrigin: CGPoint
    /// The display's backing scale: points to pixels.
    public let backingScale: CGFloat
    /// The captured image's size in pixels.
    public let imagePixelSize: CGSize

    /// Creates a context. A non-positive or non-finite scale would silently produce non-finite
    /// coordinates that surface much later; a display's scale is always positive and finite, so a
    /// bad one is a bug at the construction site and is refused here.
    public init(windowOrigin: CGPoint, backingScale: CGFloat, imagePixelSize: CGSize) {
        precondition(
            backingScale.isFinite && backingScale > 0,
            "backingScale must be positive and finite; got \(backingScale)"
        )
        self.windowOrigin   = windowOrigin
        self.backingScale   = backingScale
        self.imagePixelSize = imagePixelSize
    }

    // MARK: Global points and image pixels: both top-left, a translation and a scale

    public func imagePixel(fromGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - windowOrigin.x) * backingScale, y: (point.y - windowOrigin.y) * backingScale)
    }

    public func globalPoint(fromImagePixel pixel: CGPoint) -> CGPoint {
        CGPoint(x: pixel.x / backingScale + windowOrigin.x, y: pixel.y / backingScale + windowOrigin.y)
    }

    public func imagePixelRect(fromGlobalRect rect: CGRect) -> CGRect {
        let origin = imagePixel(fromGlobalPoint: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * backingScale, height: rect.height * backingScale)
    }

    public func globalRect(fromImagePixelRect rect: CGRect) -> CGRect {
        let origin = globalPoint(fromImagePixel: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / backingScale, height: rect.height / backingScale)
    }

    // MARK: Bottom-left normalized boxes to top-left image pixels: the one flip

    public func imagePixelRect(fromBottomLeftNormalized box: CGRect) -> CGRect {
        let width = imagePixelSize.width, height = imagePixelSize.height
        return CGRect(
            x     : box.minX * width,
            y     : (1 - box.maxY) * height,
            width : box.width * width,
            height: box.height * height
        )
    }
}

/// Converts a global top-left point to a Cocoa bottom-left screen point, given the global display
/// space's height. Kept pure so it is testable without a display.
public func cocoaScreenPoint(fromGlobalPoint point: CGPoint, globalHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: globalHeight - point.y)
}

/// Rect variant of `cocoaScreenPoint`. Flipping only an origin is a trap: a top-left origin maps to
/// the Cocoa bottom-left, so the Cocoa origin's y is `globalHeight - maxY`.
public func cocoaScreenRect(fromGlobalRect rect: CGRect, globalHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: globalHeight - rect.maxY, width: rect.width, height: rect.height)
}
