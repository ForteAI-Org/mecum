//
//  NormalizedRect.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// NormalizedRect is a rectangle inside one window, in window-normalized units: the window's
/// top-left corner is (0, 0) and its bottom-right corner is (1, 1), whatever its pixel size.
///
/// It is the only geometry a scene carries. Positions in a scene are disambiguation hints for a
/// language model and a way back to a pixel when an action is taken, never a pixel coordinate of
/// their own, so they are rounded to three decimals at construction.
public struct NormalizedRect: Sendable, Equatable, Hashable {

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x      = x
        self.y      = y
        self.width  = width
        self.height = height
    }

    public static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)

    /// Builds the rectangle from a four-element `[x, y, width, height]` array, or nil for any
    /// other count. The array shape is what the scene's JSON carries.
    public init?(_ array: [Double]) {
        guard array.count == 4 else { return nil }
        self.init(x: array[0], y: array[1], width: array[2], height: array[3])
    }

    /// Normalizes a pixel box against the image it was measured in, rounded to three decimals.
    /// A degenerate image size yields `.zero` rather than a division by zero.
    public init(pixelBox: CGRect, in pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            self = .zero
            return
        }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 1000).rounded() / 1000 }
        self.init(
            x     : rounded(pixelBox.minX / pixelSize.width),
            y     : rounded(pixelBox.minY / pixelSize.height),
            width : rounded(pixelBox.width / pixelSize.width),
            height: rounded(pixelBox.height / pixelSize.height)
        )
    }

    public var array: [Double] { [x, y, width, height] }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }
    public var center: CGPoint { CGPoint(x: midX, y: midY) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func contains(_ point: CGPoint) -> Bool { cgRect.contains(point) }

    /// The pixel box this rectangle names in an image of `pixelSize`.
    public func pixelBox(in pixelSize: CGSize) -> CGRect {
        CGRect(
            x     : x * pixelSize.width,
            y     : y * pixelSize.height,
            width : width * pixelSize.width,
            height: height * pixelSize.height
        )
    }
}

extension NormalizedRect: Codable {

    /// Encoded as the compact `[x, y, width, height]` array a scene has always carried.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x         = try container.decode(Double.self)
        let y         = try container.decode(Double.self)
        let width     = try container.decode(Double.self)
        let height    = try container.decode(Double.self)
        self.init(x: x, y: y, width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(width)
        try container.encode(height)
    }
}
