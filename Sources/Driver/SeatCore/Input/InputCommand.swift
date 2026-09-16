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

    /// One key press and release, optionally carrying an explicit Unicode
    /// payload. `modifiers` are held for both events.
    ///
    /// A Character Shortcut keeps `text` empty and records a
    /// `CharacterShortcutOrigin` instead. Its virtual key and flags must reach
    /// AppKit without a Unicode override so the application can match its key
    /// equivalent. `.text` and `.insertText` remain the routes that carry text.
    ///
    /// The modifiers are `Modifiers` and not `CGEventFlags` because a caller
    /// means six things and `CGEventFlags` is sixty four bits that also carry
    /// the numeric keypad, the help key and the left and right variants the
    /// window server fills in. What a caller can say here is what a caller can
    /// mean; the flags are built from it one level down.
    case key(
        virtualKey: CGKeyCode,
        text      : String,
        modifiers : Modifiers = [],
        phase     : KeyPhase = .press,
        origin    : CharacterShortcutOrigin? = nil
    )

    /// A string typed as a sequence of key events by the driver, one down and up
    /// pair per **grapheme cluster**, which is what a hand produces.
    /// `.insertText` is the same string on one event, and the two are not
    /// interchangeable.
    ///
    /// The unit is the cluster and not the UTF-16 code unit, because the
    /// cluster is what costs two events: an emoji built from a zero width
    /// joiner sequence is one keystroke here and several code units on the
    /// wire. `textMeasure` says which unit any given Command counted in.
    case text(String)

    /// A whole string carried on **one** key event, for filling a field.
    ///
    /// This is not a faster `.text` and the driver never substitutes one for the
    /// other: the caller chooses, and the choice is about what the target sees.
    /// `.text` produces one key down and one key up per grapheme cluster, which
    /// is what a hand produces, so anything that reacts per keystroke reacts the
    /// way it would for a person: a completion list narrows cluster by cluster, a
    /// field that validates while typing validates each time, a key handler in a
    /// page runs once per cluster, a framework controlled editor sees the edits
    /// it expects. `.insertText` sends a single key down whose unicode payload
    /// is the entire string, **counted in UTF-16 code units**, so all of that
    /// happens once, with the whole string already in place, and a target that
    /// counts keystrokes counts one. A field that only wants its contents set does not care; a field that
    /// watches the typing does.
    ///
    /// What it buys is the cost, and past a few hundred clusters the difference
    /// stops being marginal. Measured on macOS 27.0 into background windows,
    /// timed to the target's own counter and not to a receipt. The samples were
    /// ASCII, where a cluster and a code unit are the same thing; the counts
    /// below are clusters, which is what the typed path pays per event. At 8192
    /// clusters: 2 events, 383 ms on a browser renderer and at most 295 ms on a
    /// native text control, against 16384 events, 5,4 s and 92 s for the same
    /// string typed. Per cluster that is 0,05 and 0,04 ms against 0,66 and 11,3.
    /// At 128 clusters the two are within a fraction of a second of each other
    /// either way, so the choice there is about behaviour alone. The inserted
    /// total is flat from 128 clusters to 8192 and the typed one is not, because
    /// the typed cost per cluster grows with how much the target's editor
    /// already holds.
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
    /// cluster and therefore no way for the target to see a partial string:
    /// either the one event is delivered or nothing is.
    ///
    /// Walking past the layout means walking past the input method too, and a
    /// target that is **already composing** drops it: measured on 26A428
    /// against a native text view holding a marked range, the string never
    /// arrived and the composition was left exactly as it was, while the same
    /// Command to the same window with nothing composing arrived. So an
    /// insertion neither commits nor replaces marked text, it is the
    /// delivered-and-ignored case, and there is no error anywhere to say so:
    /// only the target's own state tells the caller which of the two happened.
    /// The measurement is about what a composing client does, not about what
    /// any particular input method would do with the event first.
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
    case drag(points: [InputLocation], modifiers: Modifiers = [])

    /// One scroll wheel event, in lines, at the given point.
    case scroll(InputLocation, deltaY: Int32)

    /// hasMouseLocation separates Commands whose coordinate transform must be
    /// revalidated from process-keyed keyboard Commands.
    /// How much text this Command carries, in the unit that Command counts in.
    ///
    /// Nil for a Command that carries none. The unit is not a formatting
    /// choice: `.text` is measured in grapheme clusters because that is what it
    /// costs, one down and one up each, and everything that travels on an event
    /// is measured in UTF-16 code units because that is what
    /// `keyboardSetUnicodeString` takes and what its limit is expressed in.
    public var textMeasure: TextMeasure? {
        switch self {
            case .text(let text):
                TextMeasure(text.count, .graphemeClusters)
            case .insertText(let text):
                TextMeasure(text.utf16.count, .utf16CodeUnits)
            case .key(_, let text, _, _, _):
                text.isEmpty ? nil : TextMeasure(text.utf16.count, .utf16CodeUnits)
            case .click, .drag, .scroll:
                nil
        }
    }

    package var hasMouseLocation: Bool {
        switch self {
            case .click, .drag, .scroll  : true
            case .key, .text, .insertText: false
        }
    }
}
