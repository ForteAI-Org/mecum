//
//  KeyHoldTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
import Testing

@Suite("Key hold")
struct KeyHoldTests {

    private static let shift   = KeyHold.HeldKey(virtualKey: 56)
    private static let command = KeyHold.HeldKey(virtualKey: 55)

    @Test("a pressed key is held, and pressing it twice is not a second hold")
    func pressIsIdempotent() {
        let hold = KeyHold()

        #expect(hold.press(Self.shift, owner: 1, processID: 100))
        // The second press answers false, which is how the caller knows not to
        // build an event: a down for a key already down is an autorepeat, and
        // that is a phase of its own.
        #expect(!hold.press(Self.shift, owner: 1, processID: 100))
        #expect(hold.held(processID: 100).count == 1)
    }

    @Test("releasing a key nobody holds changes nothing and builds nothing")
    func releasingWhatIsNotHeldAnswersFalse() {
        let hold = KeyHold()

        #expect(!hold.release(virtualKey: 56, owner: 1, processID: 100))
    }

    @Test("the modifiers of a process are the held keys that are modifiers")
    func modifiersAreDerived() {
        let hold = KeyHold()
        hold.press(Self.shift,                            owner: 1, processID: 100)
        hold.press(Self.command,                          owner: 1, processID: 100)
        hold.press(KeyHold.HeldKey(virtualKey: 6),        owner: 1, processID: 100)

        // The letter is held too, and it is not a modifier: it leaks the same
        // way and it stamps no flag.
        #expect(hold.modifiers(processID: 100) == [.shift, .command])
        #expect(hold.held(processID: 100).count == 3)
    }

    @Test("a right hand modifier is the same modifier")
    func rightHandModifiersCount() {
        let hold = KeyHold()
        hold.press(KeyHold.HeldKey(virtualKey: 60), owner: 1, processID: 100)

        #expect(hold.modifiers(processID: 100) == .shift)
    }

    @Test("two owners on one process see each other's modifiers")
    func ownersShareTheProcess() {
        let hold = KeyHold()
        hold.press(Self.shift,   owner: 1, processID: 100)
        hold.press(Self.command, owner: 2, processID: 100)

        // The PID is the boundary the system has: two windows of one
        // application are one AppKit process with one idea of what is held.
        #expect(hold.modifiers(processID: 100) == [.shift, .command])
    }

    @Test("releasing one owner leaves the other's keys exactly where they were")
    func releaseIsScopedToItsOwner() {
        let hold = KeyHold()
        hold.press(Self.shift,   owner: 1, processID: 100)
        hold.press(Self.command, owner: 2, processID: 100)

        let released = hold.releaseAll(owner: 1, processID: 100)

        #expect(released == [Self.shift])
        #expect(hold.modifiers(processID: 100) == .command)
    }

    @Test("different processes are independent")
    func processesAreIndependent() {
        let hold = KeyHold()
        hold.press(Self.shift,   owner: 1, processID: 100)
        hold.press(Self.command, owner: 1, processID: 200)

        #expect(hold.modifiers(processID: 100) == .shift)
        #expect(hold.modifiers(processID: 200) == .command)
    }

    @Test("a release answers in reverse press order")
    func releaseIsReversePressOrder() {
        let hold = KeyHold()
        hold.press(Self.command,                   owner: 1, processID: 100)
        hold.press(Self.shift,                     owner: 1, processID: 100)
        hold.press(KeyHold.HeldKey(virtualKey: 6), owner: 1, processID: 100)

        // Last pressed, first released: what a hand does, and what keeps a
        // modifier held around the key it was modifying until that key is up.
        #expect(hold.releaseAll(owner: 1, processID: 100).map(\.virtualKey) == [6, 56, 55])
    }

    @Test("a key held across a layout change is released by the key that went down")
    func heldKeyOutlivesALayoutChange() {
        let hold = KeyHold()
        // Resolved from "c" under Dvorak, where c is not where a QWERTY layout
        // puts it. If the release resolved the character again under the layout
        // the person switched to, it would lift a key that was never pressed
        // and leave this one down forever.
        hold.press(
            KeyHold.HeldKey(virtualKey: 34, character: "c"),
            owner    : 1,
            processID: 100
        )

        #expect(hold.heldVirtualKey(resolvedFrom: "c", owner: 1, processID: 100) == 34)
        #expect(hold.heldVirtualKey(resolvedFrom: "c", owner: 2, processID: 100) == nil)
        #expect(hold.heldVirtualKey(resolvedFrom: "z", owner: 1, processID: 100) == nil)
    }

    @Test("an emptied process keeps no entry behind")
    func emptyEntriesAreDiscarded() {
        let hold = KeyHold()
        hold.press(Self.shift, owner: 1, processID: 100)
        hold.press(Self.shift, owner: 2, processID: 100)

        #expect(hold.retainedTargetCount == 1)
        _ = hold.releaseAll(owner: 1, processID: 100)
        #expect(hold.retainedTargetCount == 1)
        #expect(hold.release(virtualKey: 56, owner: 2, processID: 100))
        // A registry that kept one empty dictionary per process ever touched
        // would grow for the life of the process.
        #expect(hold.retainedTargetCount == 0)
    }
}
