//
//  KeyboardLayout.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// KeyboardLayout is one reading of the keyboard layout installed right now: a
/// value, taken at a moment, that says which character each position produces.
///
/// It is the **only** place a layout enters the kit. A position, an arrow or an
/// escape, never passes through here, because a position means the same thing
/// everywhere and translating it could only introduce an error. A character
/// does: Command and C is answered by a menu item matched on the character, and
/// on a French layout a is at virtual key 12 rather than the US layout's key 0.
///
/// It is a value and not a service so that a test can build one by hand. The
/// reader that asks the system for the real one is `KeyboardLayoutReader`, and
/// nothing in this type touches Carbon.
///
/// A reading has the base and Command identity planes, plus their Shift rows.
/// Command can select another arrangement, while Option and Control alter a
/// produced character without changing the key a character Shortcut names.
/// Shift is consulted only when a requested symbol has no base-plane key.
nonisolated public struct KeyboardLayout: Sendable, Equatable {

    private struct Position: Sendable, Hashable {
        let virtualKey: CGKeyCode
        let modifiers : Modifiers
    }

    /// Resolution is the physical key a character Shortcut names and whether
    /// it depended on Shift's symbol row. The latter is held so a lost Shift
    /// can be refused before it changes a `?` back into a `/` at post time.
    package struct Resolution: Sendable, Equatable {
        package let virtualKey    : CGKeyCode
        package let commandPlane  : Bool
        package let requiresShift : Bool
    }

    /// The input source this reading came from, such as
    /// `com.apple.keylayout.Italian`.
    public let inputSourceID: String

    /// A counter that changes whenever a new reading differs from the previous
    /// one, in identity or in content. Content matters because a person can
    /// edit a custom layout without its id ever changing.
    public let generation: UInt64

    /// The `KeyNames.version` this reading was built against. A reading stored
    /// by a consumer and read back after the kit updated its table announces
    /// itself here instead of resolving quietly to a different key.
    public let tableVersion: Int

    private let charactersByPosition: [Position: Character]
    private let virtualKeysByCharacter: [Modifiers: [Character: CGKeyCode]]

    public init(
        inputSourceID: String,
        generation   : UInt64,
        tableVersion          : Int = KeyNames.version,
        characters            : [CGKeyCode: Character],
        modifiedCharactersByKey: [Modifiers: [CGKeyCode: Character]] = [:]
    ) {
        self.inputSourceID         = inputSourceID
        self.generation            = generation
        self.tableVersion          = tableVersion
        var charactersByPosition = Dictionary(
            uniqueKeysWithValues: characters.map { key, character in
                (Position(virtualKey: key, modifiers: []), character)
            }
        )
        for (modifiers, positions) in modifiedCharactersByKey {
            for (virtualKey, character) in positions {
                charactersByPosition[
                    Position(virtualKey: virtualKey, modifiers: modifiers.sourceRow)
                ] = character
            }
        }
        self.charactersByPosition = charactersByPosition
        // A layout can map two positions to the same character, the keypad
        // digits being the ordinary case. The lowest virtual key wins, so the
        // main block is chosen over the keypad and the answer is stable rather
        // than whichever the dictionary happened to yield.
        self.virtualKeysByCharacter = charactersByPosition.reduce(into: [:]) { table, pair in
            let (position, character) = pair
            var characters = table[position.modifiers] ?? [:]
            if let existing = characters[character], existing <= position.virtualKey { return }
            characters[character] = position.virtualKey
            table[position.modifiers] = characters
        }
    }

    /// The character this position produces under the source row selected by
    /// Command and Shift. Option, Control, Caps Lock and Function remain event
    /// flags, because their transformed output is not a Shortcut's identity.
    public func character(
        of virtualKey: CGKeyCode,
        modifiers    : Modifiers = []
    ) -> Character? {
        charactersByPosition[
            Position(virtualKey: virtualKey, modifiers: modifiers.sourceRow)
        ]
    }

    /// Resolves a character Shortcut under its effective event modifiers.
    ///
    /// The base or Command plane names the key first, even with Shift, Option
    /// or Control held. That makes Control-A, Option-E and Shift-Slash select
    /// A, E and Slash respectively. Only when the character has no identity
    /// key does an explicitly held Shift search its source row, which is how a
    /// Shortcut written as `?` names the shifted Slash position. The Shift row
    /// of the Command plane is preferred, then the unmodified Shift row only
    /// where Command leaves that key's base identity unchanged. No uppercase
    /// or symbol is fabricated by this lookup.
    public func virtualKey(
        producing character: Character,
        modifiers          : Modifiers = []
    ) -> CGKeyCode? {
        resolve(character, modifiers: modifiers)?.virtualKey
    }

    package func resolve(
        _ character: Character,
        modifiers : Modifiers
    ) -> Resolution? {
        let commandPlane: Modifiers = modifiers.contains(.command) ? .command : []
        if let virtualKey = virtualKeysByCharacter[commandPlane]?[character] {
            return Resolution(
                virtualKey   : virtualKey,
                commandPlane : !commandPlane.isEmpty,
                requiresShift: false
            )
        }
        guard modifiers.contains(.shift) else { return nil }
        let shiftedPlane = commandPlane.union(.shift)
        if let virtualKey = virtualKeysByCharacter[shiftedPlane]?[character] {
            return Resolution(
                virtualKey   : virtualKey,
                commandPlane : !commandPlane.isEmpty,
                requiresShift: true
            )
        }
        guard !commandPlane.isEmpty else { return nil }
        guard let fallback = virtualKeysByCharacter[.shift]?[character] else { return nil }
        let base = Position(virtualKey: fallback, modifiers: [])
        let command = Position(virtualKey: fallback, modifiers: .command)
        let commandShift = Position(virtualKey: fallback, modifiers: [.command, .shift])
        guard let baseCharacter = charactersByPosition[base],
              baseCharacter == charactersByPosition[command],
              baseCharacter == charactersByPosition[commandShift]
        else {
            return nil
        }
        return Resolution(virtualKey: fallback, commandPlane: true, requiresShift: true)
    }

    /// Resolves `reference` with the complete modifiers the event will carry.
    ///
    /// A character Shortcut sends no Unicode payload. Its virtual key and flags
    /// let the target derive `charactersIgnoringModifiers`, which is what an
    /// AppKit menu uses to match a key equivalent. Text Commands keep their
    /// Unicode payload through their separate InputCommand path.
    public func resolve(
        _ reference: KeyReference,
        modifiers : Modifiers = []
    ) throws -> CGKeyCode {
        switch reference {
            case .physical(let key):
                return key.virtualKey

            case .virtualKey(let virtualKey):
                return virtualKey

            case .character(let character):
                guard let resolution = resolve(character, modifiers: modifiers) else {
                    throw InputFailure.keyUnresolvable(
                        character    : String(character),
                        inputSourceID: inputSourceID
                    )
                }
                return resolution.virtualKey
        }
    }
}

nonisolated private extension Modifiers {

    /// Shortcut identity reads only the source rows selected by Command and
    /// Shift. The remaining bits change event flags but do not name a layout
    /// position, so querying their translated output would turn Control-A into
    /// U+0001 and Option-E into a dead accent.
    var sourceRow: Modifiers {
        intersection([.command, .shift])
    }
}
