//
//  KeyVocabularyTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
import Testing

@Suite("Key vocabulary")
struct KeyVocabularyTests {

    // MARK: Modifiers

    @Test("the press order is ascending bit order, and the release order is its exact reverse")
    func pressOrderIsBitOrder() {
        let all: Modifiers = [.command, .shift, .option, .control, .function, .capsLock]

        #expect(all.inPressOrder == [.command, .shift, .option, .control, .function, .capsLock])
        #expect(all.inPressOrder.reversed() == [.capsLock, .function, .control, .option, .shift, .command])
    }

    @Test("the press order lists only what the set contains")
    func pressOrderIsASubset() {
        #expect(Modifiers([.command, .option]).inPressOrder == [.command, .option])
        #expect(Modifiers().inPressOrder.isEmpty)
    }

    @Test("every modifier survives the round trip through CoreGraphics flags", arguments: [
        Modifiers.command, .shift, .option, .control, .function, .capsLock,
        [.command, .shift], [.command, .shift, .option, .control, .function, .capsLock],
    ] as [Modifiers])
    func flagsRoundTrip(modifiers: Modifiers) {
        #expect(Modifiers(modifiers.cgFlags) == modifiers)
    }

    @Test("reading flags back drops every bit this vocabulary does not name")
    func readingFlagsIsLossyOnPurpose() {
        let flags: CGEventFlags = [.maskCommand, .maskNumericPad, .maskHelp]

        #expect(Modifiers(flags) == .command)
    }

    @Test("a single modifier has the virtual key a transition event carries", arguments: [
        (Modifiers.command,  CGKeyCode(55)),
        (.shift,             CGKeyCode(56)),
        (.capsLock,          CGKeyCode(57)),
        (.option,            CGKeyCode(58)),
        (.control,           CGKeyCode(59)),
        (.function,          CGKeyCode(63)),
    ])
    func singleModifierVirtualKey(modifiers: Modifiers, expected: CGKeyCode) {
        #expect(modifiers.singleVirtualKey == expected)
    }

    @Test("a set that is not exactly one modifier has no virtual key")
    func compoundModifiersHaveNoVirtualKey() {
        #expect(Modifiers([.command, .shift]).singleVirtualKey == nil)
        #expect(Modifiers().singleVirtualKey == nil)
    }

    // MARK: The table

    @Test("no virtual key and no name is listed twice")
    func tableIsUnambiguous() {
        // Both directions are built with `Dictionary(uniqueKeysWithValues:)`,
        // which traps on a duplicate. Asserting it here means a bad entry fails
        // a unit test instead of the first process that touches the table.
        #expect(Set(KeyNames.entries.map(\.virtualKey)).count == KeyNames.entries.count)
        #expect(Set(KeyNames.entries.map(\.name)).count == KeyNames.entries.count)
    }

    @Test("the table names ANSI, ISO and JIS positions", arguments: [
        ("KeyA",          CGKeyCode(0)),    // ANSI letter block
        ("Digit6",        CGKeyCode(22)),   // the digit that is not in numeric order
        ("IntlBackslash", CGKeyCode(10)),   // ISO, beside the left shift
        ("IntlYen",       CGKeyCode(93)),   // JIS
        ("IntlRo",        CGKeyCode(94)),   // JIS
        ("ArrowRight",    CGKeyCode(124)),  // the position the matrix drives
        ("Escape",        CGKeyCode(53)),
    ])
    func tableNamesEveryFamily(name: String, virtualKey: CGKeyCode) {
        #expect(KeyNames.key(named: name)?.virtualKey == virtualKey)
        #expect(KeyNames.key(forVirtualKey: virtualKey)?.name == name)
    }

    @Test("backspace and forward delete are not swapped")
    func deleteKeysAreNotSwapped() {
        // macOS calls virtual key 51 Delete and this table calls it Backspace,
        // which is exactly why the pair is asserted: swapping them types into
        // the wrong end of a word and nothing else would notice.
        #expect(KeyNames.key(forVirtualKey: 51)?.name == "Backspace")
        #expect(KeyNames.key(forVirtualKey: 117)?.name == "Delete")
    }

    @Test("an unknown virtual key and an almost right name both answer nil")
    func unknownLookupsAnswerNil() {
        #expect(KeyNames.key(forVirtualKey: 200) == nil)
        #expect(KeyNames.key(named: "keyA") == nil)
        #expect(KeyNames.key(named: "ArrowRight ") == nil)
    }

    // MARK: Phases

    @Test("a phase produces the events a receipt has to account for", arguments: [
        (KeyPhase.press, 2), (.down, 1), (.up, 1), (.repeated(count: 5), 5),
    ])
    func phaseEventCount(phase: KeyPhase, expected: Int) {
        #expect(phase.eventCount == expected)
    }
}
