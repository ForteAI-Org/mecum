//
//  Modifiers.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics

/// Modifiers is the kit's own vocabulary of held modifier keys, and it is
/// deliberately smaller than `CGEventFlags`.
///
/// `CGEventFlags` is 64 bits that mix the six modifiers a caller means with
/// things a caller never means: the numeric keypad bit, the help bit, and the
/// device dependent left and right variants the window server fills in. A
/// declarative shortcut is a promise about what the person would have held, so
/// the type that expresses it admits nothing else, fits in a byte, hashes, and
/// prints the same way twice.
///
/// It is the type on `InputCommand`. `CGEventFlags` survives one level below,
/// as the thing an event is stamped with, and `cgFlags` is the only place the
/// two vocabularies meet.
public struct Modifiers: OptionSet, Sendable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command  = Modifiers(rawValue: 1 << 0)
    public static let shift    = Modifiers(rawValue: 1 << 1)
    public static let option   = Modifiers(rawValue: 1 << 2)
    public static let control  = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)
    public static let capsLock = Modifiers(rawValue: 1 << 5)

    /// The number of bits this set defines, which is what the order below walks.
    private static let bitCount = 6

    /// The individual modifiers of this set, in ascending bit order.
    ///
    /// This is the **declared press order**, and the release order is its exact
    /// reverse. The target does not care which modifier goes down first; a test
    /// that asserts a sequence does, and "the inverse order" means nothing
    /// without a forward order to invert. It is derived from the bits rather
    /// than written out, so adding a modifier cannot leave a hand-kept list
    /// behind.
    public var inPressOrder: [Modifiers] {
        (0 ..< Self.bitCount).compactMap { bit in
            let single = Modifiers(rawValue: 1 << bit)
            return contains(single) ? single : nil
        }
    }

    /// The CoreGraphics flags these modifiers stamp on an event.
    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command)  { flags.insert(.maskCommand)     }
        if contains(.shift)    { flags.insert(.maskShift)       }
        if contains(.option)   { flags.insert(.maskAlternate)   }
        if contains(.control)  { flags.insert(.maskControl)     }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift)  }
        return flags
    }

    /// The modifiers carried by CoreGraphics flags, ignoring every bit this
    /// vocabulary does not name. It reads an event back, which is what a test
    /// asserting a built event needs, and it is lossy on purpose.
    public init(_ flags: CGEventFlags) {
        var modifiers: Modifiers = []
        if flags.contains(.maskCommand)     { modifiers.insert(.command)  }
        if flags.contains(.maskShift)       { modifiers.insert(.shift)    }
        if flags.contains(.maskAlternate)   { modifiers.insert(.option)   }
        if flags.contains(.maskControl)     { modifiers.insert(.control)  }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        if flags.contains(.maskAlphaShift)  { modifiers.insert(.capsLock) }
        self = modifiers
    }

    /// The modifier this virtual key is, or nil for a key that is not one.
    ///
    /// It is the inverse of `singleVirtualKey` and it answers for both sides of
    /// the keyboard, because a held right shift is a held shift: the side
    /// matters to the keycode on a transition event and to nothing else.
    public init?(virtualKey: CGKeyCode) {
        switch virtualKey {
            case 54, 55: self = .command
            case 56, 60: self = .shift
            case 57     : self = .capsLock
            case 58, 61: self = .option
            case 59, 62: self = .control
            case 63     : self = .function
            default     : return nil
        }
    }

    /// The virtual key of a single modifier, which is what a `flagsChanged`
    /// event has to carry as its keycode. It answers nil for a set that is not
    /// exactly one modifier, because a transition event describes one key.
    ///
    /// The left hand variants are the ones posted: a synthetic transition has no
    /// side of the keyboard it came from, and choosing the left one keeps the
    /// value stable instead of arbitrary.
    public var singleVirtualKey: CGKeyCode? {
        switch self {
            case .command : 55
            case .shift   : 56
            case .capsLock: 57
            case .option  : 58
            case .control : 59
            case .function: 63
            default       : nil
        }
    }
}
