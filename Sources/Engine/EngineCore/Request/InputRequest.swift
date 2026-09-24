//
//  InputRequest.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// InputRequest is one input a model asks the engine to deliver beyond a click: text into a field, a
/// key into the window, a scroll, a drag, or an item of a target's contextual menu. Every target it
/// names is resolved live against this instant's scene, like an `ActionRequest`'s, and the effect is
/// judged by perceiving again.
public struct InputRequest: Sendable, Equatable {

    /// What the request delivers. Each target is an element id or a label.
    public enum Input: Sendable, Equatable {
        /// Clicks the field `into` to focus it and types `text`: over everything it holds when
        /// `replacing`, else after it.
        case typeText(String, into: String, replacing: Bool)
        /// Presses a key `times` times into the window, the chord's modifiers held around each press.
        case pressKey(KeyChord, times: Int)
        /// Turns the wheel by `lines`, positive up, over a target, or over the window's centre when nil.
        case scroll(lines: Int, over: String?)
        /// Drags from one target to another target, or by an offset in points.
        case drag(from: String, to: DragEnd)
        /// Right-clicks a target and chooses the item titled `item` in the contextual menu it opens.
        case contextMenu(on: String, item: String)
    }

    /// Where a drag ends: on another target, or at an offset in points from where it starts.
    public enum DragEnd: Sendable, Equatable {
        case target(String)
        case offset(dx: Double, dy: Double)
    }

    /// The most presses one key request repeats, so a single request never holds the window for long.
    public static let maximumKeyPresses = 20

    /// The most wheel lines one scroll turns.
    public static let maximumScrollLines = 50

    public var processID: pid_t
    public var bundleID: String
    public var appName: String
    public var input: Input
    /// A panel name that disambiguates a shared label, for every target the input names.
    public var section: String?
    /// A rehearsal: resolve and report what would happen, perform nothing.
    public var isDryRun: Bool

    public init(
        processID: pid_t,
        bundleID : String,
        appName  : String,
        input    : Input,
        section  : String? = nil,
        isDryRun : Bool = false
    ) {
        self.processID = processID
        self.bundleID  = bundleID
        self.appName   = appName
        self.input     = input
        self.section   = section
        self.isDryRun  = isDryRun
    }
}

/// KeyChord is one key the engine presses by name and the modifiers held around it. A named key is a
/// position, the same on every layout; a letter or a digit is a meaning, pressed wherever the
/// installed layout puts it.
public struct KeyChord: Sendable, Equatable, CustomStringConvertible {

    /// The keys a chord can name: the ones that navigate and submit, and the letters and digits a
    /// shortcut is written with.
    public enum Name: Sendable, Equatable {
        case `return`, tab, escape, space, delete
        case left, right, up, down
        /// A letter a to z or a digit 0 to 9, lowercase.
        case character(Character)

        /// The key a tool names: `return`, `left`, `a`, `7`. Nil for anything else.
        public init?(_ name: String) {
            switch name.lowercased() {
                case "return": self = .return
                case "tab"   : self = .tab
                case "escape": self = .escape
                case "space" : self = .space
                case "delete": self = .delete
                case "left"  : self = .left
                case "right" : self = .right
                case "up"    : self = .up
                case "down"  : self = .down
                case let word:
                    guard word.count == 1, let character = word.first,
                          ("a"..."z").contains(character) || ("0"..."9").contains(character)
                    else { return nil }
                    self = .character(character)
            }
        }

        /// Every name a tool may use, in the order a person reads them.
        public static var all: [String] {
            ["return", "tab", "escape", "space", "delete", "left", "right", "up", "down"]
                + "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
        }

        /// The name a tool writes and a sentence reads.
        public var word: String {
            switch self {
                case .return              : "return"
                case .tab                 : "tab"
                case .escape              : "escape"
                case .space               : "space"
                case .delete              : "delete"
                case .left                : "left"
                case .right               : "right"
                case .up                  : "up"
                case .down                : "down"
                case .character(let value): String(value)
            }
        }
    }

    public let key: Name
    public let modifiers: KeyModifiers

    public init(_ key: Name, modifiers: KeyModifiers = []) {
        self.key       = key
        self.modifiers = modifiers
    }

    /// `cmd+shift+n`, the modifiers in the order a menu prints them.
    public var description: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("ctrl") }
        if modifiers.contains(.option)  { words.append("opt") }
        if modifiers.contains(.shift)   { words.append("shift") }
        if modifiers.contains(.command) { words.append("cmd") }
        return (words + [key.word]).joined(separator: "+")
    }

    /// The gesture that presses this chord once.
    public var gesture: Gesture {
        switch key {
            case .return              : .key(code: Key.return, modifiers: modifiers)
            case .tab                 : .key(code: Key.tab, modifiers: modifiers)
            case .escape              : .key(code: Key.escape, modifiers: modifiers)
            case .space               : .key(code: Key.space, modifiers: modifiers)
            case .delete              : .key(code: Key.delete, modifiers: modifiers)
            case .left                : .key(code: Key.leftArrow, modifiers: modifiers)
            case .right               : .key(code: Key.rightArrow, modifiers: modifiers)
            case .up                  : .key(code: Key.upArrow, modifiers: modifiers)
            case .down                : .key(code: Key.downArrow, modifiers: modifiers)
            case .character(let value): .character(value, modifiers: modifiers)
        }
    }
}
