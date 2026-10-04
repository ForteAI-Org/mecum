//
//  InputFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore

/// PreparationStep remains visible through SeatInput for source compatibility.
/// Its value lives in SeatCore so Receipt and progress types share one enum.
public typealias PreparationStep = SeatCore.PreparationStep

/// InputFailure is everything the Input Facility refuses to do. It carries
/// fields and codes, never prose: the consumer writes the sentence, a test
/// asserts on the case, and the compatibility report prints the numbers.
///
/// A Command-specific case refuses before that Command's first event. A
/// `restoreFailed` value describes cleanup only: its surrounding Receipt or
/// progress record says whether a Command was posted and prevents replay from
/// being inferred from the error alone.
nonisolated public enum InputFailure: Error, Sendable, Equatable {

    // MARK: The Facility

    /// A private primitive the Facility needs did not resolve on this build.
    /// The payload is the Ledger key, so it matches what `FacilityGate` reports
    /// as `unavailable(reason:)`.
    case primitiveUnavailable(String)

    /// The gate refused a missing grant, failed self check or unreadable Ledger.
    /// Readiness carries the cause. Missing build qualification alone does not
    /// refuse (Spec section 6 and ADR 0015).
    case facilityUnavailable(FacilityReadiness)

    /// `SLSMainConnectionID` answered zero: this process has no window server
    /// connection, so nothing can be routed.
    case mainConnectionUnavailable

    /// `CGEventSource(.privateState)` refused. Without a private source the
    /// events would carry the person's own state, so there is no fallback.
    case eventSourceUnavailable

    /// Input was not admitted before this command was posted. The reasons are
    /// the ones the refusing reading held, sorted, and never empty: a pause with
    /// nothing named is a pause nobody can act on.
    case inputPaused([InputPauseReason])

    // MARK: The target

    /// The process that owns the target window is gone.
    case processUnavailable(processID: Int32)

    /// The Window ID is zero or does not fit the window server's `UInt32`.
    case invalidWindowNumber(Int)

    /// `SLSGetWindowOwner` did not confirm an owning connection for the window,
    /// which is the identity re-read that stands in for a window list scan.
    case windowOwnerUnavailable(windowNumber: Int, code: Int32)

    /// The caller supplied only a PID and Window ID. Both can be reused after
    /// their former owners terminate, so the driver cannot prove this is the
    /// window the caller observed and refuses before changing target state.
    case windowIdentityUnverified(processID: Int32, windowNumber: Int)

    /// A fresh WindowServer ownership chain no longer equals the one attached
    /// to the reference. `observed` is nil when any link could not be proved.
    case windowIdentityChanged(expected: WindowIdentity, observed: WindowIdentity?)

    // MARK: The Command

    /// A sequence with no Command in it.
    case noCommands

    /// A Shortcut named a character the installed keyboard layout cannot
    /// name on its base, Command or required Shift symbol plane. Refused rather
    /// than resolved to virtual key zero with the character attached: that is
    /// the `.text` path and it means something else, and a menu key equivalent
    /// matched on virtual key zero matches nothing.
    case keyUnresolvable(character: String, inputSourceID: String)

    /// A character Shortcut's Command plane, or required Shift symbol row,
    /// changed before the driver built its events.
    case shortcutContextChanged(resolved: Modifiers, current: Modifiers)

    /// A `repeated` phase asked for no repeats at all, or for more than one
    /// atomic Command may hold the target's exclusion for. Both are the same
    /// refusal because both describe a count that cannot be posted, and the
    /// numbers say which it was.
    case invalidRepeatCount(requested: Int, maximum: Int)

    /// The click train is empty or exceeds the bounded atomic command.
    case invalidClickCount(requested: Int, maximum: Int)

    /// The platform asked for `.flagsChanged` on a build where the modifier
    /// transition record has not been verified.
    ///
    /// There is no implicit fall back to `.eventFlags`. A silent downgrade
    /// would post a Command that looks like it worked and would make a matrix
    /// row pass for the wrong reason, which is the one thing the matrix exists
    /// to prevent.
    case modifierPolicyUnavailable(ModifierPolicy)

    /// One grapheme cluster is longer, in UTF-16 code units, than a single
    /// delivery may carry. It is refused and never split: half of a joined
    /// emoji is not a smaller emoji, it is different text.
    case textClusterTooLarge(codeUnits: Int, maximum: Int)

    /// A chunk bound that cannot describe any chunk. Both numbers are carried
    /// so the refusal says which one was wrong.
    case invalidTextLimit(clusters: Int, codeUnits: Int)

    /// One Command asked to carry more text than anybody has measured being
    /// delivered. Refused rather than attempted: the kit does not post what
    /// nobody measured, and a partial insertion has no failure mode a caller
    /// could detect. The unit is the one that Command counts in.
    case textTooLong(TextMeasure, maximum: Int)

    /// A `text` Command with nothing to type.
    case emptyText

    /// A coordinate that is not finite. A NaN posted to another process is a
    /// click at an unknown place.
    case invalidLocation

    /// A mouse coordinate was built through the legacy initializer and has no
    /// attested geometry reading. Current geometry cannot be attached at send
    /// time to certify an older point.
    case coordinateObservationMissing

    /// The driver could not obtain a fresh identity, frame and single-display
    /// scale for the target immediately before constructing the Command.
    case currentCoordinateGeometryUnavailable

    /// One of the geometry values required by the transform is malformed.
    case invalidCoordinateGeometry

    /// The coordinate was observed on a different window lifetime than the
    /// current target. Either value may be nil only for unverified legacy data.
    case coordinateIdentityChanged(expected: WindowIdentity?, observed: WindowIdentity?)

    /// The target changed size. Only a pure translation preserves every local
    /// point without a fresh observation of the window's layout.
    case coordinateGeometryChanged(observed: CGRect, current: CGRect)

    /// The target moved to output with a different point-to-pixel scale.
    case coordinateScaleChanged(observed: CGFloat, current: CGFloat)

    /// The local point lies outside the window frame that produced it.
    case coordinateOutsideObservedWindow(point: CGPoint, frame: CGRect)

    /// The supplied screen point and window-local point do not describe the
    /// same location under the geometry that was bound at observation time.
    case coordinateSpacesDisagree

    /// A drag needs a start, at least one intermediate point and an end.
    case invalidDragPath(pointCount: Int)

    /// CoreGraphics did not create one of the events.
    case eventCreationFailed

    // MARK: The record

    /// `SLEventRecordPointer` returned nothing for an event the kit created.
    case eventRecordUnavailable

    /// The record's declared length at 0x04 is not 0xF8. Nothing is written and
    /// nothing is posted.
    case unsupportedEventRecord(declared: UInt32, expected: UInt32)

    /// A bounded read or write of the record was refused. The audited exception
    /// to "no unsafe unwraps" is this path, and this is the bound.
    case recordOffsetOutOfBounds(offset: Int, width: Int, length: Int)

    // MARK: The Preparation

    /// `SLPSPostEventRecordTo` refused one of the Preparation records. No
    /// Command event is sent. The failed record's effect is uncertain, so
    /// `InputPreparationFailure` also reports the bounded cleanup attempt.
    case preparationFailed(step: PreparationStep, code: Int32)

    /// The restore record was refused after the Preparation was applied. The
    /// surrounding Receipt or progress record carries delivery and recovery.
    case restoreFailed(code: Int32)
}
