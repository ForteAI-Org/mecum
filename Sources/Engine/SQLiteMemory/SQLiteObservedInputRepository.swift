//
//  SQLiteObservedInputRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
import PerceptionCore

/// SQLiteObservedInputRepository is `ObservedInputStoring` over `SQLiteMemoryStore`: a Watcher input's
/// event through the events' codec (`SQLiteEventRows.record`) and its detail in `memory_input_events`,
/// in one write transaction; a stated correlation in `memory_action_correlations`. It observes and
/// correlates nothing on its own, and nothing in production calls it: no Watcher producer exists in
/// this checkout.
public struct SQLiteObservedInputRepository: ObservedInputStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ input: ObservedInputRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            _ = try SQLiteEventRows.record(transaction, input.event)
            let eventID = input.event.eventID
            if let stored = try SQLiteInputRows.detail(transaction, eventID: eventID) {
                guard stored.isExactly(input.input) else {
                    throw SQLiteFactRows.conflict(eventID, stored: "\(stored)", offered: "\(input.input)")
                }
                return .alreadyApplied
            }
            try SQLiteInputRows.insert(transaction, eventID: eventID, input.input)
            return .committed
        }
    }

    public func input(_ eventID: String) async throws -> ObservedInputRecord? {
        try await store.read { snapshot in
            guard let detail = try SQLiteInputRows.detail(snapshot, eventID: eventID),
                  let event = try SQLiteEventRows.read(snapshot, eventID: eventID) else { return nil }
            do {
                return try ObservedInputRecord(event: event, input: detail)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw EventFactError.malformedRow(table: "memory_input_events", id: eventID, malformation: .invalid(invalidity))
            }
        }
    }

    public func record(_ correlation: ActionCorrelation) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let watcher = correlation.watcherEventID, agent = correlation.agentEventID
            let watcherApp = try SQLiteFactRows.event(transaction, watcher, sources: [.watcher], kind: .input, expected: "a watcher input")
            let agentApp = try SQLiteFactRows.event(transaction, agent, sources: [.app, .cli], kind: .action, expected: "an app or cli action")
            if let watcherApp, let agentApp, watcherApp != agentApp {
                throw EventFactError.appMismatch(watcherEventID: watcher, agentEventID: agent)
            }
            if let stored = try SQLiteInputRows.correlation(transaction, watcherEventID: watcher) {
                guard stored.isExactly(correlation) else {
                    throw SQLiteFactRows.conflict(watcher, stored: "\(stored)", offered: "\(correlation)")
                }
                return .alreadyApplied
            }
            try transaction.execute(
                "INSERT INTO memory_action_correlations (watcher_event_id, agent_event_id, basis_kind, time_offset_ms, explanation) VALUES (?, ?, ?, ?, ?)",
                [.text(watcher), .text(agent), .text(correlation.basis.rawValue), correlation.timeOffsetMS.map(SQLiteValue.real) ?? .null,
                 correlation.explanation.map(SQLiteValue.text) ?? .null]
            )
            return .committed
        }
    }

    public func correlation(ofWatcherEvent eventID: String) async throws -> ActionCorrelation? {
        try await store.read { snapshot in try SQLiteInputRows.correlation(snapshot, watcherEventID: eventID) }
    }

    public func correlations(ofAgentEvent eventID: String) async throws -> [ActionCorrelation] {
        try await store.read { snapshot in
            let ids = try snapshot.query(
                """
                SELECT c.watcher_event_id FROM memory_action_correlations c JOIN memory_events e ON e.event_id = c.watcher_event_id
                WHERE c.agent_event_id = ? ORDER BY e.local_order
                """,
                [.text(eventID)]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteInputRows.correlation(snapshot, watcherEventID: $0) }
        }
    }
}

/// SQLiteInputRows is the codec of an input's detail and of a correlation.
enum SQLiteInputRows {

