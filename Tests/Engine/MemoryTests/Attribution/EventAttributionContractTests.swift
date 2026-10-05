//
//  EventAttributionContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The contracts of observed inputs, correlations, verifications and episodes on their own: shapes
/// by kind, ranges and finiteness refused before any store, and the exact comparison.
@Suite("Observed inputs and explicit attributions: the contracts")
struct EventAttributionContractTests {

    private let point = ScreenPoint(x: 812.5, y: 433)

    @Test("each kind keeps its shape: a click, a scroll and a hover have a point, only a scroll a delta, a focus no point, only a gap a range and lost counts and no window or capture")
    func shapes() throws {
        _ = try ObservedInput(kind: .click, sequenceNumber: 7, targetPID: 412, windowNumber: 9001, windowTitle: "Inbox",
                              windowFrame: ScreenFrame(x: 0, y: 25, width: 1440, height: 875), point: point,
                              beforeStatus: .complete, afterStatus: .partial, difference: .changed)
        _ = try ObservedInput(kind: .scroll, point: point, scrollDelta: .init(dx: 0, dy: -3.5))
        _ = try ObservedInput(kind: .hover, point: point)
        _ = try ObservedInput(kind: .focus, targetPID: 412, windowNumber: 9001)
        _ = try ObservedInput(kind: .gap, gap: .init(first: 10, last: .max), lostCritical: .max, lostCoalescible: 0)
        func refused(_ field: String, _ make: () throws -> ObservedInput) {
            #expect(throws: EventFactError.invalidRecord(.shape(field: field))) { _ = try make() }
        }
        refused("point") { try ObservedInput(kind: .click) }
        refused("point") { try ObservedInput(kind: .focus, point: point) }
        refused("delta") { try ObservedInput(kind: .scroll, point: point) }
        refused("delta") { try ObservedInput(kind: .click, point: point, scrollDelta: .init(dx: 1, dy: 1)) }
        refused("gap") { try ObservedInput(kind: .gap) }
        refused("gap") { try ObservedInput(kind: .hover, point: point, gap: .init(first: 1, last: 2)) }
        refused("window") { try ObservedInput(kind: .gap, windowTitle: "W", gap: .init(first: 1, last: 2)) }
        refused("lost") { try ObservedInput(kind: .click, point: point, lostCritical: 1) }
        refused("capture") { try ObservedInput(kind: .gap, gap: .init(first: 1, last: 2), beforeStatus: .complete) }
        refused("difference") { try ObservedInput(kind: .click, point: point, beforeStatus: .complete, difference: .unchanged) }
    }

    @Test("numbers are refused when they are not finite, out of their range or out of order; huge counts are numbers, nothing sized by them")
    func ranges() throws {
        func refused(_ invalidity: EventFactError.Invalidity, _ make: () throws -> ObservedInput) {
            #expect(throws: EventFactError.invalidRecord(invalidity)) { _ = try make() }
        }
        refused(.notFinite) { try ObservedInput(kind: .click, point: ScreenPoint(x: .nan, y: 0)) }
        refused(.notFinite) { try ObservedInput(kind: .scroll, point: point, scrollDelta: .init(dx: .infinity, dy: 0)) }
        refused(.notFinite) { try ObservedInput(kind: .focus, windowFrame: ScreenFrame(x: 0, y: 0, width: -.infinity, height: 1)) }
        refused(.outOfRange(field: "window_frame")) { try ObservedInput(kind: .focus, windowFrame: ScreenFrame(x: 0, y: 0, width: -1, height: 1)) }
        refused(.outOfRange(field: "target_pid")) { try ObservedInput(kind: .focus, targetPID: 0) }
        refused(.outOfRange(field: "source_pid")) { try ObservedInput(kind: .focus, sourcePID: Int64(Int32.max) + 1) }
        refused(.outOfRange(field: "window_number")) { try ObservedInput(kind: .focus, windowNumber: Int64(UInt32.max) + 1) }
        refused(.outOfRange(field: "sequence_number")) { try ObservedInput(kind: .hover, sequenceNumber: -1, point: point) }
        refused(.outOfRange(field: "lost_critical")) { try ObservedInput(kind: .gap, gap: .init(first: 0, last: 0), lostCritical: .min) }
        refused(.outOfOrder(field: "ended_at_ns")) { try ObservedInput(kind: .hover, point: point, startedAtNS: 10, endedAtNS: 9) }
        refused(.outOfOrder(field: "revision")) { try ObservedInput(kind: .hover, point: point, precedingRevision: 4, revision: 3) }
        refused(.outOfOrder(field: "gap_last_sequence")) { try ObservedInput(kind: .gap, gap: .init(first: 5, last: 4)) }
        let huge = try ObservedInput(kind: .gap, gap: .init(first: 0, last: .max), lostCritical: .max, lostCoalescible: .max)
        #expect(huge.gap?.last == .max && huge.lostCritical == .max)
    }

