//
//  SymbolABI.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics

/// SymbolABI is the argument list of every private symbol the kit calls,
/// written once. A `dlsym` result is an untyped address, so the ABI is the
/// caller's assertion and a wrong one is undefined behaviour: keeping the
/// assertion in a single place is what makes it reviewable, and the Ledger's
/// `checks` are the evidence behind each line.
///
/// Every shape below was exercised on 26A5425a.
nonisolated public enum SymbolABI {

    /// `SLSMainConnectionID()`.
    public typealias MainConnectionID = @convention(c) () -> Int32

    /// `_SLPSSetFrontProcessWithOptions(&psn, windowID, mode)`. Cross-process
    /// mode 0x200 measured on 26A5425a; distinct from the non-underscore export.
    public typealias SetFrontProcess = @convention(c) (
        UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Int32

    /// `_SLPSGetFrontProcess(&psn)`, 0 on success. Read-only sampler and
    /// arm64 disassembly verified on 26A5425a; not the non-underscore export.
    public typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// `SLSGetWindowOwner(connection, windowID, &owner)`, 0 on success.
    public typealias GetWindowOwner = @convention(c) (
        Int32,
        UInt32,
        UnsafeMutablePointer<Int32>?
    ) -> Int32

    /// `SLSGetConnectionPSN(connection, &psn)`, 0 on success. The PSN is two
    /// `UInt32`s, passed raw because the public struct is deprecated.
    public typealias GetConnectionPSN = @convention(c) (
        Int32,
        UnsafeMutableRawPointer?
    ) -> Int32

    /// `SLSGetWindowBounds(connection, windowID, &frame)`, 0 on success. It is
    /// the window server's own rectangle for one Window ID, scoped to that id
    /// and answered for a window the public `CGWindowList` calls do not
    /// enumerate, which is what an out of process panel's content window is.
    public typealias GetWindowBounds = @convention(c) (
        Int32,
        UInt32,
        UnsafeMutablePointer<CGRect>?
    ) -> Int32

    /// `SLEventRecordPointer(event)`, the private record behind a `CGEvent`.
    public typealias EventRecordPointer = @convention(c) (
        UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?

    /// `SLPSPostEventRecordTo(&psn, record)`, 0 on success.
    public typealias PostEventRecordTo = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt8>?
    ) -> Int32

    /// `CGEventSetWindowLocation(event, x, y)`. On arm64 a `CGPoint` is two
    /// consecutive `Double`s, so this shape also fits SkyLight's
    /// `SLEventSetWindowLocation`.
    public typealias SetWindowLocation = @convention(c) (
        UnsafeMutableRawPointer?,
        Double,
        Double
    ) -> Void

    /// `SLEventSetIntegerValueField(event, field, value)`.
    public typealias SetIntegerValueField = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32,
        Int64
    ) -> Void

    /// `_AXUIElementGetWindow(element, &windowID)`.
    public typealias AXUIElementGetWindow = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<UInt32>?
    ) -> AXError
}
