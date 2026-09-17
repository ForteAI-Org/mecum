//
//  FakeFacilities.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession

/// The three role protocols of the session layer, faked. This is what makes
/// the whole state machine a unit test: no virtual display, no event tap, no
/// Accessibility grant, no Screen Recording, and no window belonging to a
/// person who is trying to work.
///
/// They are `@unchecked Sendable` classes for the honest reason: the protocols
/// are `nonisolated` because the live witnesses are read from the heartbeat and
/// the recovery loop, and everything in this suite drives them from the main
/// actor and from nowhere else.

/// A virtual display 2560 by 1440 attached to the right of a 1512 by 982
/// physical one, which is the reference machine's real arrangement.
enum FakeGeometry {

    static let physical = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let virtual  = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    static let mainDisplayID: CGDirectDisplayID = 1
    static let targetPID    : Int32             = 4242
    static let userPID      : Int32             = 99
    static let windowNumber                     = 777

    static let windowSize = CGSize(width: 800, height: 600)

    static func identity(
        processID  : Int32 = targetPID,
        windowNumber: Int = FakeGeometry.windowNumber,
        lifetime   : UInt32 = 1
    ) -> WindowIdentity {
        WindowIdentity(
            process: ProcessIdentity(
                processID       : processID,
                serialNumberHigh: lifetime,
                serialNumberLow : UInt32(bitPattern: processID)
            ),
            windowNumber     : windowNumber,
            ownerConnectionID: processID &+ 1_000
        )
    }

    static func reference(
        frame       : CGRect,
        processID   : Int32 = targetPID,
        windowNumber: Int = FakeGeometry.windowNumber,
        lifetime    : UInt32 = 1
    ) -> WindowReference {
        WindowReference(
            identity: identity(
                processID   : processID,
                windowNumber: windowNumber,
                lifetime    : lifetime
            ),
            frame: frame
        )
    }

    static var windowOrigin: CGPoint {
        CGPoint(x: virtual.midX - windowSize.width / 2, y: virtual.midY - windowSize.height / 2)
    }

    /// The window as it sits in the User Seat, before adoption.
    static var userSeatWindow: WindowReference {
        reference(frame: CGRect(origin: CGPoint(x: 100, y: 100), size: windowSize))
    }

    /// The window as it sits on the virtual display, after adoption.
    static var adoptedWindow: WindowReference {
        reference(frame: CGRect(origin: windowOrigin, size: windowSize))
    }
}

final class FakeSensing: SeatSensing, @unchecked Sendable {

    var mainDisplayID               = FakeGeometry.mainDisplayID
    var physicalTopologyIsUnchanged = true
    var virtualDisplayIsOnline      = true
    var virtualDisplayBounds        = FakeGeometry.virtual
    var fenceIsActive               = true
    var cursorLocation: CGPoint?    = CGPoint(x: 700, y: 500)
    var frontmostProcessID: Int32?  = FakeGeometry.userPID
    var focusedUserWindow: WindowReference?
    var preparedSnapshot: FocusRecoverySnapshot?
    var snapshotReadCount = 0
    var focusRecoverySnapshot: FocusRecoverySnapshot? {
        get { snapshotReadCount += 1; return preparedSnapshot }
        set { preparedSnapshot = newValue }
    }
    var snapshotPreparation: (@MainActor () async -> FocusRecoverySnapshot?)?
    @MainActor func prepareFocusRecoverySnapshot() async -> FocusRecoverySnapshot? {
        if let snapshotPreparation { return await snapshotPreparation() }
        return focusRecoverySnapshot
    }
    var userMayBeSwitchingApplications = false
    var additionalWindows: [Int: WindowReference] = [:]
    var targetWindowsAreVirtual = true
    var userWindowIsPhysical = true

    func visibleWindowsAreVirtual(ownedBy processID: Int32) -> Bool { targetWindowsAreVirtual }
    func windowIsVisibleOnPhysicalDisplay(_ window: WindowReference) -> Bool { userWindowIsPhysical }

    /// What the window server answers for the target's Window ID. Nil is an
    /// unreadable window, which is a recoverable Issue and not a missing one.
    var geometry: WindowReference? = FakeGeometry.adoptedWindow

    /// Three-valued, exactly as the live witness: nil is a dead process.
    var targetIsActive: Bool? = false

    var isBehind: Bool?  = true
    var orderIndex: Int? = 3

    /// What the next drain answers. It is consumed, like the real latch.
    var pendingSignals = FenceSignals.quiet

