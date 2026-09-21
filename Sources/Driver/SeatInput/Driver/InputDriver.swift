//
//  InputDriver.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Dispatch
import os
import PrivateSymbols
import SeatCore

/// InputDriver is the Background Driver: it receives a Window Reference, a
/// location and one Command, builds the events, and posts them to the target
/// process. It knows no accessibility tree and no UI semantics, and it never
/// posts anything globally: there is one route, `CGEventPostToPid`, and no
/// fallback to the User Seat.
///
/// One recipe covers every target family: **prepare the target's
/// own AppKit state when the platform asks for it, then post plain events**.
/// No `mouseMoved` primer, no 12 and 28 ms pauses, no Chromium field stamping;
/// all three were measured to change no outcome, and all three are in
/// `docs/SpiLedger.md` under "verified but not used".
///
/// The actor protects this driver's reused engine and pending-event buffer. The
/// process-scoped exclusion coordinates every driver aimed at the same PID, so
/// one Preparation cannot be restored while another driver is still posting.
/// The posting work itself is synchronous, in `InputEngine`.
public actor InputDriver {

    /// CleanupAttempt keeps the typed restore failure beside the structured
    /// result. The Receipt takes the result; a failure path also retains the
    /// cause without changing the primary error.
    private struct CleanupAttempt {
        let result: InputCleanupResult
        let cause : (any Error)?

        static let notRequired = CleanupAttempt(result: .notRequired, cause: nil)
    }

    /// TraceHandler receives a completed immutable trace after a Command has
    /// finished restoration, or after a refusal has ended. It runs outside the
    /// event construction and posting loops and must return promptly.
    public typealias TraceHandler = @Sendable (InputCommandTrace) -> Void

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "input")
    private nonisolated static let targetExclusion = InputTargetExclusion.shared

    private let engine: InputEngine
    private nonisolated let traceHandler: TraceHandler?
    package nonisolated let commandGate: InputCommandGate

    /// What the Facility answered about this system when the driver was built.
    /// A driver only exists when it is allowed to act, so this is `validated`,
    /// or `unvalidated` with the consumer's opt in.
    public nonisolated let readiness: FacilityReadiness

    /// True when the Ledger does not cover this build or this hardware. Every
    /// Receipt carries the same flag.
    public nonisolated let unvalidatedBuild: Bool

    /// Builds a driver, or refuses.
    ///
    /// The gate runs here and not per send: primitives, the record's declared
    /// length and the offset round trip against the public setters, then the
    /// Post Event grant, then the Ledger (spec section 6). A build the Ledger
    /// does not know refuses unless the consumer opted in for **this** Facility,
    /// and an opt in never lifts a failed self check.
    public init(
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared,
        traceHandler         : TraceHandler? = nil
    ) throws {
        let gate = FacilityGate.current(
            facility             : .input,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard gate.mayAct else { throw InputFailure.facilityUnavailable(gate.readiness) }

        let commandGate = InputCommandGate()
        self.commandGate = commandGate
        self.engine = try InputEngine(
            table                   : table,
            unvalidatedBuild        : gate.unvalidatedBuild,
            commandGate             : commandGate,
            allowUnvalidatedIdentity: allowUnvalidatedBuild
        )
        self.traceHandler      = traceHandler
        self.readiness        = gate.readiness
        self.unvalidatedBuild = gate.unvalidatedBuild
    }

    /// Posts one Command to one window.
    ///
    /// `correlationID` is the marker the driver stamps on every event, and it
    /// belongs to the caller because the cursor fence has to be told about it
    /// **before** the first event goes out: it is what tells the driver's own
    /// events from the person's hand.
    ///
    /// When the platform asks for a Preparation the order is fixed: prepare,
    /// wait for the settle, post, restore. If the Preparation is refused,
    /// nothing at all is posted; if anything after it fails, the restore still
    /// runs.
    @discardableResult
    public nonisolated func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform = ChromiumPlatform()
    ) async throws -> InputReceipt {
        try await send(
            command,
            to           : window,
            correlationID: correlationID,
            platform     : platform,
            traceContext : InputTraceIdentity.submitted(
                command      : command,
                window       : window,
                correlationID: correlationID
            )
        )
    }

    @discardableResult
    public nonisolated func send(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContext : InputTraceContext,
        beforeFirstPost: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> InputReceipt {
        try await performSend(
            command,
            to           : window,
            correlationID: correlationID,
            platform     : platform,
            traceContext : traceContext,
            beforeFirstPost: beforeFirstPost
        )
    }

    private func performSend(
        _ command    : InputCommand,
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContext suppliedTraceContext: InputTraceContext,
        beforeFirstPost: @escaping @Sendable () async throws -> Void
    ) async throws -> InputReceipt {

        var traceContext = suppliedTraceContext
        traceContext.beginExecution(at: DispatchTime.now().uptimeNanoseconds)
        var participant: AppKitStatePreparation.Participant?
        var exclusionLease: InputTargetExclusion.Lease?

        guard window.identity != nil else {
            let failure = InputFailure.windowIdentityUnverified(
                processID   : window.processID,
                windowNumber: window.windowNumber
            )
            recordCompletedTrace(traceContext.completed(at: DispatchTime.now().uptimeNanoseconds))
            throw failure
        }

        do {
            let lease = try await Self.targetExclusion.acquire(processID: window.processID)
            exclusionLease = lease
            recordExclusion(lease.wait, in: &traceContext)
        } catch let cancellation as InputTargetExclusion.Cancellation {
            recordExclusion(cancellation.wait, in: &traceContext)
            recordCompletedTrace(traceContext.completed(at: DispatchTime.now().uptimeNanoseconds))
            throw CancellationError()
        } catch {
            recordCompletedTrace(traceContext.completed(at: DispatchTime.now().uptimeNanoseconds))
            throw error
        }
        defer { releaseExclusion(&exclusionLease) }

        do {
            try Task.checkCancellation()
            let gateStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await commandGate.prepare(correlationID: correlationID)
            } catch {
                traceContext.recordPrerequisite(
                    from   : gateStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            traceContext.recordPrerequisite(
                from   : gateStart,
                through: DispatchTime.now().uptimeNanoseconds
            )

            guard platform.preparation(for: command) == .internalAppKitState else {
                try await beforeFirstPost()
                let receipt = try engine.post(
                    command,
                    to           : window,
                    correlationID: correlationID,
                    platform     : platform,
                    trace        : &traceContext
                )
                let timed = recordingExclusionWait(
                    on         : receipt,
                    nanoseconds: exclusionLease?.waitingNanoseconds ?? 0
                )
                releaseExclusion(&exclusionLease)
                return complete(timed, traceContext: traceContext)
            }

            let identityStart = DispatchTime.now().uptimeNanoseconds
            let expectedIdentity: WindowIdentity
            do {
                expectedIdentity = try engine.identity(of: window)
            } catch {
                traceContext.recordWindowVerification(
                    from   : identityStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            traceContext.recordWindowVerification(
                from   : identityStart,
                through: DispatchTime.now().uptimeNanoseconds
            )

            let preparationStart = DispatchTime.now().uptimeNanoseconds
            var rollbackTiming: AppKitStatePreparation.RollbackTiming?
            do {
                var resolved = try engine.preparation.participant(for: window)
                try validate(resolved, against: expectedIdentity)
                try engine.preparation.apply(
                    &resolved,
                    rollbackTiming: &rollbackTiming
                )
                participant = resolved
            } catch {
                if let rollbackTiming {
                    traceContext.recordRestoration(
                        from   : rollbackTiming.startedAtNanoseconds,
                        through: rollbackTiming.completedAtNanoseconds
                    )
                }
                traceContext.recordPreparation(
                    from   : preparationStart,
                    through: rollbackTiming?.startedAtNanoseconds
                        ?? DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            traceContext.recordPreparation(
                from   : preparationStart,
                through: DispatchTime.now().uptimeNanoseconds
            )

            let settleStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await Task.sleep(for: platform.preparationSettle(for: command))
            } catch {
                traceContext.recordSettling(
                    from   : settleStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            let settleEnd = DispatchTime.now().uptimeNanoseconds
            traceContext.recordSettling(from: settleStart, through: settleEnd)

            let secondGateStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await commandGate.prepare(correlationID: correlationID)
            } catch {
                traceContext.recordPrerequisite(
                    from   : secondGateStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                throw error
            }
            traceContext.recordPrerequisite(
                from   : secondGateStart,
                through: DispatchTime.now().uptimeNanoseconds
            )

            // This is intentionally the final suspension before `engine.post`.
            // The validator belongs to the seat, which owns the logical modal
            // relation and selection generation. Once it returns, construction
            // and the first post remain synchronous on this driver actor.
            try await beforeFirstPost()
            let receipt = try engine.post(
                command,
                to           : window,
                correlationID: correlationID,
                platform     : platform,
                trace        : &traceContext
            )

            let restoreStart = DispatchTime.now().uptimeNanoseconds
            let cleanup = restoreParticipant(&participant)
            traceContext.recordRestoration(
                from   : restoreStart,
                through: DispatchTime.now().uptimeNanoseconds
            )
            let preparedReceipt = prepared(
                receipt,
                settleNanoseconds: settleEnd &- settleStart
            )
            let timedReceipt = recordingExclusionWait(
                on         : preparedReceipt,
                nanoseconds: exclusionLease?.waitingNanoseconds ?? 0
            )
            releaseExclusion(&exclusionLease)
            return complete(
                timedReceipt.replacingCleanup(cleanup.result),
                traceContext: traceContext
            )
        } catch let primaryCause {
            let hadParticipant = participant != nil
            var cleanup = CleanupAttempt.notRequired
            if hadParticipant {
                let restoreStart = DispatchTime.now().uptimeNanoseconds
                cleanup = restoreParticipant(&participant)
                traceContext.recordRestoration(
                    from   : restoreStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
            }
            releaseExclusion(&exclusionLease)
            recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            guard hadParticipant else { throw primaryCause }
            throw InputPreparationFailure(
                progress    : completedPreparationProgress(cleanup: cleanup.result),
                cause       : primaryCause,
                cleanupCause: cleanup.cause
            )
        }
    }

    /// Applies the Preparation to one window and undoes it at once, posting no
    /// input event of any kind.
    ///
    /// It looks like a Command that does nothing and it is not: the effect is
    /// the **restore**, and the effect is on a target that is running a modal
    /// tracking loop. A contextual menu's loop reads the deactivation record as
    /// an application switch and dismisses the menu on it, measured at 50 ms on
    /// 26A5425a. That is the same property that makes the Preparation harmful
    /// around a right click, and here it is the lever instead of the defect,
    /// which is why one function serves both readings of it.
    ///
    /// It is no more reachable than a prepared click already was: the records
    /// go to the process serial number of the given window's owning connection
    /// and nowhere else, exactly as they do inside `send`, and a caller aiming
    /// this at a window of the User Seat achieves what a prepared click at that
    /// window already achieves, which is that the window briefly believes it is
    /// key inside its own application. `_SLPSSetFrontProcessWithOptions` is
    /// still never called, so the person's frontmost application and Space do
    /// not move.
    ///
    /// A refused restore throws structured progress, unlike the one inside
    /// `send`: no Command events went out here, so the caller receives a failed
    /// cleanup rather than a delivery failure for an already posted Command.
    public func cyclePreparation(on window: WindowReference) async throws {
        guard window.identity != nil else {
            throw InputFailure.windowIdentityUnverified(
                processID   : window.processID,
                windowNumber: window.windowNumber
            )
        }
        // Closing a modal menu is cleanup, not a new input command. Recovery
        // may pause posting without removing this targeted dismissal path.
        let lease: InputTargetExclusion.Lease
        do {
            lease = try await Self.targetExclusion.acquire(processID: window.processID)
        } catch is InputTargetExclusion.Cancellation {
            throw CancellationError()
        }
        defer { Self.targetExclusion.release(lease) }
        try Task.checkCancellation()

        let expectedIdentity = try engine.identity(of: window)
        var participant = try engine.preparation.participant(for: window)
        try validate(participant, against: expectedIdentity)
        try engine.preparation.apply(&participant)
        do {
            try engine.preparation.restore(&participant)
        } catch let primaryCause {
            let cleanup = Self.cleanupResult(for: primaryCause)
            throw InputPreparationFailure(
                progress: InputProgress(
                    completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
                    failedStep                  : .restore,
                    failedStepMayHaveTakenEffect: Self.restoreMayHaveTakenEffect(primaryCause),
                    cleanup                     : cleanup
                ),
                cause       : primaryCause,
                cleanupCause: primaryCause
            )
        }
    }

    /// Posts several Commands under **one** Preparation: prepared once at the
    /// start, restored once at the end, with the settle paid once.
    ///
    /// The Commands are still atomic one by one, and the driver still never
    /// retries one: what a sequence buys is the target's state, which would
    /// otherwise be taken and given back between every keystroke.
    @discardableResult
    public nonisolated func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform = ChromiumPlatform()
    ) async throws -> [InputReceipt] {

        guard !commands.isEmpty else { throw InputFailure.noCommands }
        let traceContexts = commands.map {
            InputTraceIdentity.submitted(
                command      : $0,
                window       : window,
                correlationID: correlationID
            )
        }
        return try await sendSequence(
            commands,
            to           : window,
            correlationID: correlationID,
            platform     : platform,
            traceContexts: traceContexts
        )
    }

    @discardableResult
    public nonisolated func sendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContexts: [InputTraceContext]
    ) async throws -> [InputReceipt] {
        try await performSendSequence(
            commands,
            to           : window,
            correlationID: correlationID,
            platform     : platform,
            traceContexts: traceContexts
        )
    }

    private func performSendSequence(
        _ commands   : [InputCommand],
        to window    : WindowReference,
        correlationID: Int64,
        platform     : any InputPlatform,
        traceContexts suppliedTraceContexts: [InputTraceContext]
    ) async throws -> [InputReceipt] {

        guard !commands.isEmpty else { throw InputFailure.noCommands }
        guard commands.count == suppliedTraceContexts.count else {
            throw InputFailure.noCommands
        }

        var traceContexts = suppliedTraceContexts
        let executionStarted = DispatchTime.now().uptimeNanoseconds
        for index in traceContexts.indices {
            traceContexts[index].beginExecution(at: executionStarted)
        }

        guard window.identity != nil else {
            let failure = InputFailure.windowIdentityUnverified(
                processID   : window.processID,
                windowNumber: window.windowNumber
            )
            let completedAt = DispatchTime.now().uptimeNanoseconds
            for traceContext in traceContexts {
                recordCompletedTrace(traceContext.completed(at: completedAt))
            }
            throw failure
        }

        var rawReceipts: [InputReceipt] = []
        var participant: AppKitStatePreparation.Participant?
        var settleNanoseconds: UInt64 = 0
        var exclusionLease: InputTargetExclusion.Lease?
        let needsPreparation = commands.contains {
            platform.preparation(for: $0) == .internalAppKitState
        }

        do {
            let lease = try await Self.targetExclusion.acquire(processID: window.processID)
            exclusionLease = lease
            for index in traceContexts.indices {
                recordExclusion(lease.wait, in: &traceContexts[index])
            }
        } catch let cancellation as InputTargetExclusion.Cancellation {
            for index in traceContexts.indices {
                recordExclusion(cancellation.wait, in: &traceContexts[index])
            }
            let completedAt = DispatchTime.now().uptimeNanoseconds
            for traceContext in traceContexts {
                recordCompletedTrace(traceContext.completed(at: completedAt))
            }
            throw CancellationError()
        } catch {
            let completedAt = DispatchTime.now().uptimeNanoseconds
            for traceContext in traceContexts {
                recordCompletedTrace(traceContext.completed(at: completedAt))
            }
            throw error
        }
        defer { releaseExclusion(&exclusionLease) }

        do {
            try Task.checkCancellation()
            let gateStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await commandGate.prepare(correlationID: correlationID)
            } catch {
                let gateEnd = DispatchTime.now().uptimeNanoseconds
                for index in traceContexts.indices {
                    traceContexts[index].recordPrerequisite(from: gateStart, through: gateEnd)
                }
                throw error
            }
            let gateEnd = DispatchTime.now().uptimeNanoseconds
            for index in traceContexts.indices {
                traceContexts[index].recordPrerequisite(from: gateStart, through: gateEnd)
            }

            if needsPreparation {
                let identityStart = DispatchTime.now().uptimeNanoseconds
                let expectedIdentity: WindowIdentity
                do {
                    expectedIdentity = try engine.identity(of: window)
                } catch {
                    let identityEnd = DispatchTime.now().uptimeNanoseconds
                    for index in traceContexts.indices {
                        traceContexts[index].recordWindowVerification(
                            from   : identityStart,
                            through: identityEnd
                        )
                    }
                    throw error
                }
                let identityEnd = DispatchTime.now().uptimeNanoseconds
                for index in traceContexts.indices {
                    traceContexts[index].recordWindowVerification(
                        from   : identityStart,
                        through: identityEnd
                    )
                }

                let preparationStart = DispatchTime.now().uptimeNanoseconds
                var rollbackTiming: AppKitStatePreparation.RollbackTiming?
                do {
                    var resolved = try engine.preparation.participant(for: window)
                    try validate(resolved, against: expectedIdentity)
                    try engine.preparation.apply(
                        &resolved,
                        rollbackTiming: &rollbackTiming
                    )
                    participant = resolved
                } catch {
                    let preparationEnd = rollbackTiming?.startedAtNanoseconds
                        ?? DispatchTime.now().uptimeNanoseconds
                    for index in traceContexts.indices {
                        if let rollbackTiming {
                            traceContexts[index].recordRestoration(
                                from   : rollbackTiming.startedAtNanoseconds,
                                through: rollbackTiming.completedAtNanoseconds
                            )
                        }
                        traceContexts[index].recordPreparation(
                            from   : preparationStart,
                            through: preparationEnd
                        )
                    }
                    throw error
                }
                let preparationEnd = DispatchTime.now().uptimeNanoseconds
                for index in traceContexts.indices {
                    traceContexts[index].recordPreparation(
                        from   : preparationStart,
                        through: preparationEnd
                    )
                }

                var requestedSettle = Duration.milliseconds(0)
                for command in commands {
                    requestedSettle = max(
                        requestedSettle,
                        platform.preparationSettle(for: command)
                    )
                }
                let settleStart = DispatchTime.now().uptimeNanoseconds
                do {
                    try await Task.sleep(for: requestedSettle)
                } catch {
                    let settleEnd = DispatchTime.now().uptimeNanoseconds
                    for index in traceContexts.indices {
                        traceContexts[index].recordSettling(from: settleStart, through: settleEnd)
                    }
                    throw error
                }
                let settleEnd = DispatchTime.now().uptimeNanoseconds
                settleNanoseconds = settleEnd &- settleStart
                for index in traceContexts.indices {
                    traceContexts[index].recordSettling(from: settleStart, through: settleEnd)
                }
            }

            for index in commands.indices {
                let commandGateStart = DispatchTime.now().uptimeNanoseconds
                do {
                    try await commandGate.prepare(correlationID: correlationID)
                } catch {
                    traceContexts[index].recordPrerequisite(
                        from   : commandGateStart,
                        through: DispatchTime.now().uptimeNanoseconds
                    )
                    throw error
                }
                traceContexts[index].recordPrerequisite(
                    from   : commandGateStart,
                    through: DispatchTime.now().uptimeNanoseconds
                )
                rawReceipts.append(try engine.post(
                    commands[index],
                    to           : window,
                    correlationID: correlationID,
                    platform     : platform,
                    trace        : &traceContexts[index]
                ))
            }

            let restoreStart = DispatchTime.now().uptimeNanoseconds
            let hadParticipant = participant != nil
            let cleanup = restoreParticipant(&participant)
            let restoreEnd = DispatchTime.now().uptimeNanoseconds
            if hadParticipant {
                for index in traceContexts.indices {
                    traceContexts[index].recordRestoration(from: restoreStart, through: restoreEnd)
                }
            }

            let exclusionWait = exclusionLease?.waitingNanoseconds ?? 0
            releaseExclusion(&exclusionLease)
            let completedAt = DispatchTime.now().uptimeNanoseconds
            return rawReceipts.indices.map { index in
                var receipt = needsPreparation
                    ? prepared(rawReceipts[index], settleNanoseconds: settleNanoseconds)
                    : rawReceipts[index]
                if index == rawReceipts.startIndex {
                    receipt = recordingExclusionWait(on: receipt, nanoseconds: exclusionWait)
                }
                return complete(
                    receipt.replacingCleanup(cleanup.result),
                    traceContext: traceContexts[index],
                    completedAt : completedAt
                )
            }
        } catch let primaryCause {
            let restoreStart = DispatchTime.now().uptimeNanoseconds
            let hadParticipant = participant != nil
            let cleanup = restoreParticipant(&participant)
            let restoreEnd = DispatchTime.now().uptimeNanoseconds
            if hadParticipant {
                for index in traceContexts.indices {
                    traceContexts[index].recordRestoration(from: restoreStart, through: restoreEnd)
                }
            }

            let exclusionWait = exclusionLease?.waitingNanoseconds ?? 0
            releaseExclusion(&exclusionLease)
            let completedAt = DispatchTime.now().uptimeNanoseconds
            let completed = rawReceipts.indices.map { index in
                var receipt = needsPreparation
                    ? prepared(rawReceipts[index], settleNanoseconds: settleNanoseconds)
                    : rawReceipts[index]
                if index == rawReceipts.startIndex {
                    receipt = recordingExclusionWait(on: receipt, nanoseconds: exclusionWait)
                }
                return complete(
                    receipt.replacingCleanup(cleanup.result),
                    traceContext: traceContexts[index],
                    completedAt : completedAt
                )
            }
            for index in rawReceipts.count..<traceContexts.count {
                recordCompletedTrace(traceContexts[index].completed(at: completedAt))
            }

            let progress = hadParticipant
                ? completedPreparationProgress(cleanup: cleanup.result)
                : nil
            guard !completed.isEmpty else {
                guard let progress else { throw primaryCause }
                throw InputPreparationFailure(
                    progress    : progress,
                    cause       : primaryCause,
                    cleanupCause: cleanup.cause
                )
            }
            throw InputSequenceFailure(
                completedReceipts: completed,
                cause            : primaryCause,
                progress         : progress,
                cleanupCause     : cleanup.cause
            )
        }
    }

    /// Confirms that Preparation resolved the same owner connection and process
    /// lifetime that WindowServer attested on the reference.
    private func validate(
        _ participant: AppKitStatePreparation.Participant,
        against expected: WindowIdentity
    ) throws {

        let observed = WindowIdentity(
            process: ProcessIdentity(
                processID       : participant.processID,
                serialNumberHigh: participant.serialNumber.high,
                serialNumberLow : participant.serialNumber.low
            ),
            windowNumber     : Int(participant.windowNumber),
            ownerConnectionID: participant.ownerConnectionID
        )
        guard observed == expected else {
            throw InputFailure.windowIdentityChanged(expected: expected, observed: observed)
        }
    }

    /// The restore, which never fails a send that already posted its events.
    ///
    /// A refused restore leaves the target believing it is active inside its
    /// own process, which is a seat-level anomaly and not a delivery failure:
    /// turning it into a thrown error here would hand the caller an error for a
    /// Command whose events did go out, and a caller that reads an error as
    /// "nothing happened" is exactly how an action gets replayed twice. The
    /// Receipt is the truth about delivery, and it now carries the refusal as a
    /// field so a seat can raise `preparationNotRestored` instead of the fact
    /// living only in the log.
    ///
    /// Returns the structured result and retains the typed cause on failure.
    private func restore(
        _ participant: inout AppKitStatePreparation.Participant
    ) -> CleanupAttempt {
        let processID = participant.processID
        do {
            try engine.preparation.restore(&participant)
            return CleanupAttempt(result: .succeeded, cause: nil)
        } catch let failure as InputFailure {
            if case .restoreFailed(let code) = failure {
                Self.log.error("""
                    preparation restore refused for pid \
                    \(processID, privacy: .public), code \(code, privacy: .public)
                    """)
                return CleanupAttempt(result: Self.cleanupResult(for: failure), cause: failure)
            }
            Self.log.error("preparation restore failed: \(failure, privacy: .public)")
            return CleanupAttempt(result: Self.cleanupResult(for: failure), cause: failure)
        } catch let failure {
            Self.log.error("preparation restore failed: \(failure, privacy: .public)")
            return CleanupAttempt(result: Self.cleanupResult(for: failure), cause: failure)
        }
    }

    /// Maps every failed restore onto the Receipt-safe result while the caller
    /// keeps the original typed failure beside it.
    private static func cleanupResult(for failure: any Error) -> InputCleanupResult {
        guard let inputFailure = failure as? InputFailure,
              case .restoreFailed(let code) = inputFailure else {
            return .failed(code: nil)
        }
        return .failed(code: code)
    }

    /// A nonzero result means the restore record reached the window server but
    /// does not prove whether it changed the target before being refused.
    private static func restoreMayHaveTakenEffect(_ failure: any Error) -> Bool {
        guard let inputFailure = failure as? InputFailure,
              case .restoreFailed = inputFailure else { return false }
        return true
    }

    /// Restores an optional participant once and clears it so an outer failure
    /// path cannot restore the same Preparation a second time.
    private func restoreParticipant(
        _ participant: inout AppKitStatePreparation.Participant?
    ) -> CleanupAttempt {
        guard var resolved = participant else { return .notRequired }
        participant = nil
        return restore(&resolved)
    }

    /// Describes a Preparation that completed before a later refusal. The
    /// progress array is built only on the failure path and does not add that
    /// representation to successful sends.
    private func completedPreparationProgress(
        cleanup: InputCleanupResult
    ) -> InputProgress {
        InputProgress(
            completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
            failedStep                  : nil,
            failedStepMayHaveTakenEffect: false,
            cleanup                     : cleanup
        )
    }

    /// Releases before any trace handler can synchronously submit another send.
    private func releaseExclusion(_ lease: inout InputTargetExclusion.Lease?) {
        guard let held = lease else { return }
        lease = nil
        Self.targetExclusion.release(held)
    }

    /// Records only a real blocked interval. An uncontended acquisition remains
    /// an absent trace stage and reports zero in the Receipt summary.
    private func recordExclusion(
        _ wait       : InputTargetExclusion.Wait?,
        in traceContext: inout InputTraceContext
    ) {
        guard let wait else { return }
        traceContext.recordExclusion(
            from   : wait.startedAtNanoseconds,
            through: wait.completedAtNanoseconds
        )
    }

    /// Completes the immutable trace before publishing it on the Receipt and
    /// through the explicit per-driver handler.
    private func complete(
        _ receipt    : InputReceipt,
        traceContext : InputTraceContext,
        completedAt  : UInt64? = nil
    ) -> InputReceipt {
        let trace = traceContext.completed(
            at: completedAt ?? DispatchTime.now().uptimeNanoseconds
        )
        recordCompletedTrace(trace)
        return receipt.replacingTrace(trace)
    }

    public nonisolated func recordCompletedTrace(_ trace: InputCommandTrace) {
        traceHandler?(trace)
    }

    /// The Receipt of a Command that was posted under a Preparation. The engine
    /// does not know it was prepared, so the two fields that describe it are
    /// filled in here.
    ///
    /// **Every other field has to be carried through by hand.** This rebuilds
    /// the Receipt rather than copying it, so a field added to `InputReceipt`
    /// and not added here silently returns to its default on every prepared
    /// Command, which is every Chromium one. That is how `heldAfter`,
    /// `layoutGeneration` and `textMeasure` were all nil on one family and
    /// right on the other until the text ceiling sweep of ticket B4 noticed.
    private func prepared(_ receipt: InputReceipt, settleNanoseconds: UInt64) -> InputReceipt {
        InputReceipt(
            eventCount : receipt.eventCount,
            route      : receipt.route,
            preparation: .internalAppKitState,
            timing     : InputTiming(
                postingNanoseconds         : receipt.timing.postingNanoseconds,
                settleNanoseconds          : settleNanoseconds,
                exclusionWaitingNanoseconds: receipt.timing.exclusionWaitingNanoseconds
            ),
            trace           : receipt.trace,
            observation     : receipt.observation,
            unvalidatedBuild: receipt.unvalidatedBuild,
            cleanup         : .notAttempted,
            heldAfter       : receipt.heldAfter,
            layoutGeneration: receipt.layoutGeneration,
            textMeasure     : receipt.textMeasure
        )
    }

    /// Adds the one PID queue wait paid by a send or by the first Receipt in a
    /// sequence, without changing delivery, observation or restoration facts.
    private func recordingExclusionWait(
        on receipt    : InputReceipt,
        nanoseconds   : UInt64
    ) -> InputReceipt {
        guard nanoseconds > 0 else { return receipt }
        return InputReceipt(
            eventCount : receipt.eventCount,
            route      : receipt.route,
            preparation: receipt.preparation,
            timing     : InputTiming(
                postingNanoseconds         : receipt.timing.postingNanoseconds,
                settleNanoseconds          : receipt.timing.settleNanoseconds,
                exclusionWaitingNanoseconds: nanoseconds
            ),
            trace           : receipt.trace,
            observation     : receipt.observation,
            unvalidatedBuild: receipt.unvalidatedBuild,
            cleanup         : receipt.cleanup,
            heldAfter       : receipt.heldAfter,
            layoutGeneration: receipt.layoutGeneration,
            textMeasure     : receipt.textMeasure
        )
    }
}
