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
        _ command    : InputCommand,
        correlationID: Int64 = 7,
        pacing       : DragPacing = .realistic
    ) throws -> [PreparedEvent] {
        var events: [PreparedEvent] = []
        try InputEvents.append(
            command,
            source       : try makeSource(),
            pacing       : pacing,
            correlationID: correlationID,
            into         : &events
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
        let events = try build(.key(virtualKey: 6, text: "Z", flags: .maskCommand))

        #expect(events.count == 2)
        #expect(events.map(\.event.type) == [.keyDown, .keyUp])
        // No window point: a key press reaches the process and its key window,
        // and writing a location into it would be a coordinate nobody reads.
        #expect(events.allSatisfy { $0.windowPointFromTop == nil })
        #expect(events.allSatisfy { $0.event.flags.contains(.maskCommand) })
        #expect(events.allSatisfy { $0.event.getIntegerValueField(.eventSourceUserData) == 7 })
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
            flags: .maskShift
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
