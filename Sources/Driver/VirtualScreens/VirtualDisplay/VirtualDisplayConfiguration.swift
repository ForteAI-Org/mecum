//
//  VirtualDisplayConfiguration.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// RefreshRate is what a Seat Host may ask a virtual display to run at. It is
/// an enumeration and not a `Double` because only two values are supported by
/// the spec, and a type that admits 75 would need a runtime rejection that says
/// the same thing later and worse. 120 is accepted here; whether the Monitor
/// holds that pace is a Capture question, and `Monitor.start` answers it by
/// refusing a display that does not really run at 120 Hz.
nonisolated public enum RefreshRate: Double, Sendable, Equatable, CaseIterable {
    case standard = 60
    case high     = 120
}

/// VirtualDisplayConfiguration is the shape of the surface a Seat Host asks
/// for. The identity triple is deliberately **not** in here: macOS keeps modes,
/// arrangement and colour profile per vendor, product and serial, so a random
/// serial per run would leave the person's Mac with a growing pile of remembered
/// monitors. The kit always presents itself as the same display.
nonisolated public struct VirtualDisplayConfiguration: Sendable, Equatable {

    public let pixelWidth : UInt32
    public let pixelHeight: UInt32
    public let refreshRate: RefreshRate

    public init(
        pixelWidth : UInt32      = 2560,
        pixelHeight: UInt32      = 1440,
        refreshRate: RefreshRate = .standard
    ) {
        self.pixelWidth  = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public var pixelSize: CGSize {
        CGSize(width: Int(pixelWidth), height: Int(pixelHeight))
    }

    /// The stable identity of the kit's display, verified on 26A5425a: with it
    /// the second and every later creation costs about 290 ms and no wait for
    /// active plus online, because macOS recognises the monitor it already
    /// knows.
    public static let vendorID : UInt32 = 0xF0A7
    public static let productID: UInt32 = 0xA617
    public static let serial   : UInt32 = 0xA617_0001

    /// The name the person sees in System Settings.
    public static let displayName = "AgentSeat Virtual 1"

    /// A 27 inch 16:9 panel. The window server derives point size from pixels
    /// and this, so it is part of the identity rather than a decoration.
    public static let sizeInMillimeters = CGSize(width: 508, height: 286)
}
