//
//  KeyboardLayoutTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
import Testing

@Suite("Keyboard layout")
struct KeyboardLayoutTests {

    /// Two layouts that disagree about where the letters are, built by hand so
    /// the suite stays pure: nothing here asks the system what is installed.
    /// The positions are the real ones, a US layout has q at virtual key 12 and
    /// a French one has a there, which is the case the whole `.character`
    /// reference exists for.
    static let american = KeyboardLayout(
        inputSourceID: "test.keylayout.US",
        generation   : 1,
        characters   : [0: "a", 8: "c", 12: "q", 13: "w", 6: "z", 1: "s"]
    )

    static let french = KeyboardLayout(
        inputSourceID: "test.keylayout.French",
        generation   : 2,
        characters   : [0: "q", 8: "c", 12: "a", 13: "z", 6: "w", 1: "s"]
    )

    @Test("a position resolves without consulting the layout at all")
    func positionIgnoresTheLayout() throws {
        let arrowRight = try #require(KeyNames.key(named: "ArrowRight"))
        let reference  = KeyReference.physical(arrowRight)

        let onAmerican = try Self.american.resolve(reference)
        let onFrench   = try Self.french.resolve(reference)

        #expect(onAmerican == 124)
        #expect(onAmerican == onFrench)
    }

    @Test("a raw virtual key resolves to itself on any layout")
    func virtualKeyIsTheDirectPath() throws {
        let resolved = try Self.french.resolve(.virtualKey(9))

        #expect(resolved == 9)
    }

    @Test("the same character resolves to different positions on different layouts")
    func characterFollowsTheLayout() throws {
        let onAmerican = try Self.american.resolve(.character("a"))
        let onFrench   = try Self.french.resolve(.character("a"))

        #expect(onAmerican == 0)
        #expect(onFrench == 12)
        #expect(onAmerican != onFrench)
    }

    @Test("a character the layout cannot produce unmodified is refused, not guessed")
    func unresolvableCharacterRefuses() {
        #expect(throws: InputFailure.keyUnresolvable(
            character    : "?",
            inputSourceID: "test.keylayout.US"
        )) {
            try Self.american.resolve(.character("?"))
        }
    }

    @Test("when two positions produce the same character the lowest virtual key wins")
    func duplicateCharactersResolveStably() throws {
        // The keypad digits are the ordinary case of a layout mapping one
        // character to two positions. Whichever the dictionary happened to
        // yield would make the answer change between runs.
        let layout = KeyboardLayout(
            inputSourceID: "test.keylayout.Duplicates",
            generation   : 1,
            characters   : [29: "0", 82: "0"]
        )

        #expect(try layout.resolve(.character("0")) == 29)
    }

    @Test("a reading carries the identity, the generation and the table it was built against")
    func readingCarriesItsProvenance() {
        #expect(Self.american.inputSourceID == "test.keylayout.US")
        #expect(Self.american.generation == 1)
        #expect(Self.american.tableVersion == KeyNames.version)
    }

    @Test("a reading built against another table version says so instead of resolving quietly")
    func staleTableVersionIsVisible() {
        let stale = KeyboardLayout(
            inputSourceID: "test.keylayout.US",
            generation   : 1,
            tableVersion : KeyNames.version - 1,
            characters   : [0: "a"]
        )

        #expect(stale.tableVersion != KeyNames.version)
    }

    @Test("QWERTY, Dvorak, AZERTY and QWERTZ each choose their own position")
    func namedLayoutsChooseTheirOwnPositions() throws {
        let qwerty = KeyboardLayout(
            inputSourceID: "test.keylayout.US",
            generation: 1,
            characters: [8: "c", 6: "z", 12: "q"]
        )
        let dvorak = KeyboardLayout(
            inputSourceID: "test.keylayout.Dvorak",
            generation: 1,
            characters: [34: "c", 6: ";", 12: "'"]
        )
        let azerty = KeyboardLayout(
            inputSourceID: "test.keylayout.French",
            generation: 1,
            characters: [8: "c", 0: "q", 12: "a"]
        )
        let qwertz = KeyboardLayout(
            inputSourceID: "test.keylayout.German",
            generation: 1,
            characters: [8: "c", 6: "y", 16: "z"]
        )

        #expect(try qwerty.resolve(.character("c")) == 8)
        #expect(try dvorak.resolve(.character("c")) == 34)
        #expect(try azerty.resolve(.character("a")) == 12)
        #expect(try qwertz.resolve(.character("z")) == 16)
    }

    @Test("Command chooses its identity plane while Option and Control stay event flags")
    func commandPlaneDoesNotTreatTransformedOutputAsTheShortcutName() throws {
        let layout = KeyboardLayout(
            inputSourceID: "test.keylayout.CommandSwitching",
            generation: 1,
            characters: [0: "a", 2: "e", 5: "g", 44: "/"],
            modifiedCharactersByKey: [
                .command: [0: "a", 2: "e", 5: "g", 44: "/"],
                .shift: [0: "A", 2: "E", 5: "G", 44: "?"],
                [.command, .shift]: [0: "A", 2: "E", 5: "G", 44: "/"],
            ]
        )

        #expect(try layout.resolve(.character("a"), modifiers: .control) == 0)
        #expect(try layout.resolve(.character("e"), modifiers: .option) == 2)
        #expect(try layout.resolve(.character("g"), modifiers: [.command, .option]) == 5)
        #expect(try layout.resolve(.character("/"), modifiers: .shift) == 44)
        #expect(try layout.resolve(.character("?"), modifiers: [.command, .shift]) == 44)
    }

    @Test("a shifted-symbol fallback refuses a Command plane that changed the position")
    func shiftedFallbackDoesNotCrossACommandLayoutSwitch() {
        let layout = KeyboardLayout(
            inputSourceID: "test.keylayout.CommandSwitching",
            generation: 1,
            characters: [33: "["],
            modifiedCharactersByKey: [
                .command: [33: "{"],
                .shift: [33: "?"],
                [.command, .shift]: [33: "["],
            ]
        )

        #expect(throws: InputFailure.keyUnresolvable(
            character: "?",
            inputSourceID: "test.keylayout.CommandSwitching"
        )) {
            try layout.resolve(.character("?"), modifiers: [.command, .shift])
        }
    }

    @Test("a shifted fallback does not override an explicit Command Shift symbol")
    func shiftedFallbackRespectsTheCommandShiftRow() {
        let layout = KeyboardLayout(
            inputSourceID: "test.keylayout.CommandShiftSymbol",
            generation: 1,
            characters: [44: "/"],
            modifiedCharactersByKey: [
                .command: [44: "/"],
                .shift: [44: "?"],
                [.command, .shift]: [44: "!"],
            ]
        )

        #expect(throws: InputFailure.keyUnresolvable(
            character: "?",
            inputSourceID: "test.keylayout.CommandShiftSymbol"
        )) {
            try layout.resolve(.character("?"), modifiers: [.command, .shift])
        }
    }
}
