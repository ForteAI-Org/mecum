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
    /// A letter or digit pressed on whichever key the installed layout produces it from, because a
    /// shortcut is matched on the character: on an Italian keyboard Z sits where a US one has W.
    case character(Character, modifiers: KeyModifiers = [])
    /// One key down and up per character, the way a hand types.
    case type(String)
    /// The whole string on one key event: flat in cost where typing grows with the text, dropped by a
    /// field already composing with an input method, and seen by the target as one keystroke.
    case insert(String)
    /// A press at `from`, a paced path of moves and a release at `to`.
    case drag(from: CGPoint, to: CGPoint)
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
/// DeliveryEffect is what the engine saw after the gestures it delivered: the effect it looked for
/// was observed, it was verified that nothing happened, or it could not be established. An actuator
/// that keeps receipts answers them with this; one that posts and forgets has nothing to answer.
public enum DeliveryEffect: Sendable, Equatable {

    case observed
    case absent
    case unknown
}

public protocol Actuating: Sendable {

    /// Delivers one gesture to the process and returns when the events have gone out. Says nothing
    /// about their effect; the engine verifies by perceiving again.
    func perform(_ gesture: Gesture, in processID: pid_t) async throws

    /// Closes the gestures delivered since the last confirmation with what the engine saw. Called
    /// once per action, after the verdict, and also when delivery itself failed.
    func confirm(_ effect: DeliveryEffect, in processID: pid_t) async
}
