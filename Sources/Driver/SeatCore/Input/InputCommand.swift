//
//  InputCommand.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// MouseButton is which button a click presses. It has two cases because two
/// are measured: a middle or a fourth button would build an `otherMouseDown`
/// nobody has posted at a background target, and a vocabulary that admits an
/// unmeasured value is a vocabulary that promises one.
///
/// The right button is not a decoration on the left one. It opens a contextual
/// menu inside the target, which is a modal tracking loop in that process, so
/// what an open menu costs and how it is closed again belong to the action that
/// opens one, `AgentSeat.useContextMenu`, and not to the click.
public enum MouseButton: Sendable, Equatable, CaseIterable {

    case left
    case right

    /// The two CoreGraphics event types this button presses and releases.
    ///
    /// It is written once, here, because these raw values are also the byte the
    /// private record carries at 0x08: 1 and 2 for the left button, 3 and 4 for
    /// the right one. `RecordLayout.typeByte(of:)` states that rule; this is
    /// the only place the pair itself is chosen.
    public var eventTypes: (down: CGEventType, up: CGEventType) {
        switch self {
            case .left : (.leftMouseDown,  .leftMouseUp)
            case .right: (.rightMouseDown, .rightMouseUp)
        }
    }

    /// The button an event of this kind carries.
    public var cgButton: CGMouseButton {
        switch self {
            case .left : .left
            case .right: .right
        }
    }
}

/// InputCommand is one complete, atomic input action. One call is one command:
/// the driver never splits it, never retries it and never invents an extra
/// event. The six cases are the whole vocabulary; anything that used to be a
/// variant of a drag (primed, paced, modified) is now either data on the
/// command itself, such as `flags`, or a property of the platform, such as
/// `DragPacing`.
public enum InputCommand: Sendable, Equatable {

    /// One key press and release, optionally carrying the text the key
    /// produces, so a layout the kit does not know still types the right
    /// character. `flags` are the modifiers held for both events.
    case key(virtualKey: CGKeyCode, text: String, flags: CGEventFlags = [])

    /// A string typed as a sequence of key events by the driver, one down and up
    /// pair per character, which is what a hand produces. `.insertText` is the
    /// same string on one event, and the two are not interchangeable.
    case text(String)

    /// A whole string carried on **one** key event, for filling a field.
    ///
    /// This is not a faster `.text` and the driver never substitutes one for the
    /// other: the caller chooses, and the choice is about what the target sees.
    /// `.text` produces one key down and one key up per character, which is what
    /// a hand produces, so anything that reacts per keystroke reacts the way it
    /// would for a person: a completion list narrows character by character, a
    /// field that validates while typing validates each time, a key handler in a
    /// page runs once per character, a framework controlled editor sees the
    /// edits it expects. `.insertText` sends a single key down whose unicode
    /// payload is the entire string, so all of that happens **once**, with the
    /// whole string already in place, and a target that counts keystrokes counts
    /// one. A field that only wants its contents set does not care; a field that
    /// watches the typing does.
    ///
    /// What it buys is the cost, and past a few hundred characters the
    /// difference stops being marginal. Measured on macOS 27.0 into background
    /// windows, timed to the target's own counter and not to a receipt. At 8192
    /// characters: 2 events, 383 ms on a browser renderer and at most 295 ms on
    /// a native text control, against 16384 events, 5,4 s and 92 s for the same
    /// string typed. Per character that is 0,05 and 0,04 ms against 0,66 and
    /// 11,3. At 128 characters the two are within a fraction of a second of each
    /// other either way, so the choice there is about behaviour alone. The
    /// inserted total is flat from 128 characters to 8192 and the typed one is
    /// not, because the typed cost per character grows with how much the
    /// target's editor already holds.
    ///
    /// It is not free everywhere. A renderer of the Chromium family drops a key
    /// event carrying more than one character unless the target's own AppKit
    /// state is prepared first, in every window state measured, and it needs
    /// longer than the usual wait after that preparation before the event lands.
    /// So on that family this Command pays a Preparation and a settle of its own
    /// that `.text` does not, which is most of the 383 ms above. A native AppKit
    /// target needs neither.
    ///
    /// The virtual key is zero and the layout is never consulted, so the string
    /// arrives as written whatever keyboard is installed. There is no key up per
    /// character and therefore no way for the target to see a partial string:
    /// either the one event is delivered or nothing is.
    case insertText(String)

    /// One press and release at the same point, with no `mouseMoved` primer and
    /// no pause between them: measured as sufficient on the fixture and on
    /// Chromium renderers.
    ///
    /// The button defaults to the left one, so a caller that never asked the
    /// question keeps the click it had. A right click is the same two events
    /// with the other type, and it is delivered by the same recipe with one
    /// difference the caller does not choose: no Preparation, because the
    /// restore closes the menu the click just opened.
    case click(InputLocation, button: MouseButton = .left)

    /// A press, the intermediate moves and a release along `points`, paced by
    /// the platform. The path is given whole so the driver can validate the
    /// geometry before it posts the first event.
    case drag(points: [InputLocation], flags: CGEventFlags = [])

    /// One scroll wheel event, in lines, at the given point.
    case scroll(InputLocation, deltaY: Int32)

    /// hasMouseLocation separates Commands whose coordinate transform must be
    /// revalidated from process-keyed keyboard Commands.
    package var hasMouseLocation: Bool {
        switch self {
        case .click, .drag, .scroll:
            true
        case .key, .text, .insertText:
            false
        }
    }
}
