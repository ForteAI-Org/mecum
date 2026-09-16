//
//  ShortcutResolutionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatInput
import Testing

@Suite("Shortcut resolution")
struct ShortcutResolutionTests {

    /// Dvorak and QWERTY disagree about where c is, which is the whole point.
    static let dvorak = KeyboardLayout(
        inputSourceID: "test.keylayout.Dvorak",
        generation   : 7,
        characters   : [34: "c", 8: "j"],
        modifiedCharactersByKey: [.command: [34: "c", 8: "j"]]
    )

    static let qwerty = KeyboardLayout(
        inputSourceID: "test.keylayout.US",
        generation   : 8,
        characters   : [8: "c", 34: "i"]
    )

    @Test("a position needs no layout and reports none")
    func positionConsultsNoLayout() throws {
        let arrowRight = try #require(KeyNames.key(named: "ArrowRight"))
        let resolved   = try ShortcutResolution.resolve(
            .physical(arrowRight, holding: .option),
            layout   : nil,
            hold     : KeyHold(),
            owner    : 1,
            processID: 100
        )

        #expect(resolved.command == .key(virtualKey: 124, text: "", modifiers: .option))
        #expect(resolved.layoutGeneration == nil)
    }

    @Test("a character resolves through the layout and reports which reading answered")
    func characterReportsItsLayout() throws {
        let resolved = try ShortcutResolution.resolve(
            .character("c", holding: .command),
            layout   : Self.dvorak,
            hold     : KeyHold(),
            owner    : 1,
            processID: 100
        )

        #expect(resolved.command == .key(
            virtualKey: 34,
            text: "",
            modifiers: .command,
            origin: CharacterShortcutOrigin(
                character: "c",
                effectiveModifiers: .command,
                commandPlane: true,
                requiresShift: false
            )
        ))
        #expect(resolved.layoutGeneration == 7)
    }

    @Test("a character with no layout at all is refused")
    func characterWithoutALayoutRefuses() {
        #expect(throws: InputFailure.self) {
            try ShortcutResolution.resolve(
                .character("c", holding: .command),
                layout   : nil,
                hold     : KeyHold(),
                owner    : 1,
                processID: 100
            )
        }
    }

    @Test("a release after the person changed layout lifts the key that went down")
    func releaseSurvivesALayoutChange() throws {
        let hold = KeyHold()

        // Pressed while Dvorak was installed: c is at 34.
        let down = try ShortcutResolution.resolve(
            .character("c"), phase: .down,
            layout: Self.dvorak, hold: hold, owner: 1, processID: 100
        )
        #expect(down.command == .key(
            virtualKey: 34,
            text: "",
            phase: .down,
            origin: CharacterShortcutOrigin(
                character: "c",
                effectiveModifiers: [],
                commandPlane: false,
                requiresShift: false
            )
        ))
        hold.press(KeyHold.HeldKey(virtualKey: 34, character: "c"), owner: 1, processID: 100)

        // The person switches to QWERTY, where c is at 8. Resolving again would
        // lift a key that was never pressed and leave 34 down forever.
        let up = try ShortcutResolution.resolve(
            .character("c"), phase: .up,
            layout: Self.qwerty, hold: hold, owner: 1, processID: 100
        )

        #expect(up.command == .key(virtualKey: 34, text: "", phase: .up))
        // No layout was consulted, so none is reported.
        #expect(up.layoutGeneration == nil)
    }

    @Test("a release of a character nobody holds falls back to the current layout")
    func unheldReleaseUsesTheLayout() throws {
        let up = try ShortcutResolution.resolve(
            .character("c"), phase: .up,
            layout: Self.qwerty, hold: KeyHold(), owner: 1, processID: 100
        )

        // Harmless: nothing is held, so lifting the layout's own key lifts
        // nothing. The pin only matters when there is something pinned.
        #expect(up.command == .key(
            virtualKey: 8,
            text: "",
            phase: .up,
            origin: CharacterShortcutOrigin(
                character: "c",
                effectiveModifiers: [],
                commandPlane: false,
                requiresShift: false
            )
        ))
        #expect(up.layoutGeneration == 8)
    }

    @Test("another owner's held key does not pin this owner's release")
    func pinningIsScopedToItsOwner() throws {
        let hold = KeyHold()
        hold.press(KeyHold.HeldKey(virtualKey: 34, character: "c"), owner: 1, processID: 100)

        let up = try ShortcutResolution.resolve(
            .character("c"), phase: .up,
            layout: Self.qwerty, hold: hold, owner: 2, processID: 100
        )

        #expect(up.command == .key(
            virtualKey: 8,
            text: "",
            phase: .up,
            origin: CharacterShortcutOrigin(
                character: "c",
                effectiveModifiers: [],
                commandPlane: false,
                requiresShift: false
            )
        ))
    }

    @Test("a pinned up ignores a held Command that arrived after the down")
    func pinnedReleaseDoesNotRequireTheCurrentLayoutPlane() throws {
        let hold = KeyHold()
        hold.press(KeyHold.HeldKey(virtualKey: 34, character: "c"), owner: 1, processID: 100)
        hold.press(KeyHold.HeldKey(virtualKey: 55), owner: 2, processID: 100)

        let up = try ShortcutResolution.resolve(
            .character("c"),
            phase: .up,
            layout: Self.qwerty,
            hold: hold,
            owner: 1,
            processID: 100
        )

        #expect(up.command == .key(virtualKey: 34, text: "", phase: .up))
    }
}
