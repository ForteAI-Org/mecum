//
//  AgentCallFixtures.swift
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

/// AgentCallFixtures opens a store with the call repository and the capture repository on it, and
/// builds call records the way a producer will: one source, stream, trace and session per test, an
/// application, and event ids the producer chose.
enum AgentCallFixtures {

    static let app     = AppContextIdentity(bundleID: "test.fixture.calls")
    static let session = "5D0C2F2E-0000-4000-8000-000000000001"
    static let t0: Int64 = 1_700_000_000_000

    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let calls: SQLiteAgentCallRepository
        let captures: SQLiteCaptureRepository

        func count(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> Int64 {
            try await store.read { try $0.query(sql, bindings) { $0.integer(0) ?? -1 }.first ?? -1 }
        }

        /// Every row the call tables and the events hold, to prove a refused write left nothing.
        func ledger() async throws -> [Int64] {
            [try await count("SELECT count(*) FROM memory_events"), try await count("SELECT count(*) FROM memory_agent_actions"),
             try await count("SELECT count(*) FROM memory_operation_arguments"), try await count("SELECT count(*) FROM brain_apps")]
        }
    }

    static func open(at url: URL? = nil) async throws -> Memory {
        let url   = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(url: url, store: store, calls: SQLiteAgentCallRepository(store: store), captures: SQLiteCaptureRepository(store: store))
    }

    static func event(_ id: String, at ms: Int64 = t0, session: String? = AgentCallFixtures.session,
                      parent: String? = nil, position: Int? = nil, app: AppContextIdentity? = AgentCallFixtures.app,
                      key: String? = nil) -> MemoryEventRecord {
        MemoryEventRecord(eventID: id, source: .app, streamID: "worker-1", sourceKey: key, traceID: "trace-1",
                          sessionID: session, parentEventID: parent, parentPosition: position, kind: .action, app: app,
                          occurredAtMS: ms)
    }

    static func call(_ id: String, _ request: AgentCallRequest, at ms: Int64 = t0, session: String? = AgentCallFixtures.session,
                     app: AppContextIdentity? = AgentCallFixtures.app) throws -> AgentCallRecord {
        try AgentCallRecord(event: event(id, at: ms, session: session, app: app), request: request)
    }

    /// The batch `id` and one step per request, each a child at its position.
    static func batch(_ id: String, _ requests: [AgentCallRequest], at ms: Int64 = t0) throws -> (AgentCallRecord, [AgentCallRecord]) {
        let parent = try AgentCallRecord(event: event(id, at: ms), request: .batch)
        let steps = try requests.enumerated().map { position, request in
            try AgentCallRecord(event: event("\(id).\(position)", at: ms + Int64(position) + 1, parent: id, position: position),
                                request: request)
        }
        return (parent, steps)
    }

    /// The seven step variants a batch may hold.
    static let sevenSteps: [AgentCallRequest] = [
        .act(target: "Wi-Fi", verb: .setToggle, value: .on, section: "Network"),
        .select(control: "Format", item: "H.264"),
        .typeText(target: "To", text: "Zoë", section: nil, replace: false),
        .pressKey(key: .character("s"), modifiers: [.cmd], count: 1),
        .scroll(direction: .down, lines: 3, target: nil, section: nil),
        .drag(from: "Clip", to: .offset(dx: 40, dy: 0), section: "Timeline"),
        .contextMenu(target: "Paragraph", item: "Copy", section: nil),
    ]

    static func ended(_ status: AgentCallStatus, _ result: AgentCallResult? = nil, at ms: Int64 = t0 + 100) -> AgentCallProgress {
        AgentCallProgress(status, result: result, endedAtMS: ms)
    }

    static func outcome(_ kind: ActOutcomeKind, _ message: String = "said") -> AgentCallProgress {
        ended(.completed, .outcome(kind, message: message))
    }
}

/// The call error an operation throws, or nil when it succeeds.
func callError(_ operation: () async throws -> Void) async -> AgentCallError? {
    do {
        try await operation()
        return nil
    } catch let error as AgentCallError {
        return error
    } catch {
        Issue.record("expected an AgentCallError, got \(error)")
        return nil
    }
}
