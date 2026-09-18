//
//  WindowPlacing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation
import SeatCore
import SeatInput
import VirtualScreens
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

    // MARK: Native fullscreen, behind the seat's experiment

    /// `AXFullScreen` and its writability, as three answers: unreadable,
    /// readable but refused, readable and writable. An absent attribute is
    /// never `false`.
    func fullScreen(of window: WindowReference) throws -> WindowRelocator.FullScreenReading

    /// Asks the window to enter or leave native fullscreen. It does not wait:
    /// the write is accepted long before the transition happens, and the two
    /// are separate facts.
    func requestFullScreen(_ wanted: Bool, of window: WindowReference) throws

    /// Waits for the observable end of the transition and answers with the
    /// **re-read** reference, whose frame is the window's normal frame. No
    /// fixed sleep is evidence, and a process that exited ends the wait instead
    /// of consuming it.
    func awaitFullScreen(_ wanted: Bool, of window: WindowReference) async throws -> WindowReference

    /// True while the window's Space is the one on screen. Leaving fullscreen
    /// then costs the person a Space change there and back.
    func spaceIsOnScreen(for window: WindowReference) -> Bool
}

extension WindowPlacing {

    /// A witness written before this ticket answers "not readable" rather than
    /// "not fullscreen", which is the same distinction the attribute itself
    /// forces. It keeps the seat's own tests compiling without teaching them a
    /// fullscreen they do not exercise.
    public nonisolated func fullScreen(
        of window: WindowReference
    ) throws -> WindowRelocator.FullScreenReading {
        .unreadable(.attributeUnsupported)
    }

    public nonisolated func requestFullScreen(_ wanted: Bool, of window: WindowReference) throws {
        throw DisplayFailure.fullScreenNotSettable(windowNumber: window.windowNumber)
    }

    public nonisolated func awaitFullScreen(
        _ wanted: Bool,
        of window: WindowReference
    ) async throws -> WindowReference {
        throw DisplayFailure.fullScreenTransitionNotObserved(
            windowNumber: window.windowNumber,
            wanted      : wanted,
            lastFrame   : nil
        )
    }

    /// Conservative on purpose: a witness that cannot see the Space says it is
    /// still on screen, so the gate refuses instead of proceeding blind.
    public nonisolated func spaceIsOnScreen(for window: WindowReference) -> Bool { true }
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

    /// The stop this sender honours at command boundaries, when it has one.
    ///
    /// The seat needs it for a reason that has nothing to do with focus: a
    /// window transfer must hold input closed across its awaits, and the seat
    /// otherwise reaches the gate only inside `enableFocusRecovery`, which a
    /// host with `restoresUserFocus` disabled never calls. Routing it through
    /// the sender is what makes the stop available in both configurations, and
    /// what lets a test give the seat a real gate. `nil` means the witness has
    /// no gate and the seat's own refusals are the only stop there is.
    var inputCommandGate: InputCommandGate? { get }

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

    public nonisolated var inputCommandGate: InputCommandGate? { nil }
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

    public func fullScreen(of window: WindowReference) throws -> WindowRelocator.FullScreenReading {
        try WindowRelocator.fullScreen(of: window)
    }

    public func requestFullScreen(_ wanted: Bool, of window: WindowReference) throws {
        try WindowRelocator.requestFullScreen(wanted, of: window)
    }

    public func awaitFullScreen(
        _ wanted: Bool,
        of window: WindowReference
    ) async throws -> WindowReference {
        try await WindowRelocator.awaitFullScreen(wanted, of: window)
    }

    public func spaceIsOnScreen(for window: WindowReference) -> Bool {
        WindowRelocator.spaceIsOnScreen(for: window)
    }
}

extension InputDriver: CommandSending {

    /// The driver owns the gate outright; the protocol answers with an
    /// optional because a witness without one is a legitimate witness.
    public nonisolated var inputCommandGate: InputCommandGate? { commandGate }
}
