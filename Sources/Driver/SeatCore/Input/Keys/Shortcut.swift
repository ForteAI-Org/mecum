//
//  Shortcut.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics

/// KeyReference is how a caller names the key of a Shortcut, and the three
/// cases are three different questions rather than three spellings of one.
///
/// `.physical` is a position: Option and the right arrow is the same gesture on
/// every layout, and resolving it through a layout would be work that can only
/// introduce an error. `.character` is a meaning: Command and C is answered by a
/// menu item matched on the character, so on a layout where c is not at virtual
/// key 8 the reference has to travel through `KeyboardLayout` to find out where
/// it is. `.virtualKey` is the direct path, unchanged, for a caller that
/// already knows the number and does not want either of the above.
public enum KeyReference: Sendable, Equatable {

    case physical(PhysicalKey)
    case character(Character)
    case virtualKey(CGKeyCode)
}

/// Shortcut is a declarative hotkey: one key and the modifiers held around it.
///
/// It is **not** a Command. It is the value that resolves into one, which is
/// why there is no `.shortcut` case in `InputCommand`: two ways to press
/// Command and C would be two chances for a call site to pick the one that does
/// not work, and the Ledger already records that mistake being made with three
/// drag cases that turned out to be one.
///
/// What the modifiers here mean is narrow and worth stating: they are what this
/// shortcut **adds**. Whatever the session is already holding on the target
/// stays held and is carried on the events too, and only what this shortcut
/// pressed is released afterwards. So a session holding Shift that sends
/// Command and C delivers Command, Shift and C, exactly as a hand on a keyboard
/// would, and gives back only the Command.
public struct Shortcut: Sendable, Equatable {

    public let key      : KeyReference
    public let modifiers: Modifiers

    public init(_ key: KeyReference, holding modifiers: Modifiers = []) {
        self.key       = key
        self.modifiers = modifiers
    }

    /// The shortcut for a character, which is the form every menu key
    /// equivalent takes.
    public static func character(
        _ character: Character,
        holding modifiers: Modifiers = []
    ) -> Shortcut {
        Shortcut(.character(character), holding: modifiers)
    }

    /// The shortcut for a position, which is the form an arrow or an escape
    /// takes, and the one that needs no layout at all.
    public static func physical(
        _ key: PhysicalKey,
        holding modifiers: Modifiers = []
    ) -> Shortcut {
        Shortcut(.physical(key), holding: modifiers)
    }
}
