//
//  ObservedInput.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import PerceptionCore

/// ObservedInputKind is what a Watcher input event records: a gesture the person made (a click, a
/// scroll, a hover, a change of focus) or a gap, a stretch of the Watcher's stream it lost. These
/// codes are this contract's proposal: no Watcher producer exists in this checkout, so none was
/// matched against a live report. A gap is never a gesture.
public enum ObservedInputKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case click, scroll, hover, focus, gap
}

/// ObservedDifference is what a producer found comparing the captures before and after an input.
public enum ObservedDifference: String, Sendable, Equatable, Hashable, CaseIterable {
    case changed, unchanged, unknown
}

/// ScreenPoint is a point in global display coordinates, in points, as Quartz reports them: the
/// origin at the top left of the main display, `y` growing down. It is not a `NormalizedRect`.
public struct ScreenPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// ScreenFrame is a window's frame in the same global display points.
public struct ScreenFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x      = x
        self.y      = y
        self.width  = width
        self.height = height
    }
}

/// ObservedInput is the detail of one Watcher input event, as far as the schema keeps it. Every
/// field is a fact or a hint, never an identity: a process id, a window number and a point name
/// nothing beyond the moment they were seen. An absent measure is nil, never zero.
///
/// - `sequenceNumber`: the input's place in its stream, when the producer numbers it.
/// - `targetPID`, `sourcePID`: the process the input went to and the one that posted it.
/// - `windowNumber`, `windowTitle`, `windowFrame`: the window under the input as WindowServer
///   reported it; the frame whole or not at all.
/// - `point`: where a click, a scroll or a hover happened; `scrollDelta` (`dx`, `dy`): the wheel's
///   movement in points, as the producer reported it, with `dy` positive upward.
/// - `startedAtNS`, `endedAtNS`: the gesture's span on the monotonic clock of the event's
///   `monotonicNS`, the end not before the start.
/// - `precedingRevision`, `revision`: the producer's scene revisions around the input.
/// - `gap` (`first ... last`) and `lostCritical`, `lostCoalescible`: for a gap only, the sequence
///   numbers lost and how many lost reports were critical or coalescible.
/// - `beforeStatus`, `afterStatus`: the completeness of the captures taken around the input, nil
///   when none was taken; `difference`: what comparing them found, only when both exist.
///
/// Shapes by kind: a click, a scroll and a hover carry a point, a scroll its delta, and a focus no
/// point; only a gap carries a gap range and lost counts, and a gap carries no window, point,
/// delta or capture status. The type has no `==`: records are compared with `isExactly(_:)`.
public struct ObservedInput: Sendable {

    public struct SequenceGap: Sendable, Equatable {
        public let first: Int64
        public let last: Int64

        public init(first: Int64, last: Int64) {
            self.first = first
            self.last  = last
        }
    }

    public struct ScrollDelta: Sendable, Equatable {
        public let dx: Double
        public let dy: Double

        public init(dx: Double, dy: Double) {
            self.dx = dx
            self.dy = dy
        }
    }

    public let kind: ObservedInputKind
    public let sequenceNumber: Int64?
    public let targetPID: Int64?
    public let sourcePID: Int64?
    public let windowNumber: Int64?
    public let windowTitle: String?
    public let windowFrame: ScreenFrame?
    public let point: ScreenPoint?
    public let scrollDelta: ScrollDelta?
    public let startedAtNS: Int64?
    public let endedAtNS: Int64?
    public let precedingRevision: Int64?
    public let revision: Int64?
    public let gap: SequenceGap?
    public let lostCritical: Int64?
    public let lostCoalescible: Int64?
    public let beforeStatus: CaptureQuality.Completeness?
    public let afterStatus: CaptureQuality.Completeness?
    public let difference: ObservedDifference?

