//
//  ModifierPolicyGateTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import SeatCore
@testable import SeatInput
import Testing

/// The gate that decides whether this build may post modifier transitions.
///
/// On the machine this was written on the record check passes, so the refusing
/// branch never runs there. It is the branch that matters: a build where the
/// `0x0C` record type stopped being what it is must refuse rather than post
/// something the window server reads as another kind of event.
@Suite("Modifier policy gate")
struct ModifierPolicyGateTests {

    @Test("the default policy needs no verification and is never refused", arguments: [true, false])
    func eventFlagsIsAlwaysAvailable(verified: Bool) throws {
        #expect(
            try InputEngine.resolveModifierPolicy(
                .eventFlags,
                flagsChangedRecordIsVerified: verified
            ) == .eventFlags
        )
    }

    @Test("transitions are allowed on a build where the record was verified")
    func flagsChangedIsAllowedWhenVerified() throws {
        #expect(
            try InputEngine.resolveModifierPolicy(
                .flagsChanged,
                flagsChangedRecordIsVerified: true
            ) == .flagsChanged
        )
    }

    @Test("transitions are refused on a build where the record was not verified")
    func flagsChangedIsRefusedWhenUnverified() {
        // Refused, and **not** quietly downgraded to `.eventFlags`: a silent
        // fall back would post a Command that looks like it worked and make a
        // matrix row pass for the wrong reason.
        #expect(throws: InputFailure.modifierPolicyUnavailable(.flagsChanged)) {
            try InputEngine.resolveModifierPolicy(
                .flagsChanged,
                flagsChangedRecordIsVerified: false
            )
        }
    }

    @Test("a character Shortcut refuses when its Command layout plane drifted before posting")
    func characterShortcutRefusesCommandPlaneDrift() {
        let command = InputCommand.key(
            virtualKey: 5,
            text: "",
            modifiers: [],
            origin: CharacterShortcutOrigin(
                character: "g",
                effectiveModifiers: .command,
                commandPlane: true,
                requiresShift: false
            )
        )

        #expect(throws: InputFailure.shortcutContextChanged(
            resolved: .command,
            current: []
        )) {
            try InputEngine.requireStableShortcutContext(for: command, held: [])
        }
    }

    @Test("a shifted symbol refuses only when the required Shift disappeared")
    func shiftedSymbolRefusesShiftDrift() throws {
        let command = InputCommand.key(
            virtualKey: 44,
            text: "",
            modifiers: .command,
            origin: CharacterShortcutOrigin(
                character: "?",
                effectiveModifiers: [.command, .shift],
                commandPlane: true,
                requiresShift: true
            )
        )

        #expect(throws: InputFailure.shortcutContextChanged(
            resolved: [.command, .shift],
            current: .command
        )) {
            try InputEngine.requireStableShortcutContext(for: command, held: [])
        }
        try InputEngine.requireStableShortcutContext(for: command, held: .shift)
    }
}
