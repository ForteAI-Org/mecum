//
//  PhysicalKey.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics

/// PhysicalKey is a position on the keyboard, named the same way on every
/// layout: the key at the bottom left of the letter block is `KeyZ` whether the
/// installed layout produces a z, a w or a y there.
///
/// The distinction matters for exactly one reason. Option and the right arrow
/// is a position and means the same everywhere; Command and C is a *character*,
/// because the menu item that answers it is matched on the character, and on a
/// French layout that character is at a different virtual key. A vocabulary
/// with only one of the two gets one of those two wrong.
public struct PhysicalKey: Sendable, Hashable {

    /// The name, from the W3C UI Events `code` values. They are borrowed rather
    /// than invented so that a consumer that already speaks about keys, from a
    /// browser automation layer or a recorded session, does not have to
    /// translate.
    public let name: String

    /// The virtual key this position has on macOS.
    public let virtualKey: CGKeyCode

    public init(name: String, virtualKey: CGKeyCode) {
        self.name       = name
        self.virtualKey = virtualKey
    }
}
