//
//  AppKitStatePreparation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Darwin
import Dispatch
import PrivateSymbols
import SeatCore

/// AppKitStatePreparation is the Preparation: three byte records handed to
/// `SLPSPostEventRecordTo` that make one window active and key **inside its own
/// process**, and one that gives the state back afterwards.
///
/// It is deliberately not public. What it does is safe only because of what it
/// does not do: `_SLPSSetFrontProcessWithOptions` is never called, so the
/// window server's front process and the person's Space do not move, and the
/// records reach one process serial number, the target's. The driver controls
/// preparation; the separately gated user-focus restorer reuses only the
/// identity lookup for its destination-bound activation request.
///
/// Verified on 26A5425a: an instrumented target reports
/// `NSApp.isActive` and `isKeyWindow` true while the person's frontmost
/// application does not change, and reports them false again after the restore.
/// There is no fallback: a record the window server refuses stops the Command
/// before any event is posted.
nonisolated package struct AppKitStatePreparation {

    package struct RollbackTiming {
        package let startedAtNanoseconds  : UInt64
        package let completedAtNanoseconds: UInt64
    }

    /// One target, resolved once: the process, its window, and the process
    /// serial number the records are addressed to. The PSN comes from the
    /// window's **owning connection** and not from the process, because a
    /// process with several connections would otherwise be prepared at the
    /// wrong one.
    package struct Participant {

        /// The two halves of the deprecated `ProcessSerialNumber`, kept raw
        /// because the public struct is unavailable in Swift 6.
        package struct SerialNumber: Equatable {
            package var high: UInt32 = 0
            package var low : UInt32 = 0
        }

        package let processID        : Int32
        package let windowNumber     : UInt32
        package let ownerConnectionID: Int32
        package var serialNumber     : SerialNumber
    }

    /// The record type at 0x08 that carries an activation state.
    private static let activationRecordType: UInt8 = 0x0D

    /// The record types at 0x08 of the two key-window records, posted in this
    /// order. Two records, not one: the window server accepts the pair, and the
    /// pair is what was measured.
    private static let keyWindowRecordTypes: [UInt8] = [0x01, 0x02]

    /// The byte at 0x8A: 1 makes the target consider itself active, 2 gives it
    /// back its inactive state. `mouseEventNumber` sits at the same offset,
    /// which is the field an activation record reuses.
    private static let activationStateOffset = 0x8A

    /// The flags byte a key-window record carries.
    private static let keyWindowFlags: UInt8 = 0x10

    private let connectionID    : Int32
    private let getWindowOwner  : SymbolABI.GetWindowOwner
    private let getConnectionPSN: SymbolABI.GetConnectionPSN
    private let postEventRecord : SymbolABI.PostEventRecordTo

    /// Resolves the three primitives once. `nil` when one of them is missing,
    /// which the driver turns into `primitiveUnavailable` at construction time
    /// rather than in the middle of an action.
    package init?(table: SymbolTable, connectionID: Int32) {
        guard
            let getWindowOwner   = table.function(.getWindowOwner,   as: SymbolABI.GetWindowOwner.self),
            let getConnectionPSN = table.function(.getConnectionPSN, as: SymbolABI.GetConnectionPSN.self),
            let postEventRecord  = table.function(.postEventRecordTo, as: SymbolABI.PostEventRecordTo.self)
        else {
            return nil
        }
        self.connectionID     = connectionID
        self.getWindowOwner   = getWindowOwner
        self.getConnectionPSN = getConnectionPSN
        self.postEventRecord  = postEventRecord
    }

    /// The identity chain: Window ID to owning connection to process serial
    /// number. It is re-run for every Preparation and never cached across
    /// Commands, because a window that was replaced between two actions would
    /// otherwise be prepared through the dead one's connection.
    package func participant(for window: WindowReference, didResolveOwner: (() -> Void)? = nil) throws -> Participant {
        guard let windowNumber = UInt32(exactly: window.windowNumber), windowNumber != 0 else {
            throw InputFailure.invalidWindowNumber(window.windowNumber)
        }
        var ownerConnectionID: Int32 = 0
        let ownerResult = getWindowOwner(connectionID, windowNumber, &ownerConnectionID)
        guard ownerResult == 0, ownerConnectionID != 0 else {
            throw InputFailure.windowOwnerUnavailable(
                windowNumber: window.windowNumber,
                code        : ownerResult
            )
        }
        didResolveOwner?()
        var serialNumber = Participant.SerialNumber()
        let psnResult = withUnsafeMutablePointer(to: &serialNumber) { pointer in
            getConnectionPSN(ownerConnectionID, UnsafeMutableRawPointer(pointer))
        }
        guard psnResult == 0 else {
            throw InputFailure.windowOwnerUnavailable(
                windowNumber: window.windowNumber,
                code        : psnResult
            )
        }
        return Participant(
            processID        : window.processID,
            windowNumber     : windowNumber,
            ownerConnectionID: ownerConnectionID,
            serialNumber     : serialNumber
        )
    }

    /// Makes the window active and key inside its process. Three records, in
    /// the order they were measured in. Every failure reports the records that
    /// completed and the bounded cleanup result, including a failed activation
    /// whose nonzero return leaves its effect uncertain.
    package func apply(_ participant: inout Participant) throws {
        var ignored: RollbackTiming?
        try apply(&participant, rollbackTiming: &ignored)
    }

    /// Applies the Preparation and exposes the emergency restore interval. The
    /// thrown wrapper preserves both the original failure and any restore
    /// failure without replacing either one with prose.
    package func apply(
        _ participant : inout Participant,
        rollbackTiming: inout RollbackTiming?
    ) throws {
        var completedStepCount = 0
        var failedStep: PreparationStep? = .activation

        do {
            try post(activation: true, to: &participant, step: .activation)
            completedStepCount += 1
            try makeKey(
                participant,
                completedStepCount: &completedStepCount,
                failedStep       : &failedStep
            )
            return
        } catch let primaryCause {
            let failedStepMayHaveTakenEffect: Bool
            if let inputFailure = primaryCause as? InputFailure,
               case .preparationFailed = inputFailure {
                failedStepMayHaveTakenEffect = true
            } else {
                failedStepMayHaveTakenEffect = false
            }

            let cleanupIsRequired = completedStepCount > 0
                || (failedStep == .activation && failedStepMayHaveTakenEffect)
            var cleanup: InputCleanupResult = .notRequired
            var cleanupCause: (any Error)?

            if cleanupIsRequired {
                cleanup = .notAttempted
                let rollbackStart = DispatchTime.now().uptimeNanoseconds
                do {
                    try post(activation: false, to: &participant, step: .restore)
                    cleanup = .succeeded
                } catch let failure {
                    cleanup      = Self.cleanupResult(for: failure)
                    cleanupCause = failure
                }
                rollbackTiming = RollbackTiming(
                    startedAtNanoseconds  : rollbackStart,
                    completedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            }

            let progress = InputProgress(
                completedSteps              : Array(PreparationStep.allCases.prefix(completedStepCount)),
                failedStep                  : failedStep,
                failedStepMayHaveTakenEffect: failedStepMayHaveTakenEffect,
                cleanup                     : cleanup
            )
            throw InputPreparationFailure(
                progress    : progress,
                cause       : primaryCause,
                cleanupCause: cleanupCause
            )
        }
    }

    /// The key-window pair used by background target preparation and the
    /// package-only recovery comparison. Normal recovery verifies activation.
    package func makeKey(_ participant: Participant, didPost: ((PreparationStep) -> Void)? = nil) throws {
        for (index, type) in Self.keyWindowRecordTypes.enumerated() {
            let step: PreparationStep = index == 0 ? .keyWindowFirst : .keyWindowSecond
            let code = try postKeyWindow(type: type, of: participant)
            didPost?(step)
            guard code == 0 else { throw InputFailure.preparationFailed(step: step, code: code) }
        }
    }

    /// Posts the key-window pair while recording progress in fixed-size state.
    /// The public step array is materialized only if one of these records
    /// fails, instead of being maintained throughout the normal path.
    private func makeKey(
        _ participant     : Participant,
        completedStepCount: inout Int,
        failedStep        : inout PreparationStep?
    ) throws {
        for (index, type) in Self.keyWindowRecordTypes.enumerated() {
            let step: PreparationStep = index == 0 ? .keyWindowFirst : .keyWindowSecond
            failedStep = step
            let code = try postKeyWindow(type: type, of: participant)
            guard code == 0 else { throw InputFailure.preparationFailed(step: step, code: code) }
            completedStepCount += 1
        }
    }

    /// Gives the target its inactive state back. The key-window records are not
    /// undone: a window that is key inside a process nobody activated is what
    /// that process saw before the Command as well.
    package func restore(_ participant: inout Participant) throws {
        try post(activation: false, to: &participant, step: .restore)
    }

    /// Converts every restore failure into an outcome without discarding the
    /// original typed value retained by `InputPreparationFailure`.
    private static func cleanupResult(for failure: any Error) -> InputCleanupResult {
        guard let inputFailure = failure as? InputFailure,
              case .restoreFailed(let code) = inputFailure else {
            return .failed(code: nil)
        }
        return .failed(code: code)
    }

    private func post(
        activation active: Bool,
        to participant   : inout Participant,
        step             : PreparationStep
    ) throws {
        let code = try withRecord(of: participant) { record, length in
            try RecordLayout.write(
                Self.activationRecordType,
                at    : RecordLayout.typeOffset,
                into  : record,
                length: length
            )
            try RecordLayout.write(
                UInt8(active ? 0x01 : 0x02),
                at    : Self.activationStateOffset,
                into  : record,
                length: length
            )
        }
        guard code == 0 else {
            throw step == .restore
                ? InputFailure.restoreFailed(code: code)
                : InputFailure.preparationFailed(step: step, code: code)
        }
    }

    private func postKeyWindow(type: UInt8, of participant: Participant) throws -> Int32 {
        try withRecord(of: participant) { record, length in
            try RecordLayout.write(type, at: RecordLayout.typeOffset, into: record, length: length)
            try RecordLayout.write(
                Self.keyWindowFlags,
                at    : RecordLayout.flagsOffset,
                into  : record,
                length: length
            )
            // The window-local point of a key-window record is "no point at
            // all": both doubles are all ones, which is what the window server
            // was measured to accept.
            try RecordLayout.write(
                UInt64.max,
                at    : RecordLayout.localPointXOffset,
                into  : record,
                length: length
            )
            try RecordLayout.write(
                UInt64.max,
                at    : RecordLayout.localPointYOffset,
                into  : record,
                length: length
            )
        }
    }

    /// Builds one record on the stack, lets the caller fill in what is specific
    /// to it, and posts it. The buffer is temporary rather than an `Array`
    /// because a Preparation has an allocation budget of zero (spec section 8),
    /// and 256 bytes is what `RecordLayout` says to hand the window server.
    private func withRecord(
        of participant: Participant,
        _ fill        : (UnsafeMutableRawPointer, Int) throws -> Void
    ) throws -> Int32 {

        var serialNumber = participant.serialNumber
        let length       = RecordLayout.allocatedLength

        return try withUnsafeTemporaryAllocation(
            byteCount: length,
            alignment: MemoryLayout<UInt64>.alignment
        ) { buffer -> Int32 in
            guard let record = buffer.baseAddress else {
                throw InputFailure.eventRecordUnavailable
            }
            _ = record.initializeMemory(as: UInt8.self, repeating: 0, count: length)
            try RecordLayout.write(
                RecordLayout.declaredLength,
                at    : RecordLayout.lengthOffset,
                into  : record,
                length: length
            )
            try RecordLayout.write(
                participant.windowNumber,
                at    : RecordLayout.windowNumberOffset,
                into  : record,
                length: length
            )
            try fill(record, length)

            return withUnsafeMutablePointer(to: &serialNumber) { psn in
                postEventRecord(
                    UnsafeMutableRawPointer(psn),
                    record.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }
}
