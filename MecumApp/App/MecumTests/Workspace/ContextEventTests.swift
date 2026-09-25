//
//  ContextEventTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A compaction on `provider` that left `post` tokens of a 1,000 token window.
private func compaction(
    on provider: ModelProvider = .claudeCode,
    post       : Int?          = 120
) -> ContextCompaction {
    ContextCompaction(
        provider     : provider,
        trigger      : .automatic,
        preTokens    : 900,
        postTokens   : post,
        contextWindow: 1_000,
        summary      : nil
    )
}

/// Each row writes context events straight into a real store in its own
/// directory, as `TeamModel` does, and reads back what the ring will show.
@Suite("Compactions and fresh contexts in the record")
struct ContextEventTests {

    private let directory   = TemporaryStore.directory()
    private let workspaceID = UUID()

    @discardableResult
    private func append(
        _ type         : EventType,
        to store       : WorkspaceStore,
        of worker      : UUID,
        in conversation: UUID,
        payload        : Data? = nil,
        version        : Int   = 1
    ) async throws -> RecordedEvent {
        try await store.append(NewEvent(
            workspaceID   : workspaceID,
            subjectID     : conversation,
            conversationID: conversation,
            workerID      : worker,
            type          : type,
            payloadVersion: version,
            payload       : payload
        ))
    }

    @Test func aCompactionAndAFreshContextRoundTripOnTheirConversation() async throws {
        defer { TemporaryStore.discard(directory) }
        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = UUID()
        let conversation = try await store.createConversation(participants: [worker]).id
        let compacted    = ContextCompaction(
            provider     : .ollama,
            trigger      : .manual,
            preTokens    : 3000,
            postTokens   : 200,
            contextWindow: 16_384,
            summary      : "Goals: ship."
        )

        try await store.append(NewEvent(
            workspaceID   : workspaceID,
            subjectID     : conversation,
            conversationID: conversation,
            workerID      : worker,
            type          : .contextCompacted,
            payloadVersion: ContextCompaction.payloadVersion,
            payload       : try compacted.encoded()
        ))
        try await store.append(NewEvent(
            workspaceID   : workspaceID,
            subjectID     : conversation,
            conversationID: conversation,
            workerID      : worker,
            type          : .contextReset
        ))

        let events = try await store.events(matching: EventQuery(scope: .conversation(conversation)))
        #expect(events.map(\.type) == [.contextCompacted, .contextReset])
        #expect(events.allSatisfy { $0.subjectID == conversation && $0.workerID == worker })
        #expect(events.first?.payloadVersion == ContextCompaction.payloadVersion)
        #expect(ContextCompaction.decoded(try #require(events.first?.payload)) == compacted)
        #expect(events.last?.payload == nil)
        #expect(EventType(rawValue: "contextCompacted") == .contextCompacted)
        #expect(EventType(rawValue: "contextReset") == .contextReset)
        for type in [EventType.contextCompacted, .contextReset] {
            #expect(NewEvent(
                workspaceID: workspaceID,
                subjectID  : conversation,
                type       : type
            ).deduplicationKey.hasPrefix(NewEvent.usageKeyPrefix))
        }
    }

    @Test func theContextIsTheCompactionsSizeAfterAndNoneAfterAFreshContext() async throws {
        defer { TemporaryStore.discard(directory) }
        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = UUID()
        let conversation = try await store.createConversation(participants: [worker]).id
        func context(on provider: ModelProvider) async throws -> WorkerUsage.Context? {
            try await store.usage(
                of: worker,
                on: provider,
                in: workspaceID
            ).context
        }
        func turn(_ context: Int) async throws {
            let usage = TurnUsage(
                provider     : .claudeCode,
                model        : "claude-sonnet-5",
                session      : "s1",
                turn         : ProviderUsage.Tokens(
                    input : context - 10,
                    output: 10
                ),
                sessionTotal : nil,
                contextTokens: context,
                contextWindow: 1_000,
                rateLimits   : []
            )
            try await append(
                .turnUsage,
                to     : store,
                of     : worker,
                in     : conversation,
                payload: try usage.encoded(),
                version: TurnUsage.payloadVersion
            )
        }

        try await turn(900)
        #expect(try await context(on: .claudeCode)?.tokens == 900)

        try await append(
            .contextCompacted,
            to     : store,
            of     : worker,
            in     : conversation,
            payload: try compaction().encoded()
        )
        #expect(try await context(on: .claudeCode) == WorkerUsage.Context(
            tokens: 120,
            window: 1_000
        ))
        let usage = try await store.usage(
            of: worker,
            on: .claudeCode,
            in: workspaceID
        )
        #expect(usage.turns == 1, "a compaction is not a turn")
        #expect(usage.lifetime.input == 890)

        // A compaction on another provider leaves this one's context, and one of unknown size hides it.
        try await append(
            .contextCompacted,
            to     : store,
            of     : worker,
            in     : conversation,
            payload: try compaction(on: .codex).encoded()
        )
        #expect(try await context(on: .claudeCode)?.tokens == 120)
        try await append(
            .contextCompacted,
            to     : store,
            of     : worker,
            in     : conversation,
            payload: try compaction(post: nil).encoded()
        )
        #expect(try await context(on: .claudeCode) == nil)

        try await turn(300)
        try await append(
            .contextReset,
            to: store,
            of: worker,
            in: conversation
        )
        #expect(try await context(on: .claudeCode) == nil)
        #expect(try await context(on: .codex) == nil)

        try await turn(40)
        #expect(try await context(on: .claudeCode)?.tokens == 40, "the next turn shows it again")
    }
}