    /// An input refused when no store should keep it: a shape its kind does not have, a number that
    /// is not finite, a process id outside 1 ... `Int32.max`, a window number outside 0 ...
    /// `UInt32.max`, a negative sequence, revision, gap bound or count, an end before its start, a
    /// revision before the preceding one, a gap whose last is before its first, a frame of negative
    /// size, a difference without both captures.
    public init(
        kind             : ObservedInputKind,
        sequenceNumber   : Int64? = nil,
        targetPID        : Int64? = nil,
        sourcePID        : Int64? = nil,
        windowNumber     : Int64? = nil,
        windowTitle      : String? = nil,
        windowFrame      : ScreenFrame? = nil,
        point            : ScreenPoint? = nil,
        scrollDelta      : ScrollDelta? = nil,
        startedAtNS      : Int64? = nil,
        endedAtNS        : Int64? = nil,
        precedingRevision: Int64? = nil,
        revision         : Int64? = nil,
        gap              : SequenceGap? = nil,
        lostCritical     : Int64? = nil,
        lostCoalescible  : Int64? = nil,
        beforeStatus     : CaptureQuality.Completeness? = nil,
        afterStatus      : CaptureQuality.Completeness? = nil,
        difference       : ObservedDifference? = nil
    ) throws {
        func refuse(_ invalidity: EventFactError.Invalidity) -> EventFactError { .invalidRecord(invalidity) }
        let gesture = kind != .gap
        let pointed = kind == .click || kind == .scroll || kind == .hover
        if pointed != (point != nil) { throw refuse(.shape(field: "point")) }
        if (kind == .scroll) != (scrollDelta != nil) { throw refuse(.shape(field: "delta")) }
        if (kind == .gap) != (gap != nil) { throw refuse(.shape(field: "gap")) }
        if !gesture, windowNumber != nil || windowTitle != nil || windowFrame != nil || targetPID != nil || sourcePID != nil {
            throw refuse(.shape(field: "window"))
        }
        if gesture, lostCritical != nil || lostCoalescible != nil { throw refuse(.shape(field: "lost")) }
        if !gesture, beforeStatus != nil || afterStatus != nil || difference != nil { throw refuse(.shape(field: "capture")) }
        if difference != nil, beforeStatus == nil || afterStatus == nil { throw refuse(.shape(field: "difference")) }
        let reals = [point?.x, point?.y, scrollDelta?.dx, scrollDelta?.dy, windowFrame?.x, windowFrame?.y, windowFrame?.width,
                     windowFrame?.height].compactMap { $0 }
        if !reals.allSatisfy(\.isFinite) { throw refuse(.notFinite) }
        if let frame = windowFrame, frame.width < 0 || frame.height < 0 { throw refuse(.outOfRange(field: "window_frame")) }
        for (field, pid) in [("target_pid", targetPID), ("source_pid", sourcePID)] {
            if let pid, !(1...Int64(Int32.max)).contains(pid) { throw refuse(.outOfRange(field: field)) }
        }
        if let windowNumber, !(0...Int64(UInt32.max)).contains(windowNumber) { throw refuse(.outOfRange(field: "window_number")) }
        let counts: [(String, Int64?)] = [("sequence_number", sequenceNumber), ("started_at_ns", startedAtNS), ("ended_at_ns", endedAtNS),
                                          ("preceding_revision", precedingRevision), ("revision", revision),
                                          ("gap_first_sequence", gap?.first), ("gap_last_sequence", gap?.last),
                                          ("lost_critical", lostCritical), ("lost_coalescible", lostCoalescible)]
        for (field, value) in counts { if let value, value < 0 { throw refuse(.outOfRange(field: field)) } }
        if let started = startedAtNS, let ended = endedAtNS, ended < started { throw refuse(.outOfOrder(field: "ended_at_ns")) }
        if let preceding = precedingRevision, let revision, revision < preceding { throw refuse(.outOfOrder(field: "revision")) }
        if let gap, gap.last < gap.first { throw refuse(.outOfOrder(field: "gap_last_sequence")) }
        self.kind              = kind
        self.sequenceNumber    = sequenceNumber
        self.targetPID         = targetPID
        self.sourcePID         = sourcePID
        self.windowNumber      = windowNumber
        self.windowTitle       = windowTitle
        self.windowFrame       = windowFrame
        self.point             = point
        self.scrollDelta       = scrollDelta
        self.startedAtNS       = startedAtNS
        self.endedAtNS         = endedAtNS
        self.precedingRevision = precedingRevision
        self.revision          = revision
        self.gap               = gap
        self.lostCritical      = lostCritical
        self.lostCoalescible   = lostCoalescible
        self.beforeStatus      = beforeStatus
        self.afterStatus       = afterStatus
        self.difference        = difference
    }

