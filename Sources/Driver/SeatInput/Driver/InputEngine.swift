//
//  InputEngine.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Darwin
import Dispatch
import Foundation
import PrivateSymbols
import SeatCore
import WindowPlacement

/// InputEngine is the synchronous half of the Background Driver: identity,
/// routing, posting. It holds the one `CGEventSource` and the one set of
/// resolved primitives a driver owns, and it never waits for anything except
/// the pacing of a drag.
///
/// It exists apart from `InputDriver` so the synchronous posting work remains
/// measurable without an actor hop. Coordinate Commands now deliberately pay
/// for two WindowServer geometry snapshots, before construction and before the
/// first post; the old zero-allocation whole-send baseline does not describe
/// this safer path and must be remeasured. The actor is where serialisation,
/// Preparation and settle live; everything under them is here.
///
/// Nothing in this type is `Sendable` on purpose. It is owned by one actor, and
/// the reused event buffer is only safe because of that.
nonisolated package final class InputEngine {

    /// True when the Ledger does not cover this build or this hardware, so
    /// every Receipt says so. It describes the evidence, not the permission.
    package let unvalidatedBuild: Bool

    /// Whether this build encodes a modifier transition record the way the rest
    /// of the event table is encoded, asked once for the life of the process.
    ///
    /// It is a `static let`, so Swift computes it lazily and exactly once under
    /// its own lock: one event built, mutated and thrown away, and never again.
    /// The answer gates `ModifierPolicy.flagsChanged`, which refuses rather than
    /// quietly falling back, because a silent downgrade would make a matrix row
    /// pass for the wrong reason.
    package static let flagsChangedRecordIsVerified: Bool =
        RecordLayout.verifyFlagsChangedRecord().passed

    /// The process-wide registry of what this kit is holding down, injectable
    /// so a test does not have to reach through a singleton.
    package let keyHold: KeyHold

    private let commandGate: InputCommandGate?
    private let identityReader: (Int) -> WindowIdentity?
    private let geometryReader: (WindowReference) -> WindowGeometryObservation?

    /// One private source per driver. `.privateState` keeps the person's own
    /// modifier and button state out of the events, and the suppression
    /// interval is zeroed so a posted event never mutes the person's mouse.
    private let source: CGEventSource

    private let recordPointer    : SymbolABI.EventRecordPointer
    private let setWindowLocation: SymbolABI.SetWindowLocation

    /// Integer field 51: the record's window number at 0x3C. Built once because
    /// `CGEventField(rawValue:)` is failable and the warm path may not throw
    /// away an event for a constant that was already checked.
    private let windowNumberField   : CGEventField
    private let ownerConnectionField: CGEventField

    /// The Preparation, resolved with the same table. It is here rather than in
    /// the actor so a driver has exactly one set of primitives.
    package let preparation: AppKitStatePreparation

    /// The event buffer, reused across sends. This is the whole reason the
    /// engine is a class with mutable state: an array built per send is one
    /// allocation per send, and the budget is zero.
    private var pending: [PreparedEvent] = []

    /// Every primitive the posting path needs, in the order the Ledger lists
    /// them. `SLEventRecordPointer` is on the list although the routed fields
    /// go through public setters: it is what answers the declared length, which
    /// is the only whole-record check the system offers.
    package static let postingPrimitives: [PrimitiveRequirement] = [
        .symbol(.mainConnectionID),
        .symbol(.getWindowOwner),
        .symbol(.getConnectionPSN),
        .symbol(.eventRecordPointer),
        .symbol(.postEventRecordTo),
        .symbol(.setWindowLocation),
    ]

    package init(
        table           : SymbolTable = .shared,
        unvalidatedBuild: Bool = false,
        commandGate     : InputCommandGate? = nil,
        keyHold         : KeyHold = .shared,
        allowUnvalidatedIdentity: Bool = false,
        identityReader          : @escaping (Int, SymbolTable, FacilityGate) -> WindowIdentity? = {
            WindowServerProbe.identity(of: $0, table: $1, validatedBy: $2)
        },
        geometryReader          : @escaping (WindowReference, Bool) -> WindowGeometryObservation? = {
            WindowGeometryProbe.observation(
                of                   : $0,
                allowUnvalidatedBuild: $1
            )
        }
    ) throws {
        self.commandGate = commandGate
        self.keyHold     = keyHold
        let identityGate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedIdentity,
            table                : table
        )
        guard identityGate.mayAct else {
            throw InputFailure.facilityUnavailable(identityGate.readiness)
        }
        self.identityReader = { identityReader($0, table, identityGate) }
        self.geometryReader = { geometryReader($0, allowUnvalidatedIdentity) }
        if let missing = table.firstUnresolved(of: Self.postingPrimitives) {
            throw InputFailure.primitiveUnavailable(missing)
        }
        guard
            let mainConnectionID  = table.function(.mainConnectionID,   as: SymbolABI.MainConnectionID.self),
            let recordPointer     = table.function(.eventRecordPointer, as: SymbolABI.EventRecordPointer.self),
            let setWindowLocation = table.function(.setWindowLocation,  as: SymbolABI.SetWindowLocation.self)
        else {
            throw InputFailure.primitiveUnavailable("SkyLight")
        }
        guard
            let windowNumberField    = CGEventField(rawValue: RecordLayout.windowNumberField),
            let ownerConnectionField = CGEventField(rawValue: RecordLayout.ownerConnectionField)
        else {
            throw InputFailure.primitiveUnavailable("CGEvent.integerValueField.51")
        }
        let connectionID = mainConnectionID()
        guard connectionID != 0 else { throw InputFailure.mainConnectionUnavailable }
        guard let preparation = AppKitStatePreparation(table: table, connectionID: connectionID) else {
            throw InputFailure.primitiveUnavailable("SLPSPostEventRecordTo")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw InputFailure.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0

        self.unvalidatedBuild     = unvalidatedBuild
        self.source               = source
        self.recordPointer        = recordPointer
        self.setWindowLocation    = setWindowLocation
        self.windowNumberField    = windowNumberField
        self.ownerConnectionField = ownerConnectionField
        self.preparation          = preparation
        self.pending.reserveCapacity(16)
    }

    /// Builds one Command and posts it. **Everything is verified before the
    /// first event goes out**: the process, the window, the owning connection,
    /// every coordinate and every record's declared length. A send that refuses
    /// halfway would leave a press without its release.
    ///
    /// It waits only where the platform's pacing says to, which is inside a
    /// drag and nowhere else. That wait blocks the caller's thread on purpose:
    /// a Command is atomic, the actor above is serialised for its duration
    /// anyway, and `usleep` between two events is what was measured to work.
    package func post(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform
    ) throws -> InputReceipt {

        var trace = InputTraceIdentity.submitted(
            command      : command,
            window       : window,
            correlationID: correlationID
        )
        trace.beginExecution(at: DispatchTime.now().uptimeNanoseconds)
        let receipt = try post(
            command,
            to           : window,
            correlationID: correlationID,
            platform     : platform,
            trace        : &trace
        )
        return receipt.replacingTrace(
            trace.completed(at: DispatchTime.now().uptimeNanoseconds)
        )
    }

    /// Builds and posts one Command while extending a trace that may have
    /// started in the session layer before this actor was entered.
    package func post(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        trace        : inout InputTraceContext
    ) throws -> InputReceipt {

        pending.removeAll(keepingCapacity: true)
        defer { pending.removeAll(keepingCapacity: true) }

        let verificationStart = DispatchTime.now().uptimeNanoseconds
        let resolved: WindowIdentity
        do {
            resolved = try identity(of: window)
        } catch {
            trace.recordWindowVerification(
                from   : verificationStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            throw error
        }
        let validatedCommand: InputCommand
        let constructedGeometry: WindowGeometryObservation?
        do {
            try WindowCoordinateValidator.requireObservations(in: command)
            if command.hasMouseLocation {
                guard let currentGeometry = geometryReader(window) else {
                    throw InputFailure.currentCoordinateGeometryUnavailable
                }
                guard currentGeometry.window.identity == resolved else {
                    throw InputFailure.coordinateIdentityChanged(
                        expected: resolved,
                        observed: currentGeometry.window.identity
                    )
                }
                validatedCommand = try WindowCoordinateValidator.validate(
                    command,
                    against: currentGeometry
                )
                constructedGeometry = currentGeometry
            } else {
                validatedCommand = command
                constructedGeometry = nil
            }
        } catch {
            trace.recordWindowVerification(
                from   : verificationStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            throw error
        }
        trace.recordWindowVerification(
            from   : verificationStart,
            through: DispatchTime.now().uptimeNanoseconds
        )

        // Resolved and refused before construction, like every other refusal of
        // this engine: a policy this build cannot express must stop the Command
        // while nothing has gone out.
        let modifierPolicy = try Self.resolveModifierPolicy(
            platform.modifierPolicy(for: validatedCommand),
            flagsChangedRecordIsVerified: Self.flagsChangedRecordIsVerified
        )

        let heldModifiers = keyHold.modifiers(processID: window.processID)
        try Self.requireStableShortcutContext(
            for : validatedCommand,
            held: heldModifiers
        )

        let constructionStart = DispatchTime.now().uptimeNanoseconds
        do {
            try InputEvents.append(
                validatedCommand,
                source         : source,
                pacing         : platform.dragPacing,
                keyRepeatPacing: platform.keyRepeatPacing,
                held           : heldModifiers,
                policy         : modifierPolicy,
                correlationID  : correlationID,
                into           : &pending
            )
        } catch {
            trace.recordEventConstruction(
                from   : constructionStart,
                through: DispatchTime.now().uptimeNanoseconds,
                copies : .unknown
            )
            throw error
        }
        trace.recordEventConstruction(
            from   : constructionStart,
            through: DispatchTime.now().uptimeNanoseconds,
            copies : .known(InputEvents.explicitBufferCopyCount(
                for            : validatedCommand,
                builtEventCount: pending.count
            ))
        )
        guard !pending.isEmpty else { throw InputFailure.noCommands }
        trace.recordNativeEventTimestamps(
            first: pending.first?.event.timestamp,
            last : pending.last?.event.timestamp
        )

        var routedEventCount = 0
        for item in pending {
            let decorationStart = DispatchTime.now().uptimeNanoseconds
            platform.decorate(item.event, for: validatedCommand)
            trace.recordRoutingWork(
                from   : decorationStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            guard let point = item.windowPointFromTop else { continue }
            let routingStart = DispatchTime.now().uptimeNanoseconds
            do {
                try route(
                    item.event,
                    to               : point,
                    windowNumber     : resolved.windowNumber,
                    ownerConnectionID: resolved.ownerConnectionID
                )
            } catch {
                trace.recordRouting(
                    from   : routingStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            trace.recordRouting(
                from   : routingStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            routedEventCount += 1
        }

        try commandGate?.check()
        let reverificationStart = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try identity(of: window)
            if let constructedGeometry {
                guard let currentGeometry = geometryReader(window) else {
                    throw InputFailure.currentCoordinateGeometryUnavailable
                }
                try WindowCoordinateValidator.requireUnchanged(
                    constructedGeometry,
                    current: currentGeometry
                )
            }
        } catch {
            trace.recordWindowVerification(
                from   : reverificationStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            throw error
        }
        trace.recordWindowVerification(
            from   : reverificationStart,
            through: DispatchTime.now().uptimeNanoseconds
        )
        let start = DispatchTime.now().uptimeNanoseconds
        for item in pending {
            let postStart = DispatchTime.now().uptimeNanoseconds
            item.event.postToPid(window.processID)
            trace.recordSendSystemCall(
                from   : postStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            if item.delayAfterPostingMicroseconds > 0 {
                let waitStart = DispatchTime.now().uptimeNanoseconds
                usleep(item.delayAfterPostingMicroseconds)
                trace.recordSendWait(
                    from   : waitStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start

        // Recorded after the posting loop and never before it: the loop cannot
        // fail, so what went out is what the registry may claim is held. A
        // refusal happens above and leaves the registry untouched.
        recordHold(of: validatedCommand, on: window.processID, owner: correlationID)

        return InputReceipt(
            eventCount: pending.count,
            route     : InputRoute(
                poster           : .publicProcess,
                routedEventCount : routedEventCount,
                windowNumber     : window.windowNumber,
                ownerConnectionID: resolved.ownerConnectionID
            ),
            timing          : InputTiming(postingNanoseconds: elapsed),
            unvalidatedBuild: unvalidatedBuild,
            heldAfter       : keyHold.modifiers(processID: window.processID),
            textMeasure     : validatedCommand.textMeasure
        )
    }

    /// Re-reads the complete target identity and compares it with the identity
    /// attached when the window was observed.
    ///
    /// The reader follows Window ID to owner connection to process serial
    /// number and maps that lifetime back to a PID. A raw PID/Window ID pair is
    /// deliberately insufficient: both values can be reused.
    package func identity(
        of window: WindowReference
    ) throws -> WindowIdentity {

        guard UInt32(exactly: window.windowNumber) != nil, window.windowNumber != 0 else {
            throw InputFailure.invalidWindowNumber(window.windowNumber)
        }
        guard let expected = window.identity else {
            throw InputFailure.windowIdentityUnverified(
                processID   : window.processID,
                windowNumber: window.windowNumber
            )
        }
        let observed = identityReader(window.windowNumber)
        guard observed == expected else {
            throw InputFailure.windowIdentityChanged(expected: expected, observed: observed)
        }
        return expected
    }

    /// Writes the three fields that make an event reach one window inside the
    /// target process instead of whatever is under the pointer.
    ///
    /// None of them is a pointer store any more. The window number and the
    /// owning connection go through the public `setIntegerValueField` with ids
    /// 51 and 52, and the window-local point through
    /// `CGEventSetWindowLocation`; a round trip proved that those land on 0x3C,
    /// 0x40, 0x20 and 0x28, the same bytes a raw store would have written.
    /// The record is still asked for its declared length first, because that is
    /// the only check that covers the record as a whole.
    package func route(
        _ event          : CGEvent,
        to point         : CGPoint,
        windowNumber     : Int,
        ownerConnectionID: Int32
    ) throws {

        guard point.x.isFinite, point.y.isFinite,
              event.location.x.isFinite, event.location.y.isFinite
        else {
            throw InputFailure.invalidLocation
        }
        let eventPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(event).toOpaque())
        guard let record = recordPointer(UnsafeRawPointer(eventPointer)) else {
            throw InputFailure.eventRecordUnavailable
        }
        do {
            _ = try RecordLayout.validateDeclaredLength(of: record)
        } catch SystemFailure.unsupportedRecordLength(let declared, let expected) {
            throw InputFailure.unsupportedEventRecord(declared: declared, expected: expected)
        } catch SystemFailure.recordOffsetOutOfBounds(let offset, let width, let length) {
            throw InputFailure.recordOffsetOutOfBounds(offset: offset, width: width, length: length)
        }

        event.setIntegerValueField(windowNumberField, value: Int64(windowNumber))
        event.setIntegerValueField(ownerConnectionField, value: Int64(ownerConnectionID))
        setWindowLocation(eventPointer, Double(point.x), Double(point.y))
    }

    /// The policy this build may actually express, or a refusal.
    ///
    /// It takes the verified flag rather than reading it, so the refusal is a
    /// pure decision a unit test can drive both ways. An engine needs real
    /// private symbols to exist at all, and two lines that only ever run on a
    /// build where the record check failed would otherwise never be exercised
    /// anywhere.
    ///
    /// There is no implicit fall back to `.eventFlags`. A silent downgrade
    /// would post a Command that looks like it worked and make a matrix row
    /// pass for the wrong reason.
    package static func resolveModifierPolicy(
        _ requested                 : ModifierPolicy,
        flagsChangedRecordIsVerified: Bool
    ) throws -> ModifierPolicy {
        guard requested != .flagsChanged || flagsChangedRecordIsVerified else {
            throw InputFailure.modifierPolicyUnavailable(requested)
        }
        return requested
    }

    /// Refuses a character Shortcut whose layout plane changed after it was
    /// resolved. Resolution precedes the driver's per-PID exclusion wait, so
    /// posting with a newer held state could select a different physical key.
    /// A refusal keeps that mismatch above the posting loop.
    package static func requireStableShortcutContext(
        for command: InputCommand,
        held       : Modifiers
    ) throws {
        guard case .key(_, _, let modifiers, let phase, let origin?) = command,
              phase != .up
        else {
            return
        }
        let current = held.union(modifiers)
        let commandPlaneMatches = current.contains(.command) == origin.commandPlane
        let requiredShiftIsStillHeld = !origin.requiresShift || current.contains(.shift)
        guard commandPlaneMatches && requiredShiftIsStillHeld else {
            throw InputFailure.shortcutContextChanged(
                resolved: origin.effectiveModifiers,
                current : current
            )
        }
    }

    /// Updates the hold registry for a Command that has already been posted.
    ///
    /// Only the two phases that are not symmetric touch it. A `.press` presses
    /// and releases inside one atomic Command and leaves nothing behind, a
    /// `.repeated` carries neither a down nor an up of its own, and no mouse or
    /// text Command holds a key at all.
    ///
    /// The character the key was resolved from travels into the registry with
    /// it, because the person can change keyboard layout between the down and
    /// the up and what went down is what has to come up.
    private func recordHold(of command: InputCommand, on processID: Int32, owner: Int64) {
        guard case .key(let virtualKey, _, _, let phase, let origin) = command else { return }
        switch phase {
            case .down:
                keyHold.press(
                    KeyHold.HeldKey(virtualKey: virtualKey, character: origin?.character),
                    owner    : owner,
                    processID: processID
                )
            case .up:
                keyHold.release(virtualKey: virtualKey, owner: owner, processID: processID)
            case .press, .repeated:
                break
        }
    }
}
