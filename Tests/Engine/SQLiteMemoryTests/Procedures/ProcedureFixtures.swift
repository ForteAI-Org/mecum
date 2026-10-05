//
//  ProcedureFixtures.swift
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

/// ProcedureFixtures opens a store with every repository the procedure, occurrence and experience
/// paths write through, and gives each test what its references need: anchors the brain's
/// projection learned, a menu command, a structural scene. Definitions are written by hand.
enum ProcedureFixtures {

    static let mail  = "com.apple.mail"
    static let notes = "com.apple.Notes"
    static let t0: Int64 = 1_700_000_000_000

    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let routes: SQLiteRouteRepository
        let steps: SQLiteStepOccurrenceRepository
        let experiences: SQLiteExperienceRepository
        let brain: SQLiteBrainRepository
        let menus: SQLiteMenuCommandRepository
        let tasks: SQLiteTaskRepository
        let verifications: SQLiteVerificationRepository
        let inputs: SQLiteObservedInputRepository
        let captures: SQLiteCaptureRepository
        let calls: SQLiteAgentCallRepository

        func count(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> Int64 {
            try await store.read { try $0.query(sql, bindings) { $0.integer(0) ?? -1 }.first ?? -1 }
        }

        func texts(_ sql: String, _ bindings: [SQLiteValue] = []) async throws -> [String] {
            try await store.read { try $0.query(sql, bindings) { try $0.text(0) ?? "NULL" } }
        }

        /// Rows of every definition table, to prove a refused write left nothing.
        func ledger() async throws -> [Int64] {
            var counts: [Int64] = []
            for table in ["memory_routes", "memory_route_parameters", "memory_route_steps", "memory_step_checks", "memory_step_operations",
                          "memory_operation_arguments", "memory_route_call_bindings", "memory_experiences", "memory_experience_bindings"] {
                counts.append(try await count("SELECT count(*) FROM \(table)"))
            }
            return counts
        }

        func plant(_ sql: String, _ bindings: [SQLiteValue] = []) async throws {
            try await store.write { try $0.execute(sql, bindings) }
        }

        /// The anchor the projection gave a label, after an ingest of these labels.
        func anchor(_ label: String, in bundle: String) async throws -> String {
            try #require(try await brain.brain(of: bundle)?.objects.first { $0.label == label }).anchorKey
        }
    }

    static func open(at url: URL? = nil) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(url: url, store: store, routes: SQLiteRouteRepository(store: store), steps: SQLiteStepOccurrenceRepository(store: store),
                      experiences: SQLiteExperienceRepository(store: store), brain: SQLiteBrainRepository(store: store),
                      menus: SQLiteMenuCommandRepository(store: store), tasks: SQLiteTaskRepository(store: store),
                      verifications: SQLiteVerificationRepository(store: store), inputs: SQLiteObservedInputRepository(store: store),
                      captures: SQLiteCaptureRepository(store: store), calls: SQLiteAgentCallRepository(store: store))
    }

    /// A store where Mail has the anchors Send and To, the menu command m-copy and the structural
    /// scene scene-compose, and Notes has the anchor Title.
    static func prepared() async throws -> Memory {
        let memory = try await open()
        func controls(_ labels: [String]) -> [BrainDetection] {
            labels.enumerated().map { BrainDetection(kind: .control, label: $1, bounds: NormalizedRect(x: 0.5, y: 0.1 + 0.05 * Double($0), width: 0.03, height: 0.017)) }
        }
        _ = try await memory.brain.ingest(controls(["Send", "To"]), into: mail, now: Date(timeIntervalSince1970: 1_700_000_000), window: nil)
        _ = try await memory.brain.ingest(controls(["Title"]), into: notes, now: Date(timeIntervalSince1970: 1_700_000_000), window: nil)
        _ = try await memory.menus.record(try MenuCommandRecord(menuCommandID: "m-copy", bundleID: mail, path: ["Edit", "Copy"], topLevelTitle: "Edit",
                                                                identifier: nil, hasSubmenu: false, enabled: true, markChar: nil, cmdChar: "C",
                                                                firstSeenMS: t0, lastSeenMS: t0))
        try await memory.plant("INSERT INTO brain_scenes (scene_id, app_id, title_bucket, scene_kind, first_seen_ms, last_seen_ms) SELECT 'scene-compose', app_id, 'compose', 'window', 0, 0 FROM brain_apps WHERE bundle_id = ?",
                               [.text(mail)])
        return memory
    }

    static let message = RouteParameter(parameterID: "p-message", name: "message", direction: .input, valueType: .text, isRequired: true)
    static let recipient = RouteParameter(parameterID: "p-recipient", name: "recipient", direction: .input, valueType: .text, isRequired: false)
    static let sent = RouteParameter(parameterID: "p-sent", name: "sent", direction: .output, valueType: .boolean, isRequired: false)

    static func textCheck(_ id: String, _ text: String = "Inviato", position: Int = 0) -> StepCheck {
        StepCheck(checkID: id, position: position, kind: .text, expected: .text(text), comparison: .contains)
    }

    /// A one-goal Route: one check, no operation.
    static func oneGoal(_ id: String = "r-one", name: String = "Già inviato") -> RouteDefinition {
        RouteDefinition(routeID: id, name: name, createdAtMS: t0, steps: [
            ProcedureStep(stepID: "\(id).s0", position: 0, goalText: "Il messaggio risulta inviato", checks: [textCheck("\(id).c0")]),
        ])
    }
}

/// The route error an operation throws, or nil when it succeeds.
func routeError(_ operation: () async throws -> Void) async -> RouteError? {
    do {
        try await operation()
        return nil
    } catch let error as RouteError {
        return error
    } catch {
        Issue.record("expected a RouteError, got \(error)")
        return nil
    }
}
