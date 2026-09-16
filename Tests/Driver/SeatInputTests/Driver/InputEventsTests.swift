//
//  InputEventsTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
@testable import SeatInput
import Testing

/// What one Command turns into, asserted on the events themselves. Nothing here
/// posts anything: the events are built with a private source, read, and thrown
/// away, which is the same method the record's offsets were measured with and
/// the reason these tests run anywhere, in parallel, with no grant.
@Suite("The events one Command turns into")
struct InputEventsTests {

    /// A private source, or the test is meaningless rather than failing.
    private func makeSource() throws -> CGEventSource {
        try #require(CGEventSource(stateID: .privateState))
    }

    private func build(
        _ command      : InputCommand,
        correlationID  : Int64 = 7,
        pacing         : DragPacing = .realistic,
        keyRepeatPacing: KeyRepeatPacing = .systemDefault,
        held           : Modifiers = [],
        policy         : ModifierPolicy = .eventFlags
    ) throws -> [PreparedEvent] {
        var events: [PreparedEvent] = []
        try InputEvents.append(
            command,
            source         : try makeSource(),
            pacing         : pacing,
            keyRepeatPacing: keyRepeatPacing,
            held           : held,
            policy         : policy,
            correlationID  : correlationID,
            into           : &events
        )
        return events
    }

    private func location(_ x: CGFloat, _ y: CGFloat) -> InputLocation {
        InputLocation(
            screenPoint       : CGPoint(x: x, y: y),
            windowPointFromTop: CGPoint(x: x - 100, y: y - 200)
        )
    }

    // MARK: click

    @Test("a click is a bare down and up, both routed, with no pause between them")
    func clickIsBareDownAndUp() throws {
        let events = try build(.click(location(300, 400)))

        #expect(events.count == 2)
        #expect(events.map(\.event.type) == [.leftMouseDown, .leftMouseUp])
        #expect(events.allSatisfy { $0.windowPointFromTop == CGPoint(x: 200, y: 200) })
        #expect(events.allSatisfy { $0.event.location == CGPoint(x: 300, y: 400) })
        // No `mouseMoved` primer and no 12 or 28 ms pauses: all three were
        // measured unnecessary on both target families.
        #expect(events.allSatisfy { $0.delayAfterPostingMicroseconds == 0 })
    }

    @Test("every mouse event carries the marker twice, for the fence and for the target")
    func mouseEventsCarryTheMarker() throws {
        let events = try build(.click(location(10, 20)), correlationID: 4242)

        for item in events {
            #expect(item.event.getIntegerValueField(.eventSourceUserData) == 4242)
            #expect(item.event.getIntegerValueField(.mouseEventNumber) == 4242)
            #expect(item.event.getIntegerValueField(.mouseEventClickState) == 1)
        }
    }

    @Test("a click with a coordinate that is not finite builds nothing")
    func nonFiniteClickRefuses() {
        let broken = InputLocation(
            screenPoint       : CGPoint(x: CGFloat.nan, y: 0),
            windowPointFromTop: .zero
        )
        #expect(throws: InputFailure.invalidLocation) { try build(.click(broken)) }
    }