    var drainCount = 0

    func fenceContainsPhysicalPoint(_ point: CGPoint) -> Bool {
        FakeGeometry.physical.contains(point)
    }

    func drainFenceSignals() -> FenceSignals {
        drainCount += 1
        let batch = pendingSignals
        pendingSignals = .quiet
        return batch
    }

    func windowGeometry(of windowNumber: Int) -> WindowReference? {
        windowNumber == FakeGeometry.windowNumber ? geometry : additionalWindows[windowNumber]
    }

    func windowGeometryObservation(
        of window: WindowReference
    ) -> WindowGeometryObservation? {
        WindowGeometryObservation(
            window     : window,
            scaleFactor: 2,
            version    : GeometryObservationVersion(
                observerGeneration: 1,
                sequence          : 1
            )
        )
    }

    func isActive(processID: Int32) -> Bool? {
        processID == FakeGeometry.targetPID ? targetIsActive : false
    }

    func isBehindFrontmostWindow(windowNumber: Int, ownedBy processID: Int32) -> Bool? { isBehind }

    func windowOrderIndex(of windowNumber: Int) -> Int? { orderIndex }

    /// The menu windows of the target, as the window server would answer them.
    /// The whole contextual menu action is driven through this one list: empty
    /// is no menu, one entry is a menu that is up. A test opens and closes it
    /// from the sender's own hooks, so the menu's life is caused by the same
    /// things that cause it on a real machine and not by a read count.
    var menus: [WindowReference] = []

    /// How many times the oracle was asked. A test asserts on it when what it
    /// wants to know is that the action polled rather than guessed.
    private(set) var menuReadCount = 0

    func menuWindows(ownedBy processID: Int32) -> [WindowReference] {
        guard processID == FakeGeometry.targetPID else { return [] }
        menuReadCount += 1
        return menus
    }

    /// What the window server answers for the driven processes. `nil` is the
    /// reading that failed, which the watch has to tell from an empty desktop.
    var surfaces: [WindowSurface]? = []

    /// How many passes the window watch has really made, for a test that wants
    /// to know a stopped watch stopped reading rather than stopped acting.
    private(set) var surfaceReadCount = 0

    func windowSurfaces(ownedBy processIDs: Set<Int32>) -> [WindowSurface]? {
        surfaceReadCount += 1
        guard let surfaces else { return nil }
        return surfaces.filter { processIDs.contains($0.reference.processID) }
    }
}

/// The menu window the fakes hand back: a window of the target's process with a
/// Window ID of its own, which is exactly what the window server reports for a
/// real one.
extension FakeGeometry {

    static let menuWindowNumber = 778

    static var menuWindow: WindowReference {
        reference(
            frame       : CGRect(x: 2000, y: 700, width: 115, height: 34),
            windowNumber: menuWindowNumber
        )
    }
}

final class FakePlacing: WindowPlacing, @unchecked Sendable {

    /// Every origin written, in order. What a placing fake is for is the
    /// record: the recovery policy's promise is a bounded number of writes and
    /// none of them on an active application.
    var moves: [CGPoint] = []
    var stages           = 0
    var recoveries       = 0

    var bodyFrame: CGRect?

    /// The accessibility body of one window, for a suite that has several of
    /// them and needs each to answer for itself.
    var bodyFrames: [Int: CGRect] = [:]

    /// A window with no element behind its Window ID, which is what an external
    /// popup looks like to the relocator.
    var frameError: (any Error)?

    func frame(of window: WindowReference) throws -> CGRect? {
        if let frameError { throw frameError }
        return bodyFrames[window.windowNumber] ?? bodyFrame
    }

    var moveError : (any Error)?
    var stageError: (any Error)?
    var afterMoveError: (any Error)?
    var onStage: (() -> Void)?
    var onStageWait: (() async -> Void)?

    /// What the sensing will answer after a move, so a test can make the window
    /// arrive where it was put.
    var onMove: ((CGPoint) -> Void)?

    func move(_ window: WindowReference, to origin: CGPoint) throws {
        moves.append(origin)
        if let moveError { throw moveError }
        onMove?(origin)
        if let afterMoveError { throw afterMoveError }
    }

    func stage(
        _ window     : WindowReference,
        expectedSize : CGSize,
        within bounds: CGRect
    ) async throws -> WindowReference {

        stages += 1
        if let stageError { throw stageError }
        onStage?()
        await onStageWait?()

        return window.replacingFrame(CGRect(origin: window.frame.origin, size: expectedSize))
    }

