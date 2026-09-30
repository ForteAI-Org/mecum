import Foundation
import SeatCore

/// Keys the planner may press. Routed to the adopted process, no location.
/// The letters are here for chords (⌘C, ⌘⇧A): plain text goes through `type`.
public enum KeyName: String, Sendable, Hashable, CaseIterable, Codable {
    case `return`, escape, tab, space, delete
    case up, down, left, right
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    /// Typed rather than pressed: an out of process file panel opens Go to Folder on a plain `/`.
    case slash = "/", tilde = "~"
}

/// The modifiers held down for a key press. Empty for a plain key.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// One written modifier: a name, a common abbreviation or the glyph a menu
    /// prints. Nil for anything else, which is how an unknown token is caught.
    public init?(token: String) {
        switch token {
        case "cmd", "command", "⌘": self = .command
        case "shift", "⇧": self = .shift
        case "opt", "option", "alt", "⌥": self = .option
        case "ctrl", "control", "⌃": self = .control
        default: return nil
        }
    }

    /// `cmd+shift`, in the order a menu prints them.
    public var description: String {
        var names: [String] = []
        if contains(.control) { names.append("ctrl") }
        if contains(.option) { names.append("opt") }
        if contains(.shift) { names.append("shift") }
        if contains(.command) { names.append("cmd") }
        return names.joined(separator: "+")
    }
}

/// An action on an element of the latest observation, by 1-based index, or a
/// key press into the adopted window.
public enum SemanticAction: Sendable, Hashable {
    /// One or more complete primary-button clicks, bounded by Mecum's input
    /// command limit.
    case click(element: Int, count: Int = 1)
    case type(element: Int, text: String)
    case scroll(element: Int, deltaY: Int32)
    case key(KeyName, modifiers: KeyModifiers)

    /// Opens the element's own contextual menu with a right click and chooses
    /// the item whose title is `item`.
    ///
    /// It exists because a key equivalent is resolved by the menu of the
    /// **active** application and the whole point of the seat is that the
    /// target is not active: Adr0011 measured Command-C, Command-V,
    /// Command-A, Command-Z and Command-Shift-Z as delivered and acted on by
    /// none, on both target families. A contextual menu belongs to the window
    /// it was opened from, so it is the route that does not go through the
    /// active application's menu bar.
    case menu(element: Int, item: String)



    /// A plain key press, no modifiers.
    public static func key(_ name: KeyName) -> SemanticAction { .key(name, modifiers: []) }

    /// The element the action targets; nil for a key press.
    public var element: Int? {
        switch self {
        case .click(let e, _), .type(let e, _), .scroll(let e, _), .menu(let e, _): e
        case .key: nil
        }
    }

    /// The clicks this action asks for: 1 for everything that is not a click.
    public var clickCount: Int {
        if case .click(_, let count) = self { count } else { 1 }
    }

    public var verb: String {
        switch self {
        case .click: "click"
        case .type: "type"
        case .scroll: "scroll"
        case .key: "key"
        case .menu: "menu"
        }
    }

    /// `[3]` for an element action, `return` or `cmd+c` for a key press, and
    /// `[3] "Copia"` for a menu action, whose item is half of what it names.
    public var targetDescription: String {
        switch self {
        case .key(let name, let modifiers):
            modifiers.isEmpty ? name.rawValue : "\(modifiers)+\(name.rawValue)"
        case .click(let element, let count) where count > 1:
            "[\(element)] x\(count)"
        case .menu(let e, let item): "[\(e)] \"\(item)\""
        default: "[\(element ?? 0)]"
        }
    }

    /// `return`, `cmd+c`, `⌘⇧a` → a key press with its modifiers. Nil when a
    /// token names no modifier or the key itself is unknown.
    public static func key(chord: String) -> SemanticAction? {
        var rest = Substring(chord.lowercased().trimmingCharacters(in: .whitespaces))
        var modifiers: KeyModifiers = []
        // "⌘⇧a" glues its modifiers to the key; "cmd+shift+a" separates them.
        while let glyph = rest.first, let modifier = KeyModifiers(token: String(glyph)) {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        let tokens = rest.split(separator: "+")
        guard let name = tokens.last, let key = KeyName(rawValue: String(name)) else { return nil }
        for token in tokens.dropLast() {
            guard let modifier = KeyModifiers(token: String(token)) else { return nil }
            modifiers.insert(modifier)
        }
        return .key(key, modifiers: modifiers)
    }

    /// Parses the lab's slash commands: `/click 3 [count]`, `/type 2 hello world`,
    /// `/scroll 4 -3`, `/key return`, `/key cmd+c`, `/menu 3 Copia`. Anything
    /// else is nil.
    public static func parse(command: String) -> SemanticAction? {
        let parts = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        if parts[0] == "/key" {
            return parts.count == 2 ? key(chord: String(parts[1])) : nil
        }
        guard let index = Int(parts[1]), index > 0 else { return nil }
        switch parts[0] {
        case "/click":
            if parts.count == 2 { return .click(element: index) }
            guard parts.count == 3,
                  let count = Int(parts[2]),
                  (1...InputCommand.maximumClickCount).contains(count)
            else { return nil }
            return .click(element: index, count: count)
        case "/type":
            guard parts.count == 3, !parts[2].isEmpty else { return nil }
            return .type(element: index, text: String(parts[2]))
        case "/scroll":
            guard parts.count == 3, let delta = Int32(parts[2]) else { return nil }
            return .scroll(element: index, deltaY: delta)
        case "/menu":
            // The rest of the line is the title, spaces and all: "Apri con" is
            // one item and splitting on the space would name neither.
            guard parts.count == 3, !parts[2].isEmpty else { return nil }
            return .menu(element: index, item: String(parts[2]))
        default:
            return nil
        }
    }
}
