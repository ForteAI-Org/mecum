//
//  SeatDisplay.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// SeatDisplay is the virtual display a worker's seat is made with: its size
/// in pixels and how often it refreshes. The panel is always the kit's 27 inch
/// 16:9 one without HiDPI, so a 16:9 size keeps its points square and a
/// smaller one gives an adopted window less room, which the seat meets by
/// resizing the window while it holds it.
public struct SeatDisplay: Sendable, Hashable {

    public var pixelWidth : Int
    public var pixelHeight: Int

    /// 60 or 120; the virtual display supports no other rate.
    public var refreshRate: Int

    public init(
        pixelWidth : Int,
        pixelHeight: Int,
        refreshRate: Int = 60
    ) {
        self.pixelWidth  = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate == 120 ? 120 : 60
    }

    /// What every seat was made with before the display could be chosen.
    public static let standard = SeatDisplay(
        pixelWidth : 2560,
        pixelHeight: 1440
    )

    /// The 16:9 sizes offered, smallest first.
    public static let sizes: [SeatDisplay] = [
        SeatDisplay(pixelWidth: 1280, pixelHeight: 720),
        SeatDisplay(pixelWidth: 1920, pixelHeight: 1080),
        .standard,
        SeatDisplay(pixelWidth: 3840, pixelHeight: 2160),
    ]
}