    func recover(
        _ window           : WindowReference,
        expectedTitle      : String,
        expectedSize       : CGSize,
        sourceDisplayBounds: CGRect,
        to origin          : CGPoint
    ) throws {
        recoveries += 1
        moves.append(origin)
        onMove?(origin)
    }
}

class FakeSender: CommandSending, @unchecked Sendable {

    var unvalidatedBuild = false

    /// A real gate, not a stub: the seat's own window transfer and a focus
    /// recovery close it at the same time, and whether one of them reopens it
    /// for the other is exactly what a test has to be able to see.
    let gate = InputCommandGate()

    var inputCommandGate: InputCommandGate? { gate }

    /// Every Command that went out, with the marker it was stamped with.
    var sent: [(command: InputCommand, correlationID: Int64)] = []

    var error: (any Error)?

    /// True to answer with a Receipt that says the Preparation was not undone,
    /// which the seat has to turn into an Issue and never into an error.
    var reportsUnrestoredPreparation = false

    func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform
    ) async throws -> InputReceipt {

        // The live driver refuses at the gate before the first event, so a fake
        // that posted anyway would be modelling a driver that does not exist.
        try gate.check()
        if let error { throw error }
        if let refusal = refusedCommand?(command) { throw refusal }

        sent.append((command, correlationID))
        onSend?(command)
        await onSendWait?()
        return receipt(for: window)
    }

    func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform
    ) async throws -> [InputReceipt] {

        try gate.check()
        if let error { throw error }

        for command in commands { sent.append((command, correlationID)) }
        // The Receipts differ by posting time in production; here they are made
        // distinguishable on purpose, because `confirm` matches on the Receipt.
        return commands.indices.map { receipt(for: window, index: $0) }
    }

    /// How many times the teardown's lever was pulled, and on which window. It
    /// is the assertion of the contextual menu action: the close is not
    /// optional, so it has to be visible from outside.
    var preparationCycles: [Int] = []

    var cycleError: (any Error)?

    /// What the target does when the lever is pulled. A contextual menu test
    /// wires this to the sensing fake, so that closing the menu is caused by
    /// the cycle exactly as it is on a real machine.
    var onCyclePreparation: (() -> Void)?

    /// What the target does when a Command reaches it, called before the
    /// Receipt is made.
    var onSend: ((InputCommand) -> Void)?

    /// A Command that takes time, so a test can ask the seat for something
    /// while one is genuinely in flight.
    var onSendWait: (() async -> Void)?

    /// A refusal for one particular Command, answered before anything is
    /// recorded as sent: the real driver refuses before the first event goes
    /// out, so a fake that recorded it first would be modelling nothing.
    var refusedCommand: ((InputCommand) -> (any Error)?)?

    func cyclePreparation(on window: WindowReference) async throws {
        preparationCycles.append(window.windowNumber)
        if let cycleError { throw cycleError }
        onCyclePreparation?()
    }

    private func receipt(for window: WindowReference, index: Int = 0) -> InputReceipt {
        InputReceipt(
            eventCount              : 2,
            route                   : InputRoute(
                poster           : .publicProcess,
                routedEventCount : 2,
                windowNumber     : window.windowNumber,
                ownerConnectionID: 1
            ),
            preparation             : .internalAppKitState,
            timing                  : InputTiming(
                postingNanoseconds: UInt64(1_000 + index),
                settleNanoseconds : 30_000_000
            ),
            unvalidatedBuild        : unvalidatedBuild,
            hasUnrestoredPreparation: reportsUnrestoredPreparation
        )
    }
}

/// A seat wired to the three fakes, already holding an adopted window, which is
/// the starting point of every test about acting.
@MainActor
func makeSeat(
    sensing: FakeSensing = FakeSensing(),
    placing: FakePlacing = FakePlacing(),
    sender : FakeSender  = FakeSender(),
    marker : Int64       = 555
) -> AgentSeat {

    // `KeyHold` is process wide and keyed by owner and PID, so a test that
    // presses a key needs a marker of its own: the default one is shared by
    // every seat here, and these suites run in parallel.
    AgentSeat(
        sensing              : sensing,
        placing              : placing,
        sender               : sender,
        fence                : nil,
        displayID            : 7,
        expectedMainDisplayID: FakeGeometry.mainDisplayID,
        markers              : { marker }
    )
}
