//
//  SeatDisplay+Preference.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SeatBroker

extension SeatDisplay {

    /// The size as Settings stores it, width by height in pixels: "2560x1440".
    var sizeKey: String { "\(pixelWidth)x\(pixelHeight)" }

    /// The display a stored size and rate describe, nil for a size that is not two numbers.
    init?(
        size       : String,
        refreshRate: Int
    ) {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }

        self.init(
            pixelWidth : parts[0],
            pixelHeight: parts[1],
            refreshRate: refreshRate
        )
    }
}
