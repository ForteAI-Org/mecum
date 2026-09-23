//
//  ColumnWidth.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ColumnWidth is one side column's width token: where it starts and how far
/// the person may drag it, in points. The split view holds a drag inside the
/// range itself; nothing in the app measures a column back.
public struct ColumnWidth: Sendable, Hashable {

    public let ideal  : Double
    public let minimum: Double
    public let maximum: Double

    public init(ideal: Double, minimum: Double, maximum: Double) {
        self.ideal   = ideal
        self.minimum = minimum
        self.maximum = maximum
    }
}
