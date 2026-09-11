//
//  InputCommandTrace.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// InputCommandTrace is one immutable temporal account of one Command.
///
/// `commandID` is unique inside the current process and is deliberately not the
/// fence correlation marker. A Turn may use one correlation marker for several
/// Commands, while every Command still receives one trace of its own.
///
/// Absolute times use the same uptime nanoseconds as `DispatchTime`. Native
/// CoreGraphics event timestamps are retained separately. The driver never
/// rewrites them, because synthetic drag events need the temporal semantics
/// CoreGraphics assigned when each event was constructed.
///
/// Event timestamps alone are not a unique cross-process key. A receiver
/// correlates them with `processID`, `windowNumber`, `correlationID` and the
/// posting interval. Missing or overlapping evidence remains unknown.
public struct InputCommandTrace: Sendable, Equatable {

    public let commandID                   : UInt64
    public let commandKind                 : InputCommandKind
    public let processID                   : Int32
    public let windowNumber                : Int
    public let correlationID               : Int64
    public let submittedAtNanoseconds      : UInt64
    public let executionStartedAtNanoseconds: UInt64?
    public let firstPostAtNanoseconds      : UInt64?
    public let lastPostAtNanoseconds       : UInt64?
    public let completedAtNanoseconds      : UInt64
    public let firstEventTimestamp         : UInt64?
    public let lastEventTimestamp          : UInt64?

    public let queue             : InputTraceStage
    public let exclusion         : InputTraceStage
    public let windowVerification: InputTraceStage
    public let preparation       : InputTraceStage
    public let settling          : InputTraceStage
    public let eventConstruction : InputTraceStage
    public let routing           : InputTraceStage
    public let sending           : InputTraceStage
    public let restoration       : InputTraceStage

    public init(
        commandID                    : UInt64,
        commandKind                  : InputCommandKind,
        processID                    : Int32,
        windowNumber                 : Int,
        correlationID                : Int64,
        submittedAtNanoseconds       : UInt64,
        executionStartedAtNanoseconds: UInt64?,
        firstPostAtNanoseconds       : UInt64?,
        lastPostAtNanoseconds        : UInt64?,
        completedAtNanoseconds       : UInt64,
        firstEventTimestamp          : UInt64?,
        lastEventTimestamp           : UInt64?,
        queue                        : InputTraceStage,
        exclusion                    : InputTraceStage,
        windowVerification           : InputTraceStage,
        preparation                  : InputTraceStage,
        settling                     : InputTraceStage,
        eventConstruction            : InputTraceStage,
        routing                      : InputTraceStage,
        sending                      : InputTraceStage,
        restoration                  : InputTraceStage
    ) {
        self.commandID                     = commandID
        self.commandKind                   = commandKind
        self.processID                     = processID
        self.windowNumber                  = windowNumber
        self.correlationID                 = correlationID
        self.submittedAtNanoseconds        = submittedAtNanoseconds
        self.executionStartedAtNanoseconds = executionStartedAtNanoseconds
        self.firstPostAtNanoseconds        = firstPostAtNanoseconds
        self.lastPostAtNanoseconds         = lastPostAtNanoseconds
        self.completedAtNanoseconds        = completedAtNanoseconds
        self.firstEventTimestamp           = firstEventTimestamp
        self.lastEventTimestamp            = lastEventTimestamp
        self.queue                         = queue
        self.exclusion                     = exclusion
        self.windowVerification            = windowVerification
        self.preparation                   = preparation
        self.settling                      = settling
        self.eventConstruction             = eventConstruction
        self.routing                       = routing
        self.sending                       = sending
        self.restoration                   = restoration
    }
}