    private static let columns = """
        input_kind, sequence_number, target_pid, source_pid, window_number, window_title, window_x, window_y, window_width,
        window_height, point_x, point_y, delta_x, delta_y, started_at_ns, ended_at_ns, preceding_revision, revision,
        gap_first_sequence, gap_last_sequence, lost_critical, lost_coalescible, before_status, after_status, difference_status
        """

    static func insert(_ transaction: SQLiteTransaction, eventID: String, _ input: ObservedInput) throws {
        func integer(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.integer) ?? .null }
        func real(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.real) ?? .null }
        func text(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
        try transaction.execute(
            "INSERT INTO memory_input_events (event_id, \(columns)) VALUES (\(Array(repeating: "?", count: 26).joined(separator: ", ")))",
            [.text(eventID), .text(input.kind.rawValue), integer(input.sequenceNumber), integer(input.targetPID), integer(input.sourcePID),
             integer(input.windowNumber), text(input.windowTitle), real(input.windowFrame?.x), real(input.windowFrame?.y),
             real(input.windowFrame?.width), real(input.windowFrame?.height), real(input.point?.x), real(input.point?.y),
             real(input.scrollDelta?.dx), real(input.scrollDelta?.dy), integer(input.startedAtNS), integer(input.endedAtNS),
             integer(input.precedingRevision), integer(input.revision), integer(input.gap?.first), integer(input.gap?.last),
             integer(input.lostCritical), integer(input.lostCoalescible), text(input.beforeStatus?.rawValue),
             text(input.afterStatus?.rawValue), text(input.difference?.rawValue)]
        )
    }

    /// The stored detail of an input, or nil, rebuilt through the same validation as a write:
    /// codes this contract knows, pairs and the window frame whole or absent, numbers in range.
    static func detail(_ handle: some SQLiteQuerying, eventID: String) throws -> ObservedInput? {
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
            .malformedRow(table: "memory_input_events", id: eventID, malformation: malformation)
        }
        return try handle.query("SELECT \(columns) FROM memory_input_events WHERE event_id = ?", [.text(eventID)]) { row in
            func code<T: RawRepresentable>(_ index: Int, _ column: String, _ type: T.Type) throws -> T? where T.RawValue == String {
                guard let raw = try row.text(index) else { return nil }
                guard let value = T(rawValue: raw), value.rawValue.utf8.elementsEqual(raw.utf8) else {
                    throw refuse(.unknownCode(column: column, code: raw))
                }
                return value
            }
            func pair(_ a: Int, _ b: Int, _ field: String) throws -> (Double, Double)? {
                switch (row.real(a), row.real(b)) {
                    case (nil, nil)      : return nil
                    case (let x?, let y?): return (x, y)
                    default              : throw refuse(.invalid(.shape(field: field)))
                }
            }
            guard let kind = try code(0, "input_kind", ObservedInputKind.self) else { throw refuse(.invalid(.shape(field: "input_kind"))) }
            let frame: ScreenFrame?
            switch (try pair(6, 7, "window_frame"), try pair(8, 9, "window_frame")) {
                case (nil, nil)              : frame = nil
                case (let origin?, let size?): frame = ScreenFrame(x: origin.0, y: origin.1, width: size.0, height: size.1)
                default                      : throw refuse(.invalid(.shape(field: "window_frame")))
            }
            let gap: ObservedInput.SequenceGap?
            switch (row.integer(18), row.integer(19)) {
                case (nil, nil)             : gap = nil
                case (let first?, let last?): gap = ObservedInput.SequenceGap(first: first, last: last)
                default                     : throw refuse(.invalid(.shape(field: "gap")))
            }
            do {
                return try ObservedInput(
                    kind: kind, sequenceNumber: row.integer(1), targetPID: row.integer(2), sourcePID: row.integer(3),
                    windowNumber: row.integer(4), windowTitle: try row.text(5), windowFrame: frame,
                    point: try pair(10, 11, "point").map { ScreenPoint(x: $0.0, y: $0.1) },
                    scrollDelta: try pair(12, 13, "delta").map { ObservedInput.ScrollDelta(dx: $0.0, dy: $0.1) },
                    startedAtNS: row.integer(14), endedAtNS: row.integer(15), precedingRevision: row.integer(16), revision: row.integer(17),
                    gap: gap, lostCritical: row.integer(20), lostCoalescible: row.integer(21),
                    beforeStatus: try code(22, "before_status", CaptureQuality.Completeness.self),
                    afterStatus: try code(23, "after_status", CaptureQuality.Completeness.self),
                    difference: try code(24, "difference_status", ObservedDifference.self)
                )
            } catch EventFactError.invalidRecord(let invalidity) {
                throw refuse(.invalid(invalidity))
            }
        }.first
    }

    static func correlation(_ handle: some SQLiteQuerying, watcherEventID: String) throws -> ActionCorrelation? {
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
            .malformedRow(table: "memory_action_correlations", id: watcherEventID, malformation: malformation)
        }
        return try handle.query(
            "SELECT watcher_event_id, agent_event_id, basis_kind, time_offset_ms, explanation FROM memory_action_correlations WHERE watcher_event_id = ?",
            [.text(watcherEventID)]
        ) { row in
            let code = try row.text(2) ?? ""
            guard let basis = CorrelationBasis(rawValue: code), basis.rawValue.utf8.elementsEqual(code.utf8) else {
                throw refuse(.unknownCode(column: "basis_kind", code: code))
            }
            do {
                return try ActionCorrelation(watcherEventID: try row.text(0) ?? "", agentEventID: try row.text(1) ?? "", basis: basis,
                                             timeOffsetMS: row.real(3), explanation: try row.text(4))
            } catch EventFactError.invalidRecord(let invalidity) {
                throw refuse(.invalid(invalidity))
            }
        }.first.map { correlation in
            // The reader checks what the writer checks: both events, their roles, and applications
            // that agree when both are known. A row the constraints admit but the writer refuses is
            // malformed, never a valid trace.
            let apps: (Int64?, Int64?)
            do {
                apps = (try SQLiteFactRows.event(handle, correlation.watcherEventID, sources: [.watcher], kind: .input, expected: "a watcher input"),
                        try SQLiteFactRows.event(handle, correlation.agentEventID, sources: [.app, .cli], kind: .action, expected: "an app or cli action"))
            } catch EventFactError.missingEvent, EventFactError.wrongEvent {
                throw refuse(.invalid(.shape(field: "event")))
            }
            if let watcher = apps.0, let agent = apps.1, watcher != agent { throw refuse(.invalid(.appContradiction)) }
            return correlation
        }
    }
}

