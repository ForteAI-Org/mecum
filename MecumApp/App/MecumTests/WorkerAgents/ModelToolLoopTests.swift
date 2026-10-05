//
//  ModelToolLoopTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// The history a loop turn is sent, read from the workspace. The loop itself, its rounds, its stop
/// and its compaction are the turn core's, proved in the package's `AgentTurnTests`.
@MainActor
@Suite("The history Mecum's own loop is sent")
struct ModelToolLoopTests {

    @Test func theHistoryIsThePersonAndThisWorkerBeforeTheMessage() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store        = try WorkspaceStore.opening(in: root)
        let worker       = UUID()
        let conversation = try await store.createConversation(participants: [worker]).id
        try await store.appendMessage(
            to  : conversation,
            text: "Open Finder."
        )
        try await store.appendMessage(
            to    : conversation,
            author: worker,
            text  : "Done."
        )
        try await store.appendMessage(
            to    : conversation,
            author: worker,
            text  : "  \n"
        )
        try await store.appendMessage(
            to    : conversation,
            author: UUID(),
            text  : "Someone else."
        )
        let current = try await store.appendMessage(
            to  : conversation,
            text: "And now?"
        )

        let earlier = try await store.messages(
            in    : conversation,
            around: current.sequence,
            before: 40,
            after : 0
        )
        let history = TeamModel.turnHistory(
            earlier,
            by: worker
        )
        #expect(history == [
            TurnMessage(
                role: .user,
                text: "Open Finder."
            ),
            TurnMessage(
                role: .assistant,
                text: "Done."
            ),
        ])
    }

    /// Two messages, a compaction through the loop, a message, a fresh context,
    /// a command line's compaction, and a last message, each a second apart.
    @Test func theHistoryStartsAtTheLastSummaryOrFreshContext() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store        = try WorkspaceStore.opening(in: root)
        let worker       = UUID()
        let conversation = try await store.createConversation(participants: [worker]).id
        let origin       = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func say(
            _ text   : String,
            by author: UUID? = nil,
            at second: Double
        ) async throws {
            try await store.appendMessage(
                to    : conversation,
                author: author,
                text  : text,
                at    : origin.addingTimeInterval(second)
            )
        }
        func record(
            _ type   : EventType,
            _ summary: String?,
            at second: Double
        ) async throws {
            let compaction = ContextCompaction(
                provider     : summary == nil ? .codex : .ollama,
                trigger      : .manual,
                preTokens    : nil,
                postTokens   : nil,
                contextWindow: nil,
                summary      : summary
            )
            try await store.append(NewEvent(
                workspaceID   : UUID(),
                subjectID     : conversation,
                conversationID: conversation,
                workerID      : worker,
                timestamp     : origin.addingTimeInterval(second),
                type          : type,
                payloadVersion: ContextCompaction.payloadVersion,
                payload       : type == .contextCompacted ? try compaction.encoded() : nil
            ))
        }
        func history() async throws -> [TurnMessage] {
            let start = try await store.contextStart(in: conversation)
            return TeamModel.turnHistory(
                try await store.messages(
                    in    : conversation,
                    around: .max,
                    before: 40,
                    after : 0
                ),
                by     : worker,
                since  : start?.date,
                summary: start?.summary
            )
        }

        try await say("Ship the build.", at: 0)
        try await say("On it.", by: worker, at: 1)
        #expect(try await store.contextStart(in: conversation) == nil)
        try await record(.contextCompacted, "Goals: ship.", at: 2)
        try await say("And the notes?", at: 3)
        #expect(try await history() == [
            TurnMessage(
                role: .system,
                text: ModelToolLoop.summaryPreface + "Goals: ship."
            ),
            TurnMessage(
                role: .user,
                text: "And the notes?"
            ),
        ])

        try await record(.contextReset, nil, at: 4)
        // A command line's compaction keeps its own session and leaves the loop's history alone.
        try await record(.contextCompacted, nil, at: 5)
        try await say("Start over.", at: 6)
        #expect(try await history() == [
            TurnMessage(
                role: .user,
                text: "Start over."
            ),
        ])
    }
}
