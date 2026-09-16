//
//  KeyRepeatPacing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// KeyRepeatPacing is the timing of a held key, as data, for the same reason
/// `DragPacing` is: the gap between repeats is not decoration, it is what makes
/// a repeat a repeat. A target that accelerates a cursor or a scroll while a key
/// is held reads the interval, and downs posted back to back are not a held key,
/// they are a burst.
public struct KeyRepeatPacing: Sendable, Equatable {

    /// The pause between one repeat and the next.
    ///
    /// There is deliberately no second number for the delay before the *first*
    /// repeat. A held key on a real keyboard waits before it starts repeating
    /// because the person is still deciding; a synthetic repeat has already
    /// decided, and the target reads the interval between repeats, not the
    /// distance from the original press. A caller that wants a pause before the
    /// repeats begin gets it by sending the `.down` and the `.repeated` when it
    /// chooses, which is the same control without a number nobody consults.
    public let intervalMicroseconds: UInt32

    public init(intervalMicroseconds: UInt32) {
        self.intervalMicroseconds = intervalMicroseconds
    }

    /// macOS's own shipping default of 33 ms between repeats.
    ///
    /// It is the **default**, not the person's setting: this module has no
    /// AppKit, deliberately. A seat that wants what the person actually
    /// configured builds one from `NSEvent.keyRepeatInterval` and hands it to
    /// the platform.
    public static let systemDefault = KeyRepeatPacing(intervalMicroseconds: 33_000)
}
