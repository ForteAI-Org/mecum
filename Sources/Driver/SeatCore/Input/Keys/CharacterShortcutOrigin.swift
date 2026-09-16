//
//  CharacterShortcutOrigin.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

/// CharacterShortcutOrigin is the semantic character that selected a physical
/// key for a Shortcut, apart from any Unicode payload on the event.
///
/// A Shortcut must post the selected virtual key with its modifiers and leave
/// the Unicode field empty: writing a string into that field changes how AppKit
/// matches a key equivalent. The origin still has to survive a `.down`, though,
/// so that its `.up` can lift that same key after the keyboard layout changes.
/// `effectiveModifiers` is the complete modifier state used for the layout
/// lookup, including keys the kit was already holding on the target process.
public struct CharacterShortcutOrigin: Sendable, Equatable {

    public let character         : Character
    public let effectiveModifiers: Modifiers
    public let commandPlane      : Bool
    public let requiresShift     : Bool

    public init(
        character         : Character,
        effectiveModifiers: Modifiers,
        commandPlane      : Bool,
        requiresShift     : Bool
    ) {
        self.character          = character
        self.effectiveModifiers = effectiveModifiers
        self.commandPlane       = commandPlane
        self.requiresShift      = requiresShift
    }
}
