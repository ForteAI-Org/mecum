//
//  ShortcutResolution.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore

/// ShortcutResolution turns a declarative Shortcut into the one key Command
/// that carries it, and it is where the keyboard layout enters and stops.
///
/// It is a separate step from building the Command because resolving can fail
/// and building cannot: a character the installed layout does not produce has
/// no key to press, and that refusal belongs before anything is constructed.
///
/// ## The release is not a second resolution
///
/// The person can change keyboard layout between a `.down` and its `.up`, and
/// on this hardware that is not hypothetical: a Dvorak layout puts c where a
/// QWERTY one puts j. Resolving the character again under the new layout would
/// send an up for a key that was never pressed and leave the pressed one down
/// forever. So a release asks the hold registry what actually went down from
/// that character, and only falls back to the layout when the registry has
/// nothing, which is the case where nothing is held and the up is harmless.
nonisolated package enum ShortcutResolution {

    /// Resolved is the Command plus the provenance a Receipt carries: which
    /// layout reading answered, or nil when none was consulted.
    package struct Resolved: Sendable, Equatable {
        package let command         : InputCommand
        package let layoutGeneration: UInt64?
    }

    package static func resolve(
        _ shortcut: Shortcut,
        phase     : KeyPhase = .press,
        layout    : KeyboardLayout?,
        hold      : KeyHold = .shared,
        owner     : Int64,
        processID : Int32
    ) throws -> Resolved {

        switch shortcut.key {
            case .physical(let key):
                // A position is the same on every layout, so consulting one
                // could only introduce an error.
                return Resolved(
                    command: .key(
                        virtualKey: key.virtualKey,
                        text      : "",
                        modifiers : shortcut.modifiers,
                        phase     : phase
                    ),
                    layoutGeneration: nil
                )

            case .virtualKey(let virtualKey):
                return Resolved(
                    command: .key(
                        virtualKey: virtualKey,
                        text      : "",
                        modifiers : shortcut.modifiers,
                        phase     : phase
                    ),
                    layoutGeneration: nil
                )

            case .character(let character):
                if phase == .up,
                   let pinned = hold.heldVirtualKey(
                       resolvedFrom: character,
                       owner       : owner,
                       processID   : processID
                   ) {
                    return Resolved(
                        command: .key(
                            virtualKey: pinned,
                            text      : "",
                            modifiers : shortcut.modifiers,
                            phase     : .up
                        ),
                        layoutGeneration: nil
                    )
                }
                guard let layout else {
                    throw InputFailure.keyUnresolvable(
                        character    : String(character),
                        inputSourceID: ""
                    )
                }
                let effectiveModifiers = hold.modifiers(processID: processID)
                    .union(shortcut.modifiers)
                guard let resolution = layout.resolve(character, modifiers: effectiveModifiers) else {
                    throw InputFailure.keyUnresolvable(
                        character    : String(character),
                        inputSourceID: layout.inputSourceID
                    )
                }
                return Resolved(
                    command: .key(
                        virtualKey: resolution.virtualKey,
                        text      : "",
                        modifiers : shortcut.modifiers,
                        phase     : phase,
                        origin    : CharacterShortcutOrigin(
                            character         : character,
                            effectiveModifiers: effectiveModifiers,
                            commandPlane      : resolution.commandPlane,
                            requiresShift     : resolution.requiresShift
                        )
                    ),
                    layoutGeneration: layout.generation
                )
        }
    }
}
