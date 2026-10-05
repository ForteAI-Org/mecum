//
//  MemoryTraceReading.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// TraceSummary is one trace as the living memory holds it: its id, how many events and calls it
/// has, the local order of its first and last event (the order the file inserted them, not a causal
/// order across processes), the calendar of its first and last fact as their producers stamped them,
/// and the source and stream of its first event. Read only; nothing in it is derived beyond counts.
public struct TraceSummary: Sendable, Equatable {

    public let traceID: String
    public let events: Int
    public let calls: Int
    public let firstLocalOrder: Int64
    public let lastLocalOrder: Int64
    public let firstOccurredAtMS: Int64
    public let lastOccurredAtMS: Int64
    public let source: MemoryEventSource
    public let streamID: String

    public init(traceID: String, events: Int, calls: Int, firstLocalOrder: Int64, lastLocalOrder: Int64,
                firstOccurredAtMS: Int64, lastOccurredAtMS: Int64, source: MemoryEventSource, streamID: String) {
        self.traceID           = traceID
        self.events            = events
        self.calls             = calls
        self.firstLocalOrder   = firstLocalOrder
        self.lastLocalOrder    = lastLocalOrder
        self.firstOccurredAtMS = firstOccurredAtMS
        self.lastOccurredAtMS  = lastOccurredAtMS
        self.source            = source
        self.streamID          = streamID
    }
}

/// TraceEntry is one event of a trace in local order, with the call it records when it is a call (an
/// `action` event with its row in the calls' table); an observation a session took on its own, with
/// its origin, is an entry without a call.
public struct TraceEntry: Sendable {

    public let localOrder: Int64
    public let event: MemoryEventRecord
    public let call: AgentCall?

    public init(localOrder: Int64, event: MemoryEventRecord, call: AgentCall?) {
        self.localOrder = localOrder
        self.event      = event
        self.call       = call
    }
}

/// MemoryTraceReading is the diagnostic read of the living memory's traces: the traces, most recent
/// first, a page at a time; one trace's events in local order, a page at a time; and the observations
/// whose origin is a given call. It writes nothing, and moves no state: an event left `started`
/// is read as `started`, never completed or failed by the reading.
public protocol MemoryTraceReading: Sendable {

    /// The traces whose last event comes before `localOrder` (all of them when nil), the most recent
    /// first, at most `limit`.
    func traces(before localOrder: Int64?, limit: Int) async throws -> [TraceSummary]

    /// The events of `traceID` after `localOrder` (from the first when nil), in local order, at most `limit`.
    func entries(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [TraceEntry]

    /// The observations recorded with `eventID` as their origin, in local order.
    func observations(originatedBy eventID: String) async throws -> [MemoryEventRecord]
}
