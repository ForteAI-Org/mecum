//
//  FixtureWindowRow.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// WindowBoundsRecord is the `kCGWindowBounds` rectangle as the row carried it,
/// in the list's own coordinates. It is stored raw: the probe compares readings
/// and does not convert anything into a placement.
struct WindowBoundsRecord: Codable, Equatable {

    let x     : Double
    let y     : Double
    let width : Double
    let height: Double
}

/// FixtureWindowRow is what one CoreGraphics row carried about a window the
/// fixture itself created and registered.
///
/// Every attribute is optional and an absent attribute stays absent: a missing
/// `kCGWindowIsOnscreen` is not `false` and a missing layer is not `0`, because
/// a default there is how "the list did not say" becomes "the window is not on
/// screen". Only rows of the fixture's own windows reach this type; anything
/// else is counted and redacted, and no title or content is ever stored.
struct FixtureWindowRow: Codable, Equatable {

    let observed  : ObservedWindowIdentity
    let bounds    : WindowBoundsRecord?
    let layer     : Int?
    let alpha     : Double?
    let isOnScreen: Bool?

    /// The names of the attributes this row did not carry, so a reader can tell
    /// an absent field from a field that was read and happened to be zero.
    let missingAttributes: [String]

    static let boundsAttribute     = "kCGWindowBounds"
    static let layerAttribute      = "kCGWindowLayer"
    static let alphaAttribute      = "kCGWindowAlpha"
    static let onScreenAttribute   = "kCGWindowIsOnscreen"
}
