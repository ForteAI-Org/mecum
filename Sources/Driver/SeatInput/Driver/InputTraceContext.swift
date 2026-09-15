//
//  InputTraceContext.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatCore

/// InputTraceWorkKind is how one measured interval spent its time.
nonisolated package enum InputTraceWorkKind {
    case work
    case systemCall
    case intentionalWait
    case schedulingWait
    case unattributed
}

/// InputTraceContext is the value that carries one Command trace across the
/// session and driver actor boundaries. Consumers see its immutable
/// `InputCommandTrace`, never this mutable construction state.
nonisolated public struct InputTraceContext: Sendable {

    package let commandID             : UInt64
    package let commandKind           : InputCommandKind
    package let processID             : Int32
    package let windowNumber          : Int
    package let correlationID         : Int64
    package let submittedAtNanoseconds: UInt64

    package private(set) var executionStartedAtNanoseconds: UInt64?
    package private(set) var firstPostAtNanoseconds: UInt64?
    package private(set) var lastPostAtNanoseconds : UInt64?
    package private(set) var firstEventTimestamp   : UInt64?
    package private(set) var lastEventTimestamp    : UInt64?

    package private(set) var queue              = InputTraceStage()
    package private(set) var exclusion          = InputTraceStage()
    package private(set) var windowVerification = InputTraceStage()
    package private(set) var preparation        = InputTraceStage()
    package private(set) var settling           = InputTraceStage()
    package private(set) var eventConstruction  = InputTraceStage()
    package private(set) var routing            = InputTraceStage()
    package private(set) var sending            = InputTraceStage()
    package private(set) var restoration        = InputTraceStage()

    private var queueStartedAtNanoseconds: UInt64

    package init(
        commandID             : UInt64,
        commandKind           : InputCommandKind,
        processID             : Int32,
        windowNumber          : Int,
        correlationID         : Int64,
        submittedAtNanoseconds: UInt64
    ) {
        self.commandID                     = commandID
        self.commandKind                   = commandKind
        self.processID                     = processID
        self.windowNumber                  = windowNumber
        self.correlationID                 = correlationID
        self.submittedAtNanoseconds        = submittedAtNanoseconds
        self.queueStartedAtNanoseconds     = submittedAtNanoseconds
        self.executionStartedAtNanoseconds = nil
    }

    /// beginExecution closes the queue interval at the first code that runs on
    /// the destination executor. It may be called again when `AgentSeat` hands
    /// the same trace to `InputDriver`, recording both actor waits without
    /// counting the active work between them as queue time.
    package mutating func beginExecution(at now: UInt64) {
        queue = Self.recording(
            queue,
            from       : queueStartedAtNanoseconds,
            through    : now,
            kind       : .schedulingWait,
            allocations: .unknown,
            copies     : .unknown
        )
        if executionStartedAtNanoseconds == nil {
            executionStartedAtNanoseconds = now
        }
    }

    /// beginQueue marks the instant immediately before another actor hop.
    package mutating func beginQueue(at now: UInt64) {
        queueStartedAtNanoseconds = now
    }

    package mutating func recordWindowVerification(from start: UInt64, through end: UInt64) {
        windowVerification = Self.recordingUnknown(
            windowVerification,
            from   : start,
            through: end,
            kind   : .systemCall
        )
    }

    package mutating func recordExclusion(from start: UInt64, through end: UInt64) {
        exclusion = Self.recordingUnknown(
            exclusion,
            from   : start,
            through: end,
            kind   : .schedulingWait
        )
    }

    package mutating func recordPreparation(from start: UInt64, through end: UInt64) {
        preparation = Self.recordingUnknown(
            preparation,
            from   : start,
            through: end,
            kind   : .systemCall
        )
    }

    /// recordPrerequisite keeps an async gate callback out of the OS-call
    /// bucket. The callback may verify, wait and hop executors internally, so
    /// only its opaque wall interval is defensible here.
    package mutating func recordPrerequisite(from start: UInt64, through end: UInt64) {
        preparation = Self.recordingUnknown(
            preparation,
            from   : start,
            through: end,
            kind   : .unattributed
        )
    }

    package mutating func recordSettling(from start: UInt64, through end: UInt64) {
        settling = Self.recordingUnknown(
            settling,
            from   : start,
            through: end,
            kind   : .intentionalWait
        )
    }

    package mutating func recordEventConstruction(
        from start: UInt64,
        through end: UInt64,
        copies     : InputTraceCount
    ) {
        eventConstruction = Self.recording(
            eventConstruction,
            from       : start,
            through    : end,
            kind       : .work,
            allocations: .unknown,
            copies     : copies
        )
    }

    package mutating func recordRouting(from start: UInt64, through end: UInt64) {
        routing = Self.recordingUnknown(routing, from: start, through: end, kind: .systemCall)
    }

    package mutating func recordRoutingWork(from start: UInt64, through end: UInt64) {
        routing = Self.recordingUnknown(routing, from: start, through: end, kind: .work)
    }

    package mutating func recordSendSystemCall(from start: UInt64, through end: UInt64) {
        if firstPostAtNanoseconds == nil { firstPostAtNanoseconds = start }
        lastPostAtNanoseconds = end
        sending = Self.recordingUnknown(sending, from: start, through: end, kind: .systemCall)
    }

    package mutating func recordSendWait(from start: UInt64, through end: UInt64) {
        sending = Self.recordingUnknown(sending, from: start, through: end, kind: .intentionalWait)
    }

    package mutating func recordRestoration(from start: UInt64, through end: UInt64) {
        restoration = Self.recordingUnknown(
            restoration,
            from   : start,
            through: end,
            kind   : .systemCall
        )
    }

    package mutating func recordNativeEventTimestamps(first: UInt64?, last: UInt64?) {
        firstEventTimestamp = first
        lastEventTimestamp  = last
    }

    package func completed(at completedAtNanoseconds: UInt64) -> InputCommandTrace {
        InputCommandTrace(
            commandID                    : commandID,
            commandKind                  : commandKind,
            processID                    : processID,
            windowNumber                 : windowNumber,
            correlationID                : correlationID,
            submittedAtNanoseconds       : submittedAtNanoseconds,
            executionStartedAtNanoseconds: executionStartedAtNanoseconds,
            firstPostAtNanoseconds       : firstPostAtNanoseconds,
            lastPostAtNanoseconds        : lastPostAtNanoseconds,
            completedAtNanoseconds       : completedAtNanoseconds,
            firstEventTimestamp          : firstEventTimestamp,
            lastEventTimestamp           : lastEventTimestamp,
            queue                        : queue,
            exclusion                    : exclusion,
            windowVerification           : windowVerification,
            preparation                  : preparation,
            settling                     : settling,
            eventConstruction            : eventConstruction,
            routing                      : routing,
            sending                      : sending,
            restoration                  : restoration
        )
    }

    private static func recordingUnknown(
        _ stage : InputTraceStage,
        from start: UInt64,
        through end: UInt64,
        kind       : InputTraceWorkKind
    ) -> InputTraceStage {
        recording(
            stage,
            from       : start,
            through    : end,
            kind       : kind,
            allocations: .unknown,
            copies     : .unknown
        )
    }

    private static func recording(
        _ stage : InputTraceStage,
        from start: UInt64,
        through end: UInt64,
        kind       : InputTraceWorkKind,
        allocations: InputTraceCount,
        copies     : InputTraceCount
    ) -> InputTraceStage {
        let duration = end &- start
        let firstMeasurement = !stage.wasPerformed
        return InputTraceStage(
            startedAtNanoseconds      : stage.startedAtNanoseconds ?? start,
            completedAtNanoseconds    : end,
            workNanoseconds           : stage.workNanoseconds
                &+ (kind == .work ? duration : 0),
            systemCallNanoseconds     : stage.systemCallNanoseconds
                &+ (kind == .systemCall ? duration : 0),
            intentionalWaitNanoseconds: stage.intentionalWaitNanoseconds
                &+ (kind == .intentionalWait ? duration : 0),
            schedulingWaitNanoseconds : stage.schedulingWaitNanoseconds
                &+ (kind == .schedulingWait ? duration : 0),
            unattributedNanoseconds    : stage.unattributedNanoseconds
                &+ (kind == .unattributed ? duration : 0),
            allocationCount           : firstMeasurement
                ? allocations : merge(stage.allocationCount, allocations),
            copyCount                 : firstMeasurement
                ? copies : merge(stage.copyCount, copies)
        )
    }

    private static func merge(
        _ left : InputTraceCount,
        _ right: InputTraceCount
    ) -> InputTraceCount {
        guard case .known(let leftValue) = left,
              case .known(let rightValue) = right
        else { return .unknown }
        return .known(leftValue + rightValue)
    }
}
