//
//  DisplayList.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// DisplayList is the kit's only answer to "does this display still exist?",
/// and it is a list membership, never `CGDisplayIsOnline`.
///
/// **The reason is a measured defect**, on build 26A5425a.
/// For a `CGDirectDisplayID` that no longer exists, `CGDisplayIsOnline` and
/// `CGDisplayIsActive` return `0xFFFFFFFF`, not `0`. The header documents a
/// `boolean_t`, so both spellings of the usual idiom are wrong on exactly the
/// case they are written for:
///
/// - `CGDisplayIsOnline(id) == 0` is the wait for "the display went away", and
///   it never becomes true, so a teardown written that way always times out
///   and the topology restore behind it is always skipped.
/// - `CGDisplayIsOnline(id) != 0` is the guard for "the display is still
///   there", and it is true for a display that vanished. Three shapes of code
///   were caught by it: a seat guard reading `displayIsOnline: true` at the
///   exact moment the display was gone, and so never raising `displayChanged`;
///   a periodic watchdog asking the same question the other way round and never
///   firing; and a creation path waiting for "active and online" with it,
///   which from the second display in a process on stopped waiting immediately
///   and reported a wait of zero on a display that was not there yet. The kit
///   writes `== 1` where the display exists by construction, which costs
///   nothing and cannot be read the wrong way.
///
/// The list has no such ambiguity: an id is in `CGGetOnlineDisplayList` or it
/// is not, and an enumeration that fails throws instead of answering "gone".
/// Where the display **exists by construction**, immediately after
/// `applySettings:` published it, `CGDisplayIsActive` is still the right call
/// and `VirtualDisplay.isRegistered` uses it: there the question is "is it
/// ready to draw", not "is it still there".
nonisolated public enum DisplayList {

    /// Every display the window server knows about, including one that is
    /// asleep or mirrored.
    public static func online() throws -> [CGDirectDisplayID] {
        try enumerate(CGGetOnlineDisplayList)
    }

    /// Every display available for drawing. Before a virtual display is
    /// created this is the person's own topology, which is what a baseline is.
    public static func active() throws -> [CGDirectDisplayID] {
        try enumerate(CGGetActiveDisplayList)
    }

    /// Whether the window server still lists this display.
    ///
    /// It throws rather than answering `false` when the enumeration fails: a
    /// call that did not answer is not evidence that a display went away, and
    /// treating it as such is how a fail-closed teardown turns into a silent
    /// one.
    public static func isOnline(_ displayID: CGDirectDisplayID) throws -> Bool {
        try online().contains(displayID)
    }

    private static func enumerate(
        _ query: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) throws -> [CGDirectDisplayID] {

        var count: UInt32 = 0
        let countError = query(0, nil, &count)
        guard countError == .success else {
            throw DisplayFailure.displayEnumerationFailed(countError)
        }
        guard count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listError = displayIDs.withUnsafeMutableBufferPointer { buffer in
            query(count, buffer.baseAddress, &count)
        }
        guard listError == .success else {
            throw DisplayFailure.displayEnumerationFailed(listError)
        }
        return Array(displayIDs.prefix(Int(count)))
    }
}
