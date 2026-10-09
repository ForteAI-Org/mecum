//
//  PrivateSymbol.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// PrivateSymbol is one C symbol the kit resolves at runtime, named by its
/// **exact spelling**. The spelling is the identity, not the concept: on
/// 26A5425a both `SLPSSetFrontProcessWithOptions` and
/// `_SLPSSetFrontProcessWithOptions` exist and are different exports, and
/// `CGEventSetWindowLocation` lives in CoreGraphics while its SkyLight twin
/// `SLEventSetWindowLocation` does not. A Ledger row that says "the front
/// process symbol" says nothing.
nonisolated public enum PrivateSymbol: String, Sendable, CaseIterable {

    /// The caller's WindowServer connection. Root of the identity chain.
    case mainConnectionID       = "SLSMainConnectionID"

    /// The connection that owns a Window ID: identity re-read before posting.
    case getWindowOwner         = "SLSGetWindowOwner"

    /// The process serial number behind an owning connection, needed by the
    /// two Preparation records.
    case getConnectionPSN       = "SLSGetConnectionPSN"

    /// The window server's rectangle for one Window ID. Read only for a window
    /// the public window list does not enumerate; a listed window keeps the
    /// public reading and its cross check.
    case getWindowBounds        = "SLSGetWindowBounds"

    /// Restores the user's front process and window. Used only by the opt-in
    /// focus recovery facility, never by background input preparation.
    case setFrontProcess       = "_SLPSSetFrontProcessWithOptions"

    /// Read-only front-process PSN. The underscore export has the measured ABI.
    case getFrontProcess       = "_SLPSGetFrontProcess"

    /// The event's private record. The kit uses it for the declared-length
    /// check and the offset round trip only; the routed fields are written
    /// through public setters.
    case eventRecordPointer     = "SLEventRecordPointer"

    /// Posts a Preparation record to one process serial number.
    case postEventRecordTo      = "SLPSPostEventRecordTo"

    /// Writes the window-local point (record 0x20 / 0x28) without a pointer
    /// store. Exported by CoreGraphics, not by SkyLight.
    case setWindowLocation      = "CGEventSetWindowLocation"

    /// Writes an integer field of the record. The kit does not need it (the
    /// public `setIntegerValueField` writes the same bytes), and resolves it
    /// only so the round trip can be cross-checked from both sides.
    case setIntegerValueField   = "SLEventSetIntegerValueField"

    /// The Objective-C send, needed because the `CGVirtualDisplay*` classes
    /// have no header.
    case messageSend            = "objc_msgSend"

    /// Maps an accessibility window element to its Window ID.
    case axUIElementGetWindow   = "_AXUIElementGetWindow"

    /// Read-only. The desktop (Space) ids a Window ID is on. Used to verify
    /// that a returned window is on the desktop it was taken from; the kit
    /// never writes a desktop.
    case copySpacesForWindows   = "SLSCopySpacesForWindows"

    /// Read-only. Every display's desktops and the one each shows now.
    case copyManagedDisplaySpaces = "SLSCopyManagedDisplaySpaces"

    /// The image to `dlopen` when the symbol is not in the process yet.
    ///
    /// `dlopen(nil)` searches the images that are **already loaded**, so what
    /// resolves depends on what the consumer happened to link: in a binary that
    /// does not touch accessibility, `_AXUIElementGetWindow` is missing, and a
    /// Facility would report `unavailable` on a machine where it works. Loading
    /// the image the primitive lives in makes the lookup depend on the system
    /// instead of on the consumer's link order. It can only turn "missing" into
    /// "found": the resolved image is still whatever `dladdr` reports.
    public var image: String {
        switch self {
        case .messageSend:
            "/usr/lib/objc/libobjcMsgSend.dylib"
        case .axUIElementGetWindow:
            "/System/Library/Frameworks/ApplicationServices.framework"
                + "/Frameworks/HIServices.framework/HIServices"
        default:
            // Every other primitive is defined in SkyLight, including the
            // `CG`-spelled `CGEventSetWindowLocation`, which CoreGraphics only
            // re-exports.
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        }
    }
}

/// PrivateClass is an Objective-C class with no public header, reached by name.
/// A class that resolves proves nothing about its selectors, so the two are
/// separate primitives in the Ledger.
nonisolated public enum PrivateClass: String, Sendable, CaseIterable {
    case virtualDisplay           = "CGVirtualDisplay"
    case virtualDisplayDescriptor = "CGVirtualDisplayDescriptor"
    case virtualDisplayMode       = "CGVirtualDisplayMode"
    case virtualDisplaySettings   = "CGVirtualDisplaySettings"
}