    @Test("the comparison is exact: the title as bytes, absent apart from zero and from empty, −0.0 and +0.0 one coordinate")
    func exactInputs() throws {
        let base = try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: "Café", point: ScreenPoint(x: -0.0, y: 1))
        #expect(base.isExactly(try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: "Caf" + "é", point: ScreenPoint(x: 0.0, y: 1))))
        let variants = [
            try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: "Cafe\u{301}", point: ScreenPoint(x: 0, y: 1)),
            try ObservedInput(kind: .click, sequenceNumber: nil, windowTitle: "Café", point: ScreenPoint(x: 0, y: 1)),
            try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: "", point: ScreenPoint(x: 0, y: 1)),
            try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: nil, point: ScreenPoint(x: 0, y: 1)),
            try ObservedInput(kind: .hover, sequenceNumber: 0, windowTitle: "Café", point: ScreenPoint(x: 0, y: 1)),
            try ObservedInput(kind: .click, sequenceNumber: 0, windowTitle: "Café\u{0}", point: ScreenPoint(x: 0, y: 1)),
        ]
        for variant in variants { #expect(!base.isExactly(variant) && !variant.isExactly(base)) }
    }

    @Test("records name the right events: an input a watcher input, a verification a verification event; a correlation two distinct ids and a finite offset")
    func records() throws {
        func event(_ source: MemoryEventSource, _ kind: MemoryEventKind) -> MemoryEventRecord {
            MemoryEventRecord(eventID: "e", source: source, streamID: "s", kind: kind, occurredAtMS: 1)
        }
        let click = try ObservedInput(kind: .click, point: point)
        _ = try ObservedInputRecord(event: event(.watcher, .input), input: click)
        for wrong in [event(.app, .input), event(.watcher, .action)] {
            #expect(throws: EventFactError.invalidRecord(.notAWatcherInput)) { _ = try ObservedInputRecord(event: wrong, input: click) }
        }
        #expect(throws: EventFactError.invalidRecord(.notAVerification)) {
            _ = try VerificationRecord(event: event(.app, .action), scope: .call, method: .sceneText, verdict: .unknown)
        }
        #expect(throws: EventFactError.invalidRecord(.sameEvent)) { _ = try ActionCorrelation(watcherEventID: "a", agentEventID: "a", basis: .assigned) }
        #expect(throws: EventFactError.invalidRecord(.notFinite)) {
            _ = try ActionCorrelation(watcherEventID: "w", agentEventID: "a", basis: .reported, timeOffsetMS: .nan)
        }
        let composed = try ActionCorrelation(watcherEventID: "w", agentEventID: "a", basis: .reported, timeOffsetMS: -0.0, explanation: "café")
        #expect(composed.isExactly(try ActionCorrelation(watcherEventID: "w", agentEventID: "a", basis: .reported, timeOffsetMS: 0, explanation: "caf" + "é")))
        #expect(!composed.isExactly(try ActionCorrelation(watcherEventID: "w", agentEventID: "a", basis: .reported, timeOffsetMS: 0, explanation: "cafe\u{301}")))
        #expect(!composed.isExactly(try ActionCorrelation(watcherEventID: "w", agentEventID: "a", basis: .reported, timeOffsetMS: nil, explanation: "café")))
    }

    @Test("episodes, memberships and labels refuse what no store should keep: no id, a time out of range or order, a negative position, a confidence that is not finite or outside [0, 1], an empty label or author, a member of another episode")
    func attributions() throws {
        #expect(throws: EventFactError.invalidRecord(.emptyID)) { _ = try TaskOccurrenceRecord(taskOccurrenceID: "", startedAtMS: 0, status: .observed) }
        #expect(throws: EventFactError.invalidRecord(.outOfOrder(field: "ended_at_ms"))) {
            _ = try TaskOccurrenceRecord(taskOccurrenceID: "t", startedAtMS: 10, endedAtMS: 9, status: .completed)
        }
        #expect(throws: EventFactError.invalidRecord(.outOfRange(field: "ms"))) {
            _ = try TaskOccurrenceRecord(taskOccurrenceID: "t", startedAtMS: 1 << 51, status: .observed)
        }
        #expect(throws: EventFactError.invalidRecord(.outOfRange(field: "position"))) {
            _ = try TaskMembership(taskOccurrenceID: "t", eventID: "e", position: -1, role: .context)
        }
        for confidence in [Double.nan, .infinity] {
            #expect(throws: EventFactError.invalidRecord(.notFinite)) {
                _ = try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "x", assignedBy: "fixture", confidence: confidence, status: .candidate, assignedAtMS: 0)
            }
        }
        for confidence in [-0.01, 1.01] {
            #expect(throws: EventFactError.invalidRecord(.outOfRange(field: "confidence"))) {
                _ = try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "x", assignedBy: "fixture", confidence: confidence, status: .candidate, assignedAtMS: 0)
            }
        }
        #expect(throws: EventFactError.invalidRecord(.emptyText(field: "label"))) {
            _ = try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "", assignedBy: "fixture", status: .candidate, assignedAtMS: 0)
        }
        #expect(throws: EventFactError.invalidRecord(.emptyText(field: "assigned_by"))) {
            _ = try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "x", assignedBy: "", status: .candidate, assignedAtMS: 0)
        }
        let unset = try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "x", assignedBy: "fixture", confidence: nil, status: .candidate, assignedAtMS: 0)
        #expect(!unset.isExactly(try TaskLabelRecord(labelID: "l", taskOccurrenceID: "t", label: "x", assignedBy: "fixture", confidence: 0, status: .candidate, assignedAtMS: 0)),
                "no confidence is not zero")
        let episode = try TaskOccurrenceRecord(taskOccurrenceID: "t", startedAtMS: 0, status: .observed)
        #expect(throws: EventFactError.invalidRecord(.otherOccurrence)) {
            _ = try TaskAttribution(occurrence: episode, memberships: [try TaskMembership(taskOccurrenceID: "u", eventID: "e", position: 0, role: .action)])
        }
    }
}
