//
//  AttributionFixtures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// AttributionFixtures opens a store with every repository the event-and-attribution path writes
/// through, and builds the events a Watcher, an agent and a verifier would offer, by explicit
/// assignment: no producer here observes, correlates or judges anything.
enum AttributionFixtures {

    static let app = AppContextIdentity(bundleID: "test.fixture.attribution")
    static let t0: Int64 = 1_700_000_000_000

    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let captures: SQLiteCaptureRepository
        let calls: SQLiteAgentCallRepository
        let inputs: SQLiteObservedInputRepository
        let verifications: SQLiteVerificationRepository
        let tasks: SQLiteTaskRepository

        func count(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> Int64 {
            try await store.read { try $0.query(sql, bindings) { $0.integer(0) ?? -1 }.first ?? -1 }
        }

        /// Rows of every table this path may write, to prove a refused write left nothing.
        func ledger() async throws -> [Int64] {
            var counts: [Int64] = []
            for table in ["memory_events", "memory_input_events", "memory_action_correlations", "memory_verifications",
                          "memory_task_occurrences", "memory_task_events", "memory_task_labels", "memory_event_observations", "brain_apps"] {
                counts.append(try await count("SELECT count(*) FROM \(table)"))
            }
            return counts
        }

        /// What the brain holds: none of it moves for an attribution.
        func brainRows() async throws -> [Int64] {
            [try await count("SELECT count(*) FROM brain_evidence"), try await count("SELECT count(*) FROM brain_applications"),
             try await count("SELECT count(*) FROM brain_anchors"), try await count("SELECT count(*) FROM brain_transitions")]
        }

        /// Writes rows as a hand would, for the fixtures a reader must refuse or the references it
        /// must keep; never through the repositories under test.
        func plant(_ statements: [(String, [SQLiteValue])]) async throws {
            try await store.write { transaction in
                for (sql, bindings) in statements { try transaction.execute(sql, bindings) }
            }
        }
    }

    static func open(at url: URL? = nil) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(url: url, store: store, captures: SQLiteCaptureRepository(store: store), calls: SQLiteAgentCallRepository(store: store),
                      inputs: SQLiteObservedInputRepository(store: store), verifications: SQLiteVerificationRepository(store: store),
                      tasks: SQLiteTaskRepository(store: store))
    }

    static func watcherEvent(_ id: String, at ms: Int64 = t0, stream: String = "watcher-1", key: String? = nil,
                             app: AppContextIdentity? = AttributionFixtures.app, monotonicNS: Int64? = nil) -> MemoryEventRecord {
        MemoryEventRecord(eventID: id, source: .watcher, streamID: stream, sourceKey: key, kind: .input, app: app, occurredAtMS: ms,
                          monotonicNS: monotonicNS)
    }

    static func verificationEvent(_ id: String, at ms: Int64 = t0, app: AppContextIdentity? = AttributionFixtures.app) -> MemoryEventRecord {
        MemoryEventRecord(eventID: id, source: .app, streamID: "verifier", kind: .verification, app: app, occurredAtMS: ms)
    }

    static func agentCall(_ id: String, at ms: Int64 = t0, app: AppContextIdentity? = AttributionFixtures.app) throws -> AgentCallRecord {
        try AgentCallRecord(
            event: MemoryEventRecord(eventID: id, source: .app, streamID: "worker-1", traceID: "trace-1", sessionID: "session-1",
                                     kind: .action, app: app, occurredAtMS: ms),
            request: .act(target: "Send", verb: .click, value: nil, section: nil))
    }

    static func click(_ title: String? = "Inbox", sequence: Int64? = 1) throws -> ObservedInput {
        try ObservedInput(kind: .click, sequenceNumber: sequence, targetPID: 412, sourcePID: 77, windowNumber: 9001, windowTitle: title,
                          windowFrame: ScreenFrame(x: 0, y: 25, width: 1440, height: 875), point: ScreenPoint(x: 812.5, y: 433),
                          startedAtNS: 5_000, endedAtNS: 5_900, precedingRevision: 3, revision: 4,
                          beforeStatus: .complete, afterStatus: .partial, difference: .changed)
    }
}

/// The attribution error an operation throws, or nil when it succeeds.
func factError(_ operation: () async throws -> Void) async -> EventFactError? {
    do {
        try await operation()
        return nil
    } catch let error as EventFactError {
        return error
    } catch {
        Issue.record("expected an EventFactError, got \(error)")
        return nil
    }
}
