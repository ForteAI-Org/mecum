//
//  WindowPlacing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Dispatch
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// WindowPlacing is the seat's whole ability to move a window, behind a role
/// protocol so that adopt, stage, release and the recovery loop run in a unit
/// test without an Accessibility grant.
///
/// The live witness is `WindowRelocator`, which is the kit's **entire** use of
/// Accessibility (ADR 0004): `AXPosition` to move, `kAXRaiseAction` to bring on
/// stage, `_AXUIElementGetWindow` to find the element behind a Window ID.
/// Nothing here reads an element tree or acts on a control.
nonisolated public protocol WindowPlacing: Sendable {

    /// Writes the window's origin. It does not wait: confirming that the window
    /// came to rest is the seat's, because what a move is confirmed against is
    /// the whole placement check.
    func move(_ window: WindowReference, to origin: CGPoint) throws

    /// The untransformed AX window body, resolved by exact PID and Window ID.
    /// Used only for return verification when the server exposes a thumbnail.
    func frame(of window: WindowReference) throws -> CGRect?

    /// Brings a window Stage Manager stashed back to full size, and waits for
    /// two agreeing window server readings of the full-size frame before
    /// answering. `expectedSize` is what full size means: a stashed window
    /// reads as a thumbnail, so size is the signal that separates the two.
    func stage(
        _ window     : WindowReference,
        expectedSize : CGSize,
        within bounds: CGRect
    ) async throws -> WindowReference

    /// Moves a window whose Window ID is momentarily not associable with an
    /// accessibility element, which happens while a display transition is in
    /// flight. It is allowed only on a single structural match and refuses on
    /// two, because a recovery that picks one of two windows can move a window
    /// the person is using.
    func recover(
        _ window           : WindowReference,
        expectedTitle      : String,
        expectedSize       : CGSize,
        sourceDisplayBounds: CGRect,
        to origin          : CGPoint
    ) throws
}

/// CommandSending is the seat's whole ability to post input, behind a role
/// protocol for the same reason: the state machine's tests must not post events
/// on the person's Mac.
///
/// The live witness is `InputDriver`. The seat adds the preflight, the
/// observation and the confirmation bookkeeping around it, and adds nothing to
/// the recipe itself: a Command still means one call, one Preparation policy,
/// no retry and no split.
nonisolated public protocol CommandSending: Sendable {

    /// True when the Ledger does not cover this build or this hardware.
    var unvalidatedBuild: Bool { get }

    func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform
    ) async throws -> InputReceipt

    func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform
    ) async throws -> [InputReceipt]

    /// Sends with a trace that may already contain the seat's queue and window
    /// verification intervals. Existing witnesses inherit the compatibility
    /// implementation below; `InputDriver` continues the trace through every
    /// driver phase.
    func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContext : InputTraceContext
    ) async throws -> InputReceipt

    /// Sends a batch with one distinct trace context per Command.
    func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContexts: [InputTraceContext]
    ) async throws -> [InputReceipt]

    /// Reports a completed refusal that produced no Receipt. The live driver
    /// forwards it to its explicit per-driver trace handler; compatibility
    /// witnesses may ignore it.
    func recordCompletedTrace(_ trace: InputCommandTrace)

    /// Applies the Preparation to the window and undoes it at once, with no
    /// Command in between. It posts no input event at all.
    ///
    /// It has one caller and it is a seam of its own for one reason: what
    /// closes a contextual menu in another process is not an event, it is the
    /// **restore**. A menu's tracking loop reads the deactivation record as an
    /// application switch and dismisses on it, measured at 50 ms. Nothing in
    /// the Command vocabulary can say "prepare and unprepare, send nothing", so
    /// without this the seat would have to post a click it does not want in
    /// order to close a menu it does not want open.
    func cyclePreparation(on window: WindowReference) async throws
}

extension CommandSending {

    public nonisolated func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContext : InputTraceContext
    ) async throws -> InputReceipt {
        do {
            return try await send(
                command,
                to           : window,
                correlationID: correlationID,
                platform     : platform
            )
        } catch {
            recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw error
        }
    }

    public nonisolated func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContexts: [InputTraceContext]
    ) async throws -> [InputReceipt] {
        do {
            return try await sendSequence(
                commands,
                to           : window,
                correlationID: correlationID,
                platform     : platform
            )
        } catch {
            let completedAt = DispatchTime.now().uptimeNanoseconds
            for traceContext in traceContexts {
                recordCompletedTrace(traceContext.completed(at: completedAt))
            }
            throw error
        }
    }

    public nonisolated func recordCompletedTrace(_ trace: InputCommandTrace) {}
}

/// The live placing witness. It is a struct and not the enum itself, because a
/// protocol witness has to be a value the seat can hold.
nonisolated public struct SystemWindowPlacing: WindowPlacing {

    public init() {}

    public func frame(of window: WindowReference) throws -> CGRect? {
        try WindowRelocator.frame(of: window)
    }

    public func move(_ window: WindowReference, to origin: CGPoint) throws {
        try WindowRelocator.move(window, to: origin)
    }

    public func stage(
        _ window     : WindowReference,
        expectedSize : CGSize,
        within bounds: CGRect
    ) async throws -> WindowReference {
        try await WindowRelocator.stage(window, expectedSize: expectedSize, within: bounds)
    }

    public func recover(
        _ window           : WindowReference,
        expectedTitle      : String,
        expectedSize       : CGSize,
        sourceDisplayBounds: CGRect,
        to origin          : CGPoint
    ) throws {
        try WindowRelocator.recover(
            window,
            expectedTitle      : expectedTitle,
            expectedSize       : expectedSize,
            sourceDisplayBounds: sourceDisplayBounds,
            to                 : origin
        )
    }
}

extension InputDriver: CommandSending {}