    @Test("the button decides the two event types, and the left one is still the default")
    func theButtonDecidesTheTypes() throws {
        #expect(try build(.click(location(300, 400))).map(\.event.type)
            == [.leftMouseDown, .leftMouseUp])
        #expect(try build(.click(location(300, 400), button: .right)).map(\.event.type)
            == [.rightMouseDown, .rightMouseUp])
    }

    @Test("a right click is routed exactly like a left one, which is what opens a menu at all")
    func aRightClickIsRoutedToo() throws {
        let events = try build(.click(location(300, 400), button: .right), correlationID: 9)

        // The window point is the whole difference between a right click that
        // opens a menu and one that reaches the process with no view to go to.
        #expect(events.allSatisfy { $0.windowPointFromTop == CGPoint(x: 200, y: 200) })
        #expect(events.allSatisfy { $0.event.getIntegerValueField(.mouseEventNumber) == 9 })
        #expect(events.allSatisfy { $0.delayAfterPostingMicroseconds == 0 })
        #expect(events.allSatisfy {
            $0.event.getIntegerValueField(.mouseEventButtonNumber) == 1
        })
    }

    /// The rule the ledger states, checked against records CoreGraphics built
    /// rather than against a table written down twice.
    @Test("the record's type byte is the event type's own raw value, for both buttons")
    func theTypeByteIsTheRawValue() throws {
        let left  = try build(.click(location(1, 2)))
        let right = try build(.click(location(1, 2), button: .right))

        #expect(RecordLayout.typeByte(of: left[0].event.type)  == 0x01)
        #expect(RecordLayout.typeByte(of: left[1].event.type)  == 0x02)
        #expect(RecordLayout.typeByte(of: right[0].event.type) == 0x03)
        #expect(RecordLayout.typeByte(of: right[1].event.type) == 0x04)
    }

    // MARK: keyboard

    @Test("a key is a down and an up, unrouted, and the modifiers are held for both")
    func keyIsDownAndUpUnrouted() throws {
        let events = try build(.key(virtualKey: 6, text: "Z", modifiers: .command))

        #expect(events.count == 2)
        #expect(events.map(\.event.type) == [.keyDown, .keyUp])
        // No window point: a key press reaches the process and its key window,
        // and writing a location into it would be a coordinate nobody reads.
        #expect(events.allSatisfy { $0.windowPointFromTop == nil })
        #expect(events.allSatisfy { $0.event.flags.contains(.maskCommand) })
        #expect(events.allSatisfy { $0.event.getIntegerValueField(.eventSourceUserData) == 7 })
    }

    // MARK: the declared ceilings

    @Test("the largest measured inserted string still builds")
    func measuredInsertedCeilingIsAccepted() throws {
        let text   = String(repeating: "a", count: TextLimits.maximumInsertedCodeUnits)
        let events = try build(.insertText(text))

        // Two events at any length, which is the whole point of this path.
        #expect(events.count == 2)
    }

    @Test("one code unit past the measured ceiling refuses")
    func insertedTextAboveTheCeilingRefuses() {
        let text = String(repeating: "a", count: TextLimits.maximumInsertedCodeUnits + 1)

        #expect(throws: InputFailure.textTooLong(
            TextMeasure(TextLimits.maximumInsertedCodeUnits + 1, .utf16CodeUnits),
            maximum: TextLimits.maximumInsertedCodeUnits
        )) {
            try build(.insertText(text))
        }
    }

    @Test("the ceiling of an inserted string counts code units and not keystrokes")
    func insertedCeilingCountsCodeUnits() {
        // Emoji built from a joiner sequence: well under the ceiling in
        // keystrokes, well over it in what the event actually carries. Counting
        // the wrong unit here would post an unmeasured payload.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text   = String(repeating: family, count: 1200)

        #expect(text.count < TextLimits.maximumInsertedCodeUnits)
        #expect(text.utf16.count > TextLimits.maximumInsertedCodeUnits)
        #expect(throws: InputFailure.self) { try build(.insertText(text)) }
    }

    @Test("a typed string refuses past its own ceiling, counted in keystrokes")
    func typedTextAboveTheCeilingRefuses() {
        let text = String(repeating: "a", count: TextLimits.maximumTypedClusters + 1)

        #expect(throws: InputFailure.textTooLong(
            TextMeasure(TextLimits.maximumTypedClusters + 1, .graphemeClusters),
            maximum: TextLimits.maximumTypedClusters
        )) {
            try build(.text(text))
        }
    }

    @Test("the chunk limit sits below the ceiling a single Command may carry")
    func chunkLimitsStayUnderTheCeilings() {
        // A chunk that could not be posted as a Command would make `sendText`
        // build pieces the driver then refuses, one at a time.
        #expect(TextDeliveryLimits.measured.maximumCodeUnits <= TextLimits.maximumInsertedCodeUnits)
        #expect(TextDeliveryLimits.measured.maximumClusters  <= TextLimits.maximumTypedClusters)
    }

    // MARK: the transition policy

    /// EventState is what one built event announces: its kind and the modifier
    /// state it carries. A transition says what is held *after* it; a key event
    /// says what was held while it was pressed. Arrays of tuples are not
    /// Equatable in Swift, and a whole expected sequence in one expectation is
    /// what makes a wrong order readable when it fails.
    private struct EventState: Equatable, CustomStringConvertible {
        let type     : CGEventType
        let modifiers: Modifiers

        init(_ type: CGEventType, _ modifiers: Modifiers) {
            self.type      = type
            self.modifiers = modifiers
        }

        var description: String { "\(type.rawValue):\(modifiers.rawValue)" }
    }

    private func states(of events: [PreparedEvent]) -> [EventState] {
        events.map { EventState($0.event.type, Modifiers($0.event.flags)) }
    }

    @Test("the default policy posts no transitions at all")
    func eventFlagsPostsNoTransitions() throws {
        let events = try build(.key(virtualKey: 8, text: "c", modifiers: [.command, .shift]))

        #expect(events.map(\.event.type) == [.keyDown, .keyUp])
    }

    @Test("a shortcut presses what it adds, types, and releases the exact inverse")
    func transitionsWrapTheKeyInInverseOrder() throws {
        let events = try build(
            .key(virtualKey: 8, text: "c", modifiers: [.command, .shift]),
            policy: .flagsChanged
        )

        // Cumulative and never differential: the second transition says Command
        // *and* Shift, not Shift alone.
        #expect(states(of: events) == [
            EventState(.flagsChanged, [.command]),
            EventState(.flagsChanged, [.command, .shift]),
            EventState(.keyDown,      [.command, .shift]),
            EventState(.keyUp,        [.command, .shift]),
            EventState(.flagsChanged, [.command]),
            EventState(.flagsChanged, []),
        ])
    }

    @Test("the transitions carry the keycode of the modifier that moved")
    func transitionsCarryTheirOwnKeycode() throws {
        let events = try build(
            .key(virtualKey: 8, text: "c", modifiers: [.command, .shift]),
            policy: .flagsChanged
        )
        let keycodes = events
            .filter { $0.event.type == .flagsChanged }
            .map { $0.event.getIntegerValueField(.keyboardEventKeycode) }

        // Command is 55 and Shift is 56, pressed in bit order and released in
        // the exact inverse.
        #expect(keycodes == [55, 56, 56, 55])
    }

    @Test("a shortcut adds only what the session does not already hold")
    func transitionsSkipWhatIsAlreadyHeld() throws {
        let events = try build(
            .key(virtualKey: 8, text: "c", modifiers: [.command, .shift]),
            held  : .shift,
            policy: .flagsChanged
        )

        // Shift was already down and stays down: this Command's transitions are
        // Command's alone, and the key still carries both.
        #expect(states(of: events) == [
            EventState(.flagsChanged, [.command, .shift]),
            EventState(.keyDown,      [.command, .shift]),
            EventState(.keyUp,        [.command, .shift]),
            EventState(.flagsChanged, [.shift]),
        ])
    }

    @Test("pressing a modifier key is a transition and not a key down")
    func modifierKeyBecomesATransition() throws {
        let down = try build(.key(virtualKey: 56, text: "", phase: .down), policy: .flagsChanged)
        let up   = try build(
            .key(virtualKey: 56, text: "", phase: .up),
            held  : .shift,
            policy: .flagsChanged
        )

        #expect(states(of: down) == [EventState(.flagsChanged, .shift)])
        #expect(states(of: up)   == [EventState(.flagsChanged, [])])
    }

    @Test("a press of a modifier key is its transition down and back up")
    func modifierKeyPressIsBothTransitions() throws {
        let events = try build(.key(virtualKey: 55, text: "", phase: .press), policy: .flagsChanged)

        #expect(states(of: events) == [
            EventState(.flagsChanged, .command),
            EventState(.flagsChanged, []),
        ])
    }

    @Test("a shortcut with nothing to add posts no transitions under either policy")
    func noAddedModifiersMeansNoTransitions() throws {
        let events = try build(.key(virtualKey: 8, text: "c"), policy: .flagsChanged)

        #expect(events.map(\.event.type) == [.keyDown, .keyUp])
    }

    // MARK: held modifiers

    @Test("a Command carries what the session already holds on top of its own")
    func heldModifiersAreCarried() throws {
        let events = try build(
            .key(virtualKey: 8, text: "c", modifiers: .command),
            held: .shift
        )

        // A session holding Shift that sends Command and C delivers Command,
        // Shift and C, which is what a hand on a keyboard would produce. The
        // shortcut does not clear a context the caller built on purpose.
        #expect(events.allSatisfy { Modifiers($0.event.flags) == [.command, .shift] })
    }

    @Test("a held modifier that the Command also names is not counted twice")
    func heldAndOwnedModifiersUnion() throws {
        let events = try build(
            .key(virtualKey: 8, text: "c", modifiers: .command),
            held: .command
        )

        #expect(events.allSatisfy { Modifiers($0.event.flags) == .command })
    }

    @Test("a drag carries the session's held modifiers too")
    func dragCarriesHeldModifiers() throws {
        let events = try build(
            .drag(points: [location(0, 0), location(40, 0), location(80, 0)], modifiers: .option),
            held: .command
        )

        #expect(events.dropFirst().allSatisfy {
            Modifiers($0.event.flags) == [.option, .command]
        })
    }

    @Test("pressing a modifier key carries its own bit down and not up")
    func modifierKeyCarriesItsOwnBit() throws {
        let events = try build(.key(virtualKey: 56, text: "", phase: .press))

        // What the real key does: the down is already shifted, the up is not.
        #expect(Modifiers(events[0].event.flags) == .shift)
        #expect(Modifiers(events[1].event.flags) == [])
    }

    @Test("releasing a modifier key drops its bit even while the session holds it")
    func modifierUpDropsItsOwnBit() throws {
        let events = try build(.key(virtualKey: 55, text: "", phase: .up), held: .command)

        #expect(Modifiers(events[0].event.flags) == [])
    }

    // MARK: phases and repeat

    @Test("a phase builds exactly the events it names", arguments: [
        (KeyPhase.press, [CGEventType.keyDown, .keyUp]),
        (.down,          [.keyDown]),
        (.up,            [.keyUp]),
    ])
    func phaseBuildsItsEvents(phase: KeyPhase, types: [CGEventType]) throws {
        let events = try build(.key(virtualKey: 6, text: "Z", phase: phase))

        #expect(events.map(\.event.type) == types)
        #expect(events.count == phase.eventCount)
    }

    @Test("a repeat is that many plain downs, with the autorepeat field left alone")
    func repeatIsPlainDowns() throws {
        let events = try build(.key(virtualKey: 124, text: "", phase: .repeated(count: 4)))

        #expect(events.count == 4)
        #expect(events.allSatisfy { $0.event.type == .keyDown })
        // Not marked as repeats, and that is the whole finding of ticket A3's
        // sweep: an event carrying the autorepeat field was delivered to
        // neither target family, at any count and any pacing, while ordinary
        // presses arrived every time.
        #expect(events.allSatisfy { $0.event.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
        // A repeat carries no up of its own: it is what happens between a down
        // and an up, so the caller sends those around it.
        #expect(!events.contains { $0.event.type == .keyUp })
    }

    @Test("a press and a down are not marked as repeats")
    func ordinaryKeysAreNotRepeats() throws {
        let events = try build(.key(virtualKey: 6, text: "Z"))

        #expect(events.allSatisfy { $0.event.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
    }

    @Test("the repeats are paced, and the last one is not")
    func repeatPacingSkipsTheLastGap() throws {
        let pacing = KeyRepeatPacing(intervalMicroseconds: 12_345)
        let events = try build(
            .key(virtualKey: 124, text: "", phase: .repeated(count: 3)),
            keyRepeatPacing: pacing
        )

        // The trailing pause a drag pays after its final event is held
        // exclusion on the target here, and it buys nothing.
        #expect(events.map(\.delayAfterPostingMicroseconds) == [12_345, 12_345, 0])
    }

    @Test("a repeat holds its modifiers on every down")
    func repeatHoldsItsModifiers() throws {
        let events = try build(
            .key(virtualKey: 124, text: "", modifiers: .option, phase: .repeated(count: 3))
        )

        #expect(events.allSatisfy { $0.event.flags.contains(.maskAlternate) })
    }

    @Test("a repeat count that cannot be posted is refused before anything is built", arguments: [
        0, -1, KeyPhase.maximumRepeatCount + 1,
    ])
    func invalidRepeatCountRefuses(count: Int) throws {
        // Refused during construction and not during posting: the posting loop
        // has no way to stop, so a count it could not finish has to be caught
        // while nothing has gone out.
        #expect(throws: InputFailure.invalidRepeatCount(
            requested: count,
            maximum  : KeyPhase.maximumRepeatCount
        )) {
            try build(.key(virtualKey: 124, text: "", phase: .repeated(count: count)))
        }
    }

    @Test("the largest accepted repeat still builds")
    func maximumRepeatCountIsAccepted() throws {
        let events = try build(
            .key(virtualKey: 124, text: "", phase: .repeated(count: KeyPhase.maximumRepeatCount))
        )

        #expect(events.count == KeyPhase.maximumRepeatCount)
    }

    @Test("a repeat materialises its text once, however many downs it builds")
    func repeatReusesOneBuffer() throws {
        let command = InputCommand.key(
            virtualKey: 6, text: "Z", phase: .repeated(count: KeyPhase.maximumRepeatCount)
        )
        let events = try build(command)

        #expect(InputEvents.explicitBufferCopyCount(
            for            : command,
            builtEventCount: events.count
        ) == 1)
    }

    @Test("the text a key produces travels on the event")
    func keyCarriesItsText() throws {
        let events = try build(.key(virtualKey: 0, text: "à"))
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        events[0].event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &characters
        )
        #expect(length == 1)
        #expect(String(utf16CodeUnits: characters, count: length) == "à")
    }

    // MARK: text

    @Test("text costs two events per character, which is why long text is paced")
    func textIsLinearInItsLength() throws {
        // The number the text pacing exists for: the event count of a `.text`
        // grows with the text, and a target's queue drains at its own speed.
        #expect(try build(.text(String(repeating: "a", count: 64))).count == 128)
    }

    @Test("text becomes one down and up pair per character")
    func textExpandsPerCharacter() throws {
        let events = try build(.text("abc"))

        #expect(events.count == 6)
        #expect(events.map(\.event.type) == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        #expect(events.allSatisfy { $0.windowPointFromTop == nil })
    }

    @Test("empty text is refused rather than posted as nothing")
    func emptyTextRefuses() {
        #expect(throws: InputFailure.emptyText) { try build(.text("")) }
    }

    // MARK: insertText

    @Test("inserted text is two events whatever its length")
    func insertedTextIsTwoEventsAtAnyLength() throws {
        for length in [1, 64, 8_192] {
            let events = try build(.insertText(String(repeating: "a", count: length)))

            #expect(events.count == 2, "\(length) characters built \(events.count) events")
            #expect(events.map(\.event.type) == [.keyDown, .keyUp])
            #expect(events.allSatisfy { $0.windowPointFromTop == nil })
            #expect(events.allSatisfy { $0.event.flags.isEmpty })
        }
    }

    @Test("the whole string travels on the one key down, unicode and all")
    func insertedTextTravelsWhole() throws {
        let text   = "città " + String(repeating: "z", count: 200)
        let events = try build(.insertText(text))

        var length     = 0
        var characters = [UniChar](repeating: 0, count: text.utf16.count)
        events[0].event.keyboardGetUnicodeString(
            maxStringLength   : text.utf16.count,
            actualStringLength: &length,
            unicodeString     : &characters
        )
        #expect(length == text.utf16.count)
        #expect(String(utf16CodeUnits: characters, count: length) == text)
    }

    /// The whole point of the case, as a number: the same string costs two
    /// events one way and two per character the other.
    @Test("the same string is one key event inserted and two per character typed")
    func insertedTextIsTheCheapShapeOfTheSameString() throws {
        let text = String(repeating: "a", count: 512)

        #expect(try build(.insertText(text)).count == 2)
        #expect(try build(.text(text)).count == 1_024)
    }

    @Test("inserted text carries the marker the fence reads")
    func insertedTextCarriesTheMarker() throws {
        let events = try build(.insertText("abc"), correlationID: 99)

        #expect(events.allSatisfy { $0.event.getIntegerValueField(.eventSourceUserData) == 99 })
    }

    @Test("an empty insertion is refused rather than posted as nothing")
    func emptyInsertedTextRefuses() {
        #expect(throws: InputFailure.emptyText) { try build(.insertText("")) }
    }

    // MARK: scroll

    @Test("a scroll is one routed event, in lines and not continuous")
    func scrollIsOneRoutedEvent() throws {
        let events = try build(.scroll(location(50, 60), deltaY: -6))

        #expect(events.count == 1)
        #expect(events[0].event.type == .scrollWheel)
        #expect(events[0].windowPointFromTop == CGPoint(x: -50, y: -140))
        #expect(events[0].event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        #expect(events[0].event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -6)
    }

    // MARK: drag

    @Test("a drag opens with a move, presses, drags and releases, paced by the platform")
    func dragIsPacedAndComplete() throws {
        let path = InputCommand.drag(from: location(0, 0), to: location(80, 0))
        let events = try build(path)

        // 1 opening move + 10 path points: down, eight dragged, up.
        #expect(events.count == 11)
        #expect(events[0].event.type == .mouseMoved)
        #expect(events[1].event.type == .leftMouseDown)
        #expect(events.last?.event.type == .leftMouseUp)
        #expect(events.dropFirst(2).dropLast().allSatisfy { $0.event.type == .leftMouseDragged })
        #expect(events.allSatisfy { $0.windowPointFromTop != nil })

        #expect(events[0].delayAfterPostingMicroseconds == DragPacing.realistic.openingMoveMicroseconds)
        #expect(events[1].delayAfterPostingMicroseconds == DragPacing.realistic.pressMicroseconds)
        #expect(events[2].delayAfterPostingMicroseconds == DragPacing.realistic.stepMicroseconds)
    }

    @Test("a drag holds the target for one last dragged event before it releases")
    func dragRestsOnTheEndPoint() {
        guard case .drag(let points, _) = InputCommand.drag(
            from: location(0, 0),
            to  : location(80, 40)
        ) else {
            Issue.record("the drag path builder did not build a drag")
            return
        }
        #expect(points.count == 10)
        #expect(points[0].screenPoint == CGPoint(x: 0, y: 0))
        #expect(points[4].screenPoint == CGPoint(x: 40, y: 20))
        // The eighth step already reaches the end, and the end is repeated.
        #expect(points[8].screenPoint == CGPoint(x: 80, y: 40))
        #expect(points[9].screenPoint == CGPoint(x: 80, y: 40))
        // Both frames of reference are interpolated, never derived.
        #expect(points[4].windowPointFromTop == CGPoint(x: -60, y: -180))
    }

    @Test("a drag holds the modifiers on every event of the path but not on the opening move")
    func dragHoldsItsModifiers() throws {
        let command = InputCommand.drag(
            from : location(0, 0),
            to   : location(80, 0),
            modifiers: .shift
        )
        let events = try build(command)

        #expect(events.dropFirst().allSatisfy { $0.event.flags.contains(.maskShift) })
    }

    @Test("a drag needs a start, a middle and an end")
    func shortDragRefuses() {
        #expect(throws: InputFailure.invalidDragPath(pointCount: 2)) {
            try build(.drag(points: [location(0, 0), location(1, 1)]))
        }
    }

    // MARK: the buffer

    @Test("commands append to the buffer the caller owns")
    func commandsAppendToTheSameBuffer() throws {
        var events: [PreparedEvent] = []
        let source = try makeSource()

        for _ in 0..<3 {
            try InputEvents.append(
                .click(location(1, 2)),
                source       : source,
                pacing       : .realistic,
                correlationID: 1,
                into         : &events
            )
        }
        #expect(events.count == 6)
    }
}
