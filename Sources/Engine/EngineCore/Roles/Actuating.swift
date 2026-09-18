//
//  Actuating.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// MouseButton is which button a click presses.
public enum MouseButton: Sendable, Equatable {
    case left
    case right
}

/// Gesture is one atomic input action at a global point, or a key sequence to the focused process.
/// The engine never splits one, never retries one, and never invents an extra event.
public enum Gesture: Sendable, Equatable {
    case click(at: CGPoint, button: MouseButton = .left, count: Int = 1)
    case scroll(at: CGPoint, deltaY: Int, deltaX: Int = 0)
    case key(code: UInt16, modifiers: KeyModifiers = [])
    case type(String)
}

/// KeyModifiers are the modifier keys held for a key gesture.
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// Actuating delivers a gesture to a process. Which process, and whether the delivery needs the
/// window in front, is the conformer's contract: a foreground actuator posts through the HID
/// system, a background one delivers to an adopted window on a hidden display.
///
/// A conformer returns once the events have gone out, which says nothing about their effect; the
/// engine verifies the effect by perceiving again. A conformer that cannot deliver at all throws.
public protocol Actuating: Sendable {

    func perform(_ gesture: Gesture, in processID: pid_t) async throws
}
