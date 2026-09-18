//
//  NormalizedSize.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// NormalizedSize is a width and height in window-normalized units, encoded as the `[width, height]`
/// array stored groups have always carried.
public struct NormalizedSize: Sendable, Equatable, Hashable {

    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width  = width
        self.height = height
    }

    public init(of rect: NormalizedRect) {
        self.init(width: rect.width, height: rect.height)
    }

    /// The larger side.
    public var maxSide: Double { max(width, height) }

    /// The extent along an axis: the width of a column cell, the height of a row cell.
    public func extent(along axis: GroupAxis) -> Double {
        axis == .column ? width : height
    }
}

extension NormalizedSize: Codable {

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let width  = try container.decode(Double.self)
        let height = try container.decode(Double.self)
        self.init(width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(width)
        try container.encode(height)
    }
}