    /// Whether the other input is this one exactly: every field, the title byte for byte, absent
    /// apart from zero and from empty text, numbers as IEEE values (`-0.0` and `0.0` are one).
    public func isExactly(_ other: ObservedInput) -> Bool {
        kind == other.kind && sequenceNumber == other.sequenceNumber && targetPID == other.targetPID && sourcePID == other.sourcePID
            && windowNumber == other.windowNumber && EventFactText.same(windowTitle, other.windowTitle) && windowFrame == other.windowFrame
            && point == other.point && scrollDelta == other.scrollDelta && startedAtNS == other.startedAtNS && endedAtNS == other.endedAtNS
            && precedingRevision == other.precedingRevision && revision == other.revision && gap == other.gap
            && lostCritical == other.lostCritical && lostCoalescible == other.lostCoalescible && beforeStatus == other.beforeStatus
            && afterStatus == other.afterStatus && difference == other.difference
    }
}

/// ObservedInputRecord is a Watcher input event as a producer or a fixture offers it: the event, a
/// `watcher` `input`, and its detail.
public struct ObservedInputRecord: Sendable {

    public let event: MemoryEventRecord
    public let input: ObservedInput

    public init(event: MemoryEventRecord, input: ObservedInput) throws {
        try event.validate()
        guard event.source == .watcher, event.kind == .input else { throw EventFactError.invalidRecord(.notAWatcherInput) }
        self.event = event
        self.input = input
    }
}

/// CorrelationBasis is why a Watcher input is linked to an agent's call, as the caller states it:
/// `reported`, the input's producer reported the call it came from; `assigned`, a person or a
/// fixture assigned it. Both are this contract's proposals; no algorithm infers either, and a
/// process id or a time close by is neither.
public enum CorrelationBasis: String, Sendable, Equatable, Hashable, CaseIterable {
    case reported, assigned
}

/// ActionCorrelation links one Watcher input to the agent call it is said to come from. It is an
/// attribution, not a second observation: it confirms nothing, proves no effect and moves no count.
/// `timeOffsetMS` is the input's time minus the call's (positive: the input came later), nil when
/// unknown. The type has no `==`: correlations are compared with `isExactly(_:)`.
public struct ActionCorrelation: Sendable {

    public let watcherEventID: String
    public let agentEventID: String
    public let basis: CorrelationBasis
    public let timeOffsetMS: Double?
    public let explanation: String?

    public init(watcherEventID: String, agentEventID: String, basis: CorrelationBasis, timeOffsetMS: Double? = nil,
                explanation: String? = nil) throws {
        if watcherEventID.isEmpty || agentEventID.isEmpty { throw EventFactError.invalidRecord(.emptyID) }
        if watcherEventID.utf8.elementsEqual(agentEventID.utf8) { throw EventFactError.invalidRecord(.sameEvent) }
        if let timeOffsetMS, !timeOffsetMS.isFinite { throw EventFactError.invalidRecord(.notFinite) }
        self.watcherEventID = watcherEventID
        self.agentEventID   = agentEventID
        self.basis          = basis
        self.timeOffsetMS   = timeOffsetMS
        self.explanation    = explanation
    }

    public func isExactly(_ other: ActionCorrelation) -> Bool {
        watcherEventID.utf8.elementsEqual(other.watcherEventID.utf8) && agentEventID.utf8.elementsEqual(other.agentEventID.utf8)
            && basis == other.basis && timeOffsetMS == other.timeOffsetMS && EventFactText.same(explanation, other.explanation)
    }
}

/// EventFactText compares optional texts as the file keeps them: byte for byte, nil apart from empty.
enum EventFactText {
    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
            case (nil, nil)       : true
            case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
            default               : false
        }
    }
}
