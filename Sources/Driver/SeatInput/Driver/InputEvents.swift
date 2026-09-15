//
//  InputEvents.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

/// PreparedEvent is one built event with the two things the posting loop needs
/// besides it: where it lands inside the target window, and how long to wait
/// after it went out.
///
/// The window point is optional and that is the whole routing rule: an event
/// that carries one is written into the record and reaches a window, an event
/// that carries none reaches the process and its key window. Keyboard events
/// are the second kind, which is why a key press needs no coordinates at all.
nonisolated package struct PreparedEvent {

    package let event: CGEvent

    /// The point inside the target window, measured from its top left, or `nil`
    /// for an event that is not routed to a window.
    package let windowPointFromTop: CGPoint?

    /// The pause after this event is posted, from the platform's pacing. Zero
    /// for everything but a drag: a click is a plain down and up with nothing
    /// in between.
    package let delayAfterPostingMicroseconds: UInt32

    package init(
        event                        : CGEvent,
        windowPointFromTop           : CGPoint?,
        delayAfterPostingMicroseconds: UInt32 = 0
    ) {
        self.event                         = event
        self.windowPointFromTop            = windowPointFromTop
        self.delayAfterPostingMicroseconds = delayAfterPostingMicroseconds
    }
}

/// InputEvents turns one Command into the events that carry it. It is the pure
/// half of the driver: it touches no private primitive, posts nothing, and can
/// therefore be unit tested on any machine, which is where the shape of every
/// Command is actually asserted.
///
/// It appends into a buffer the caller owns rather than returning an array,
/// because the driver reuses one buffer across sends and the `send` budget of
/// spec section 8 is zero attributable allocations.
nonisolated package enum InputEvents {

    /// The number of explicit buffer materialisations in this source path.
    /// This is not an allocator count: CoreGraphics and Swift may allocate
    /// internally, which only the benchmark's allocator hook can measure.
    package static func explicitBufferCopyCount(
        for command: InputCommand,
        builtEventCount: Int
    ) -> Int {
        switch command {
        case .key(_, let text, _):
            text.isEmpty ? 0 : 1
        case .text:
            builtEventCount / 2
        case .insertText:
            1
        case .click, .drag, .scroll:
            0
        }
    }

    /// Builds `command` into `events`. Nothing is posted here and no field of
    /// the record is written: what comes out is a list of CoreGraphics events
    /// with the marker already on them.
    ///
    /// The marker goes into `eventSourceUserData`, which is what the cursor
    /// fence reads to tell the driver's own events from the person's hand, and
    /// on mouse events into `mouseEventNumber` as well, which is what a target
    /// application reads to group a press with its release.
    package static func append(
        _ command    : InputCommand,
        source       : CGEventSource,
        pacing       : DragPacing,
        correlationID: Int64,
        into events  : inout [PreparedEvent]
    ) throws {

        switch command {
        case .key(let virtualKey, let text, let flags):
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
                let up   = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
            else {
                throw InputFailure.eventCreationFailed
            }
            down.flags = flags
            up.flags   = flags
            if !text.isEmpty {
                // The character travels on the event, so a keyboard layout the
                // kit knows nothing about still produces the right one.
                var utf16 = Array(text.utf16)
                utf16.withUnsafeMutableBufferPointer { buffer in
                    down.keyboardSetUnicodeString(
                        stringLength : buffer.count,
                        unicodeString: buffer.baseAddress
                    )
                    up.keyboardSetUnicodeString(
                        stringLength : buffer.count,
                        unicodeString: buffer.baseAddress
                    )
                }
            }
            mark(down, correlationID: correlationID, isMouse: false)
            mark(up,   correlationID: correlationID, isMouse: false)
            events.append(PreparedEvent(event: down, windowPointFromTop: nil))
            events.append(PreparedEvent(event: up,   windowPointFromTop: nil))

        case .text(let text):
            guard !text.isEmpty else { throw InputFailure.emptyText }
            for character in text {
                try append(
                    .key(virtualKey: 0, text: String(character), flags: []),
                    source       : source,
                    pacing       : pacing,
                    correlationID: correlationID,
                    into         : &events
                )
            }

        case .insertText(let text):
            guard !text.isEmpty else { throw InputFailure.emptyText }
            // The same pair a bare key produces, with the whole string as the
            // payload instead of one character: two events for any length, and
            // the target's own input client is what splits it, or does not.
            try append(
                .key(virtualKey: 0, text: text, flags: []),
                source       : source,
                pacing       : pacing,
                correlationID: correlationID,
                into         : &events
            )

        case .click(let location, let button):
            guard location.isFinite else { throw InputFailure.invalidLocation }
            // Which two event types a button presses is the button's own answer,
            // and CoreGraphics writes their raw values into the record's type
            // byte itself: nothing here stamps 0x03 or 0x04 by hand.
            let types = button.eventTypes
            guard
                let down = mouseEvent(
                    types.down, at: location.screenPoint, button: button, source: source
                ),
                let up = mouseEvent(
                    types.up, at: location.screenPoint, button: button, source: source
                )
            else {
                throw InputFailure.eventCreationFailed
            }
            mark(down, correlationID: correlationID, isMouse: true)
            mark(up,   correlationID: correlationID, isMouse: true)
            events.append(PreparedEvent(event: down, windowPointFromTop: location.windowPointFromTop))
            events.append(PreparedEvent(event: up,   windowPointFromTop: location.windowPointFromTop))

        case .drag(let path, let flags):
            guard path.count >= 3 else { throw InputFailure.invalidDragPath(pointCount: path.count) }
            guard let start = path.first, path.allSatisfy(\.isFinite) else {
                throw InputFailure.invalidLocation
            }
            // A background application can drop the press when its own idea of
            // where the pointer is has gone stale, so the drag opens by telling
            // it where the mouse is. The three point drag failed on Chromium
            // even prepared; the paced path is the one that passed.
            guard let opening = mouseEvent(.mouseMoved, at: start.screenPoint, source: source) else {
                throw InputFailure.eventCreationFailed
            }
            mark(opening, correlationID: correlationID, isMouse: true)
            events.append(PreparedEvent(
                event                        : opening,
                windowPointFromTop           : start.windowPointFromTop,
                delayAfterPostingMicroseconds: pacing.openingMoveMicroseconds
            ))

            for (index, location) in path.enumerated() {
                let type: CGEventType = switch index {
                case 0:              .leftMouseDown
                case path.count - 1: .leftMouseUp
                default:             .leftMouseDragged
                }
                guard let event = mouseEvent(type, at: location.screenPoint, source: source) else {
                    throw InputFailure.eventCreationFailed
                }
                event.flags = flags
                mark(event, correlationID: correlationID, isMouse: true)
                events.append(PreparedEvent(
                    event                        : event,
                    windowPointFromTop           : location.windowPointFromTop,
                    delayAfterPostingMicroseconds: index == 0
                        ? pacing.pressMicroseconds
                        : pacing.stepMicroseconds
                ))
            }

        case .scroll(let location, let deltaY):
            guard location.isFinite else { throw InputFailure.invalidLocation }
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units                  : .line,
                wheelCount             : 1,
                wheel1                 : deltaY,
                wheel2                 : 0,
                wheel3                 : 0
            ) else {
                throw InputFailure.eventCreationFailed
            }
            event.location = location.screenPoint
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            mark(event, correlationID: correlationID, isMouse: false)
            events.append(PreparedEvent(
                event             : event,
                windowPointFromTop: location.windowPointFromTop
            ))
        }
    }

    private static func mouseEvent(
        _ type  : CGEventType,
        at point: CGPoint,
        button  : MouseButton = .left,
        source  : CGEventSource
    ) -> CGEvent? {
        CGEvent(
            mouseEventSource   : source,
            mouseType          : type,
            mouseCursorPosition: point,
            mouseButton        : button.cgButton
        )
    }

    /// One event at a time and never an array: the click path of the driver
    /// has an allocation budget of zero, and an array literal here would be one
    /// allocation per send.
    private static func mark(_ event: CGEvent, correlationID: Int64, isMouse: Bool) {
        event.setIntegerValueField(.eventSourceUserData, value: correlationID)
        guard isMouse else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventNumber, value: correlationID)
    }
}