/// SQLiteFactRows holds what the fact repositories share: the check of the event a detail or an
/// attribution names, and the conflict report.
enum SQLiteFactRows {

    /// The application id of the event, after checking that it exists and has one of the sources and
    /// the kind expected; nil when it names no application.
    static func event(_ handle: some SQLiteQuerying, _ eventID: String, sources: [MemoryEventSource], kind: MemoryEventKind,
                      expected: String) throws -> Int64? {
        guard let row = try handle.query(
            "SELECT source, event_kind, app_id FROM memory_events WHERE event_id = ?", [.text(eventID)],
            { (source: try $0.text(0) ?? "", kind: try $0.text(1) ?? "", app: $0.integer(2)) }
        ).first else {
            throw EventFactError.missingEvent(eventID: eventID)
        }
        guard sources.contains(where: { $0.rawValue == row.source }), row.kind == kind.rawValue else {
            throw EventFactError.wrongEvent(eventID: eventID, expected: expected)
        }
        return row.app
    }

    static func exists(_ handle: some SQLiteQuerying, _ sql: String, _ id: String) throws -> Bool {
        try handle.query(sql, [.text(id)]) { $0.integer(0) ?? 0 }.first.map { $0 > 0 } ?? false
    }

    static func conflict(_ identity: String, stored: String, offered: String) -> MemoryStoreError {
        .identity(MemoryIdentityConflict(identity: identity, storedFingerprint: StructuralDigest.fnv1a(stored),
                                         offeredFingerprint: StructuralDigest.fnv1a(offered)))
    }
}
