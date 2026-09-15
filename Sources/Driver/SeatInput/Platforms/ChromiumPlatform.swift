//
//  ChromiumPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore

/// ChromiumPlatform prepares the mouse and the bulk insertion, and nothing else.
///
/// A Chromium renderer drops a click that arrives at a window its browser
/// process does not consider key, whatever route carries it: every unprepared
/// click failed on Chrome and every prepared one passed, including the plain
/// down and up with no primer and no field stamping. The same holds for a drag.
///
/// A key event carrying **more than one character** is dropped the same way, and
/// that is the whole reason `.insertText` is prepared while `.key` and `.text`
/// are not. Measured on macOS 27.0 against a browser the measurement launches,
/// in four window states, with the string on the event and nothing else changed:
/// unprepared, one character arrives and two do not, at every length tried up to
/// 8192 and in every state, and the refusal is silent: the page's key handler
/// and the focused field's both count the key down and the field stays empty.
/// Prepared, the whole string arrives on one edit, 383 ms for 8192 characters
/// including the settle below. The window state moves nothing here, which is
/// what makes this expressible as a policy per Command at all: the discriminator
/// is the shape of the event, not where the window sits.
///
/// A single character key press and a typed string, which is one such press per
/// character, pass without any of it, so neither is prepared: a Preparation
/// costs two records, the settle, and a window that briefly believes it is key,
/// and none of that buys anything for one character. Scroll passes too.
///
/// It covers Electron and CEF, which are the same renderer with a different
/// shell around it.
nonisolated public struct ChromiumPlatform: InputPlatform {

    public init() {}

    /// The left button, a drag and the bulk insertion are prepared; the right
    /// button, a key press, a typed string and a scroll are not.
    ///
    /// **The right button is the one place in the kit where the Preparation is
    /// harmful rather than merely pointless**, and it is the restore that does
    /// the harm. A right click opens a contextual menu, a menu runs a modal
    /// tracking loop inside the target, and that loop watches for the target's
    /// application being deactivated so it can dismiss the menu the way a real
    /// application switch would. The restore posts exactly that record. Measured
    /// on 26A5425a against an instrumented target in the background: prepared
    /// and restored, the menu lives 413 to 453 ms and is gone; unprepared, the
    /// same menu from the same click is still open at 1,9 s. Unprepared is also
    /// enough on this family for the menu to open at all, on a physical display
    /// and on the Virtual Display, which is what makes refusing the Preparation
    /// here a policy and not a trade-off.
    ///
    /// The same property is the lever the teardown uses: applying and restoring
    /// a Preparation closes an open menu in 50 ms, which is why
    /// `AgentSeat.useContextMenu` closes with the cycle it must not use to open.
    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .click(_, .right)          : .none
            case .click, .drag, .insertText : .internalAppKitState
            case .key, .text, .scroll       : .none
        }
    }

    /// The mouse takes the default wait; the bulk insertion needs five times it,
    /// and that difference is why the wait is asked per Command at all.
    ///
    /// Preparing the window is not enough on its own here: the renderer has to
    /// have caught up with it before the event lands, and until it has, the key
    /// down arrives, the focused field sees it, and nothing is inserted, which
    /// is a failure with no error anywhere. Measured at 16 characters with the
    /// window on a virtual display, which is where a seat posts, counting the
    /// target's own insertions: 30 ms lands about seven times in ten, 60 ms
    /// eleven times in twelve, 100 ms and 150 ms twelve out of twelve each. The
    /// value below is the smallest clean one plus half again, and it costs
    /// nothing anywhere else because no other Command asks for it.
    ///
    /// One failure no wait removes: on a physical display, a window the person's
    /// Stage Manager has stashed to a thumbnail refuses the same Command at
    /// every wait tried. A seat stages a window before posting to it, so it does
    /// not meet that; a caller posting at an unstaged window can.
    public func preparationSettle(for command: InputCommand) -> Duration {
        guard case .insertText = command else { return .milliseconds(30) }
        return .milliseconds(150)
    }
}
