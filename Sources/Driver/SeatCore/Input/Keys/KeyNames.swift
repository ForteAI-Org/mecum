//
//  KeyNames.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics

/// KeyNames is the kit's table from a macOS virtual key to a physical key name,
/// and back. It describes the **hardware**, so it does not change when the
/// person changes layout: that is `KeyboardLayout`'s job, and keeping the two
/// apart is the whole point of having both.
///
/// The names are the W3C UI Events `code` values, borrowed rather than invented.
/// Two of them are worth reading twice, because the obvious guess is wrong on
/// macOS: virtual key 51 is the key above Return, which macOS calls Delete and
/// this table calls `Backspace`, and virtual key 117 is forward delete, which
/// this table calls `Delete`. Swapping them types into the wrong end of a word.
///
/// ## The version
///
/// `version` is bumped by hand whenever an entry is added, removed or renamed.
/// It exists because a consumer may store `"ArrowRight"` in a configuration or
/// a recorded session and read it back after updating the kit;
/// `KeyboardLayout` carries the version it was built against so that a stale
/// pairing announces itself instead of resolving quietly to something else.
public enum KeyNames {

    /// The table's revision. Bump on any change to `entries`.
    public static let version = 1

    /// Every key this table names, as (virtual key, W3C name).
    ///
    /// ISO and JIS positions are included: 10 is the extra key an ISO keyboard
    /// has beside the left shift, and 93 to 104 are the JIS keys. A layout that
    /// has no such key simply never produces that virtual key.
    public static let entries: [(virtualKey: CGKeyCode, name: String)] = [
        // Letters, in virtual key order rather than alphabetical, because the
        // numbers are what a reader checks against a keycode table.
        (0,  "KeyA"), (1,  "KeyS"), (2,   "KeyD"), (3,   "KeyF"), (4,   "KeyH"),
        (5,  "KeyG"), (6,  "KeyZ"), (7,   "KeyX"), (8,   "KeyC"), (9,   "KeyV"),
        (11, "KeyB"), (12, "KeyQ"), (13,  "KeyW"), (14,  "KeyE"), (15,  "KeyR"),
        (16, "KeyY"), (17, "KeyT"), (31,  "KeyO"), (32,  "KeyU"), (34,  "KeyI"),
        (35, "KeyP"), (37, "KeyL"), (38,  "KeyJ"), (40,  "KeyK"), (45,  "KeyN"),
        (46, "KeyM"),

        // Digits. 22 and 26 are not in numeric order on purpose: 6 is at 22.
        (18, "Digit1"), (19, "Digit2"), (20, "Digit3"), (21, "Digit4"),
        (23, "Digit5"), (22, "Digit6"), (26, "Digit7"), (28, "Digit8"),
        (25, "Digit9"), (29, "Digit0"),

        // Punctuation of the main block.
        (24, "Equal"),        (27, "Minus"),     (30, "BracketRight"),
        (33, "BracketLeft"),  (39, "Quote"),     (41, "Semicolon"),
        (42, "Backslash"),    (43, "Comma"),     (44, "Slash"),
        (47, "Period"),       (50, "Backquote"),

        // The numeric keypad. 71 is Clear on an Apple keyboard and NumLock in
        // the W3C table: same position, two names, and the W3C one is kept for
        // consistency with the rest.
        (65, "NumpadDecimal"),  (67, "NumpadMultiply"), (69, "NumpadAdd"),
        (71, "NumLock"),        (75, "NumpadDivide"),   (76, "NumpadEnter"),
        (78, "NumpadSubtract"), (81, "NumpadEqual"),
        (82, "Numpad0"), (83, "Numpad1"), (84, "Numpad2"), (85, "Numpad3"),
        (86, "Numpad4"), (87, "Numpad5"), (88, "Numpad6"), (89, "Numpad7"),
        (91, "Numpad8"), (92, "Numpad9"),

        // Editing and control.
        (36,  "Enter"),     (48,  "Tab"),      (49,  "Space"),
        (51,  "Backspace"), (53,  "Escape"),   (114, "Help"),
        (115, "Home"),      (116, "PageUp"),   (117, "Delete"),
        (119, "End"),       (121, "PageDown"),

        // The modifiers, both sides. The left hand ones are what a synthetic
        // transition posts, because a built event has no side it came from.
        (54, "MetaRight"),    (55, "MetaLeft"),     (56, "ShiftLeft"),
        (57, "CapsLock"),     (58, "AltLeft"),      (59, "ControlLeft"),
        (60, "ShiftRight"),   (61, "AltRight"),     (62, "ControlRight"),
        (63, "Fn"),

        // Arrows.
        (123, "ArrowLeft"), (124, "ArrowRight"), (125, "ArrowDown"), (126, "ArrowUp"),

        // Function row and the extended function keys.
        (122, "F1"),  (120, "F2"),  (99,  "F3"),  (118, "F4"),  (96,  "F5"),
        (97,  "F6"),  (98,  "F7"),  (100, "F8"),  (101, "F9"),  (109, "F10"),
        (103, "F11"), (111, "F12"), (105, "F13"), (107, "F14"), (113, "F15"),
        (106, "F16"), (64,  "F17"), (79,  "F18"), (80,  "F19"), (90,  "F20"),

        // Volume keys, which arrive as ordinary virtual keys.
        (72, "AudioVolumeUp"), (73, "AudioVolumeDown"), (74, "AudioVolumeMute"),

        // ISO, then JIS.
        (10,  "IntlBackslash"),
        (93,  "IntlYen"), (94, "IntlRo"), (95, "NumpadComma"),
        (102, "Lang1"),   (104, "Lang2"),
    ]

    /// Every key as a `PhysicalKey`, built once.
    public static let all: [PhysicalKey] = entries.map {
        PhysicalKey(name: $0.name, virtualKey: $0.virtualKey)
    }

    private static let byVirtualKey: [CGKeyCode: PhysicalKey] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.virtualKey, $0) }
    )

    private static let byName: [String: PhysicalKey] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    /// The position this virtual key occupies, or nil for a key this table does
    /// not name. Nil is an answer and not a failure: the system can deliver a
    /// virtual key from hardware nobody here has seen.
    public static func key(forVirtualKey virtualKey: CGKeyCode) -> PhysicalKey? {
        byVirtualKey[virtualKey]
    }

    /// The position with this name, or nil. The lookup is exact and case
    /// sensitive, because a name that almost matches is a typo and resolving it
    /// anyway would type into the wrong place.
    public static func key(named name: String) -> PhysicalKey? {
        byName[name]
    }
}
