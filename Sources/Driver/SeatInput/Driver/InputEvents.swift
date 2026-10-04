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

    /// The pause after this event is posted. A single click has no pause;
    /// repeated clicks pause only between complete pairs, and drags use
    /// the platform's pacing.
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
        case .key(_, let text, _, _, _):
            // One materialisation for the whole Command whatever the phase
            // builds: a repeat of thirty two downs reuses the same buffer a
            // single press does.
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
        _ command      : InputCommand,
        source         : CGEventSource,
        pacing         : DragPacing,
        keyRepeatPacing: KeyRepeatPacing = .systemDefault,
        held           : Modifiers = [],
        policy         : ModifierPolicy = .eventFlags,
        correlationID  : Int64,
        into events    : inout [PreparedEvent]
    ) throws {

        switch command {
        case .key(let virtualKey, let text, let modifiers, let phase, _):
            if case .repeated(let count) = phase {
                // Refused here, before the first event is built, because the
                // posting loop has no way to stop: a count that cannot be
                // posted has to be caught while nothing has gone out yet.
                guard (1 ... KeyPhase.maximumRepeatCount).contains(count) else {
                    throw InputFailure.invalidRepeatCount(
                        requested: count,
                        maximum  : KeyPhase.maximumRepeatCount
                    )
                }
            }
            // What the session already holds is carried too, and only what this
            // Command names is its own to press and release. A session holding
            // Shift that sends Command and C delivers Command, Shift and C,
            // which is what a hand on a keyboard would produce.
            let effective = held.union(modifiers)
            // A key that is itself a modifier carries its own bit on the way
            // down and not on the way up, which is what the real key does.
            let ownModifier = Modifiers(virtualKey: virtualKey)
            let downFlags   = (ownModifier.map { effective.union($0) } ?? effective).cgFlags
            let upFlags     = (ownModifier.map { effective.subtracting($0) } ?? effective).cgFlags
            // Materialised once for the whole Command and reused by every event
            // it builds, which is what keeps a repeat of thirty two downs at the
            // same explicit copy count as a single press.
            var utf16 = text.isEmpty ? [] : Array(text.utf16)

            func appendKeyEvent(
                isDown    : Bool,
                autorepeat: Bool,
                delay     : UInt32
            ) throws {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey         : virtualKey,
                    keyDown            : isDown
                ) else {
                    throw InputFailure.eventCreationFailed
                }
                event.flags = isDown ? downFlags : upFlags
                // The autorepeat field is deliberately **not** written, and
                // `autorepeat` only says which phase asked for it.
                //
                // Measured on 26A428 against both target families: an event
                // carrying `keyboardEventAutorepeat` is not delivered at all.
                // Twelve counts across three intervals, on an AppKit target and
                // a Chromium renderer, zero arrived every time, while four
                // ordinary presses arrived four times out of four on both. The
                // pacing changed nothing, so it is the field and not the speed.
                // A repeat is therefore posted as ordinary key downs, and what
                // that gives up is written on `KeyPhase.repeated`.
                _ = autorepeat
                if !utf16.isEmpty {
                    // The character travels on the event, so a keyboard layout
                    // the kit knows nothing about still produces the right one.
                    utf16.withUnsafeMutableBufferPointer { buffer in
                        event.keyboardSetUnicodeString(
                            stringLength : buffer.count,
                            unicodeString: buffer.baseAddress
                        )
                    }
                }
                mark(event, correlationID: correlationID, isMouse: false)
                events.append(PreparedEvent(
                    event                        : event,
                    windowPointFromTop           : nil,
                    delayAfterPostingMicroseconds: delay
                ))
            }

            // A modifier transition carries the **whole** current modifier
            // state, not the one bit that moved: pressing Command then Shift
            // produces flagsChanged(Command) and flagsChanged(Command, Shift).
            // Emitting only the bit that changed is the easy mistake.
            func appendTransition(cumulative: Modifiers, keyOf modifier: Modifiers) throws {
                guard let transitionKey = modifier.singleVirtualKey else { return }
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey         : transitionKey,
                    keyDown            : true
                ) else {
                    throw InputFailure.eventCreationFailed
                }
                // CoreGraphics has no constructor for a transition, so the type
                // is reassigned. That the reassignment sticks is what
                // `RecordLayout.verifyFlagsChangedRecord()` proves on the build
                // before this policy is allowed at all.
                event.type  = .flagsChanged
                event.flags = cumulative.cgFlags
                mark(event, correlationID: correlationID, isMouse: false)
                events.append(PreparedEvent(event: event, windowPointFromTop: nil))
            }

            let usesTransitions = policy == .flagsChanged
            // Only what this Command does not already hold is its own to press
            // and, afterwards, to release. The rest stays exactly as it was.
            let added = modifiers.subtracting(held)

            // A modifier key under the transition policy **is** a transition: a
            // real keyboard reports Shift going down as flagsChanged and never
            // as a key down. An ordinary key stays a key down and up, wrapped
            // by the transitions of the modifiers this Command adds.
            let modifierKeyTransitions = usesTransitions && ownModifier != nil

            switch phase {
            case .press:
                if modifierKeyTransitions, let ownModifier {
                    try appendTransition(cumulative: held.union(ownModifier),     keyOf: ownModifier)
                    try appendTransition(cumulative: held.subtracting(ownModifier), keyOf: ownModifier)
                    break
                }
                var cumulative = held
                if usesTransitions {
                    for modifier in added.inPressOrder {
                        cumulative.insert(modifier)
                        try appendTransition(cumulative: cumulative, keyOf: modifier)
                    }
                }
                try appendKeyEvent(isDown: true,  autorepeat: false, delay: 0)
                try appendKeyEvent(isDown: false, autorepeat: false, delay: 0)
                if usesTransitions {
                    // The exact inverse, and only of what this Command pressed.
                    for modifier in added.inPressOrder.reversed() {
                        cumulative.remove(modifier)
                        try appendTransition(cumulative: cumulative, keyOf: modifier)
                    }
                }

            case .down:
                if modifierKeyTransitions, let ownModifier {
                    try appendTransition(cumulative: held.union(ownModifier), keyOf: ownModifier)
                } else {
                    try appendKeyEvent(isDown: true, autorepeat: false, delay: 0)
                }

            case .up:
                if modifierKeyTransitions, let ownModifier {
                    try appendTransition(
                        cumulative: held.subtracting(ownModifier),
                        keyOf     : ownModifier
                    )
                } else {
                    try appendKeyEvent(isDown: false, autorepeat: false, delay: 0)
                }

            case .repeated(let count):
                // No pause after the last repeat. A drag pays one after its
                // final event and nothing notices; here the pause is held
                // exclusion on the target for every other driver in the
                // process, and the last one buys nothing.
                for index in 0 ..< count {
                    try appendKeyEvent(
                        isDown    : true,
                        autorepeat: true,
                        delay     : index == count - 1 ? 0 : keyRepeatPacing.intervalMicroseconds
                    )
                }
            }

        case .text(let text):
            guard !text.isEmpty else { throw InputFailure.emptyText }
            // Two events per cluster inside one atomic Command, so the ceiling
            // is about the exclusion this holds as much as about delivery.
            guard text.count <= TextLimits.maximumTypedClusters else {
                throw InputFailure.textTooLong(
                    TextMeasure(text.count, .graphemeClusters),
                    maximum: TextLimits.maximumTypedClusters
                )
            }
            for character in text {
                try append(
                    .key(virtualKey: 0, text: String(character), modifiers: []),
                    source         : source,
                    pacing         : pacing,
                    keyRepeatPacing: keyRepeatPacing,
                    held           : held,
                    policy         : policy,
                    correlationID  : correlationID,
                    into           : &events
                )
            }

        case .insertText(let text):
            guard !text.isEmpty else { throw InputFailure.emptyText }
            guard text.utf16.count <= TextLimits.maximumInsertedCodeUnits else {
                throw InputFailure.textTooLong(
                    TextMeasure(text.utf16.count, .utf16CodeUnits),
                    maximum: TextLimits.maximumInsertedCodeUnits
                )
            }
            // The same pair a bare key produces, with the whole string as the
            // payload instead of one character: two events for any length, and
            // the target's own input client is what splits it, or does not.
            try append(
                .key(virtualKey: 0, text: text, modifiers: []),
                source         : source,
                pacing         : pacing,
                keyRepeatPacing: keyRepeatPacing,
                held           : held,
                policy         : policy,
                correlationID  : correlationID,
                into           : &events
            )

        case .click(let location, let button, let count):
            guard (1...InputCommand.maximumClickCount).contains(count) else {
                throw InputFailure.invalidClickCount(
                    requested: count,
                    maximum: InputCommand.maximumClickCount
                )
            }
            guard location.isFinite else { throw InputFailure.invalidLocation }
            // Which two event types a button presses is the button's own answer,
            // and CoreGraphics writes their raw values into the record's type
            // byte itself: nothing here stamps 0x03 or 0x04 by hand.
            let types = button.eventTypes
            for ordinal in 1...count {
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
                mark(up, correlationID: correlationID, isMouse: true)
                down.setIntegerValueField(.mouseEventClickState, value: Int64(ordinal))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(ordinal))
                events.append(PreparedEvent(event: down, windowPointFromTop: location.windowPointFromTop))
                events.append(PreparedEvent(
                    event: up,
                    windowPointFromTop: location.windowPointFromTop,
                    delayAfterPostingMicroseconds: ordinal == count ? 0 : 50_000
                ))
            }

        case .drag(let path, let modifiers):
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
                event.flags = held.union(modifiers).cgFlags
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
            // The private source retains flags from prior directed key events.
            // Scroll reflects only this Turn's held keys, not that cached state.
            event.flags = held.cgFlags
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
