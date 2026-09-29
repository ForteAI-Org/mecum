//
//  MecumProcess.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
@testable import SQLiteLivingMemory
import Testing

/// MecumProcess is what one `mecum chat` process composes, over an invented window that outlives it:
/// its own SQLite store instance, brain, session, tools and turn cycle over one knowledge directory.
/// Only the application window and the provider are synthetic, the provider being the tool calls a
/// model would make. A new instance over the same directory stands for a restarted `mecum chat`, with
/// nothing shared in memory, but it runs in the same test process: a real restart is the live tier's.
@MainActor
struct MecumProcess {

    let store: SQLiteLivingMemoryStore
    let session: ControlSession
    let tools: AutomationTools
    let cycle: TurnCycle

    init(knowledge: URL, window: ControlSession.Window) throws {
        store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
        let intake = SceneIntake(brain: BrainMemory(store: InMemoryKnowledgeStore(), clock: { Date() }),
                                 livingMemory: store)
        session = ControlSession(intake: intake, window: window)
        tools = AutomationTools(session: session)
        cycle = TurnCycle(tools: tools, livingMemory: store)
    }

    /// One provider turn: the cycle's begin, the model's tool calls, then the cycle's end.
    func turn(
        _ request: String,
        ending   : TurnAdmission.Ending = .completed,
        _ model  : (AutomationTools, JSONValue) async throws -> Void
    ) async throws -> (TurnCycle.Start, TurnCycle.End) {
        let start = try await cycle.begin(request, sessionIsOpen: session.id != nil)
        if session.id == nil { _ = try await tools.call("open_session", .object(["app": .string("Synthetic")])) }
        let id = JSONValue.string(session.id?.uuidString ?? "none")
        _ = try await tools.call("observe", .object(["session": id]))
        try await model(tools, id)
        return (start, try #require(await cycle.end(ending)))
    }

    func experiences() async throws -> [ExperienceRecord] {
        try await store.experiences(in: [session.window.bundleID])
    }

    /// Runs `body` with a knowledge directory inside a temporary root that is removed afterwards.
    static func withKnowledge(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-living-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.appendingPathComponent("Knowledge", isDirectory: true))
    }
}
