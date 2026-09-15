//
//  FenceFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// FenceFailure is everything the Cursor Fence itself can refuse to do. It
/// carries fields, never prose: the consumer writes the sentence the person
/// reads, and a report reads the numbers.
///
/// What is deliberately **not** here is the judgement "the fence was violated".
/// The fence reports what it observed (a disabled tap, a point outside the
/// region, a cursor it could not read); deciding that the observation means the
/// seat must fail closed belongs to whoever owns the seat.
nonisolated public enum FenceFailure: Error, Sendable, Equatable {

    /// No display bound survived validation, so the region would confine the
    /// cursor to nowhere. Installing the tap here would be worse than refusing.
    case noPhysicalDisplays

    /// A mutating HID tap needs Accessibility. `Permissions.preflight` said no,
    /// and the kit never prompts on its own.
    case accessibilityPermissionMissing

    /// `CGEvent.tapCreate` returned nothing, or the tap did not come back
    /// enabled after `tapEnable`.
    case eventTapUnavailable

    /// The fence's own thread never published its run loop, so the tap would
    /// have no one to deliver to. Bounded wait, then refuse.
    case fenceThreadUnavailable

    /// The global pointer position is unreadable, so neither the initial
    /// confinement nor an anchor can be established.
    case cursorPositionUnavailable

    /// A second acquisition asked for a different region than the one the
    /// active tap confines to. There is one HID tap in the process: two regions
    /// would mean two answers to the same question, so this is an error rather
    /// than a second tap.
    case regionMismatch(active: [CGRect], requested: [CGRect])

    /// A marker of zero cannot be anchored or audited: the driver writes it in
    /// `eventSourceUserData`, where zero is what an untagged event carries.
    case markerReserved
}
