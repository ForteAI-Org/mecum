//
//  WorkerUsageTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Mecum

private let fiveHours = ProviderUsage.RateLimit(
    window      : "five_hour",
    usedFraction: 0.13,
    resetsAt    : Date(timeIntervalSince1970: 1_790_359_800)
)

private let sevenDays = ProviderUsage.RateLimit(
    window      : "seven_day",
    usedFraction: 0.79,
    resetsAt    : Date(timeIntervalSince1970: 1_790_506_800)
)

/// A turn's usage as the host reports it, on Claude's Opus unless another
/// provider and model are named.
private func usage(
    input   : Int,
    cached  : Int                       = 0,
    output  : Int,
    context : Int?,
    window  : Int?                      = 1_000_000,
    limits  : [ProviderUsage.RateLimit] = [],
    provider: ModelProvider             = .claudeCode,
    model   : String                    = "claude-opus-5"
) -> TurnUsage {
    TurnUsage(
        provider     : provider,
        model        : model,
        session      : "session-\(provider.rawValue)",
        turn         : ProviderUsage.Tokens(
            input     : input,
            cacheReads: cached,
            output    : output
        ),
        sessionTotal : nil,
        contextTokens: context,
        contextWindow: window,
        rateLimits   : limits
    )
}

/// Each row records turns through the recorder into a real store in its own
/// directory, then reads back what the inspector and the composer will show.
@MainActor
@Suite("What a worker's turns used")
struct WorkerUsageTests {

    private let directory   = TemporaryStore.directory()
    private let workspaceID = UUID()

    /// Records one turn by `worker` on the provider and model `reported` names,
    /// in the worker's one conversation.
    @discardableResult
    private func record(
        _ reported: TurnUsage,
        by worker : UUID,
        in store  : WorkspaceStore
    ) async throws -> WorkerTurnRecorder.Ending {
        try await store.configure(
            worker   : worker,
            selection: ModelSelection(
                provider: reported.provider,
                model   : reported.model ?? "",
                effort  : .low
            )
        )
        var conversation = try await store.conversations().first { $0.participantIDs == [worker] }?.id
        if conversation == nil { conversation = try await store.createConversation(participants: [worker]).id }
        let conversationID = try #require(conversation)

        let message = try await store.appendMessage(
            to  : conversationID,
            text: "Say ok."
        )
        let recorder = WorkerTurnRecorder(
            store         : store,
            workspaceID   : workspaceID,
            workerID      : worker,
            conversationID: conversationID,
            messageID     : message.id
        ) {}
        return try await recorder.run { _, _, emit in
            emit(.provider(.assistant("ok")))
            emit(.provider(.completed))
            emit(.usage(reported))
        }
    }

    private func worker(
        _ name  : String,
        in store: WorkspaceStore
    ) async throws -> UUID {
        try await store.createWorker(
            name      : name,
            appearance: TemporaryStore.appearance()
        ).id
    }

    @Test func aTurnsUsageIsOneEventOnItsExecutionAndReadsBackWhole() async throws {
        defer { TemporaryStore.discard(directory) }
        let store    = try WorkspaceStore.opening(in: directory)
        let nova     = try await worker(
            "Nova",
            in: store
        )
        let reported = usage(
            input  : 3557,
            output : 4,
            context: 3561,
            limits : [fiveHours, sevenDays]
        )

        let ending = try await record(
            reported,
            by: nova,
            in: store
        )
        #expect(ending == .completed)

        let events = try await store.events(matching: EventQuery(scope: .worker(nova)))
        #expect(events.map(\.type) == [.executionStarted, .turnUsage, .executionCompleted])
        let recorded = try #require(events.first { $0.type == .turnUsage })
        #expect(recorded.subjectID == events.first?.subjectID, "on the turn's execution")
        #expect(recorded.payloadVersion == TurnUsage.payloadVersion)
        #expect(TurnUsage.decoded(try #require(recorded.payload)) == reported)
        #expect(EventType(rawValue: "turnUsage") == .turnUsage)
    }

    @Test func theLifetimeAddsUpEveryTurnAndSplitsItByModel() async throws {
        defer { TemporaryStore.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let nova   = try await worker(
            "Nova",
            in: store
        )
        let first  = usage(
            input  : 3557,
            output : 4,
            context: 3561
        )
        let second = usage(
            input  : 3600,
            cached : 3555,
            output : 40,
            context: 3640
        )
        let third  = usage(
            input   : 16357,
            cached  : 16128,
            output  : 39,
            context : 16396,
            window  : 258_400,
            provider: .codex,
            model   : "gpt-5.6-luna"
        )
        for reported in [first, second, third] {
            try await record(
                reported,
                by: nova,
                in: store
            )
        }

        let onCodex = try await store.usage(
            of: nova,
            on: .codex,
            in: workspaceID
        )
        #expect(onCodex.turns == 3)
        #expect(onCodex.lifetime == ProviderUsage.Tokens(
            input     : 3557 + 3600 + 16357,
            cacheReads: 3555 + 16128,
            output    : 4 + 40 + 39
        ))
        #expect(onCodex.byModel == [
            "claude-opus-5": first.turn + second.turn,
            "gpt-5.6-luna" : third.turn,
        ])
        #expect(onCodex.lastTurn == third)
        #expect(onCodex.context == WorkerUsage.Context(
            tokens: 16396,
            window: 258_400
        ))

        // Back on Claude, the context is the one its last Claude turn left in that session.
        let onClaude = try await store.usage(
            of: nova,
            on: .claudeCode,
            in: workspaceID
        )
        #expect(onClaude.lastTurn == third)
        #expect(onClaude.context?.tokens == 3640)
        #expect(onClaude.context?.fraction == 3640.0 / 1_000_000)

        let withoutProvider = try await store.usage(
            of: nova,
            on: nil,
            in: workspaceID
        )
        #expect(withoutProvider.turns == 3)
        #expect(withoutProvider.context == nil)
        #expect(withoutProvider.rateLimits.isEmpty)
    }

    @Test func theLimitsAreTheNewestAnyWorkerOnTheProviderReported() async throws {
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let nova  = try await worker(
            "Nova",
            in: store
        )
        let orion = try await worker(
            "Orion",
            in: store
        )
        let older = ProviderUsage.RateLimit(
            window      : "seven_day",
            usedFraction: 0.5
        )

        let turns: [(TurnUsage, UUID)] = [
            (
                usage(
                    input  : 10,
                    output : 1,
                    context: 11,
                    limits : [older]
                ),
                nova
            ),
            (
                usage(
                    input  : 20,
                    output : 2,
                    context: 22,
                    limits : [fiveHours, sevenDays]
                ),
                orion
            ),
            // A later turn that reported no limits, and one on another provider, change nothing.
            (
                usage(
                    input  : 30,
                    output : 3,
                    context: 33
                ),
                orion
            ),
            (
                usage(
                    input   : 40,
                    output  : 4,
                    context : 44,
                    provider: .codex,
                    model   : "gpt-5.6-luna"
                ),
                orion
            ),
        ]
        for (reported, worker) in turns {
            try await record(
                reported,
                by: worker,
                in: store
            )
        }

        let seen = try await store.usage(
            of: nova,
            on: .claudeCode,
            in: workspaceID
        )
        #expect(seen.rateLimits == [fiveHours, sevenDays])
        #expect(seen.turns == 1)
        #expect(seen.lastTurn?.turn.input == 10)

        for provider in [ModelProvider.codex, .ollama] {
            let other = try await store.usage(
                of: orion,
                on: provider,
                in: workspaceID
            )
            #expect(other.rateLimits.isEmpty)
        }
    }

    @Test func aRowAtAnotherVersionOrThatDoesNotDecodeIsSkipped() async throws {
        defer { TemporaryStore.discard(directory) }
        let store    = try WorkspaceStore.opening(in: directory)
        let nova     = try await worker(
            "Nova",
            in: store
        )
        let reported = usage(
            input  : 10,
            output : 1,
            context: 11
        )
        try await record(
            reported,
            by: nova,
            in: store
        )

        let payload = try reported.encoded()
        let rows: [(type: EventType, version: Int, payload: Data)] = [
            (.turnUsage, TurnUsage.payloadVersion + 1, payload),
            (.turnUsage, 0, payload),
            (.turnUsage, TurnUsage.payloadVersion, Data(#"{"provider":"someday","turn":{}}"#.utf8)),
            (.turnUsage, TurnUsage.payloadVersion, Data([0xFF, 0x00])),
            (.unknown("turnUsageV2"), TurnUsage.payloadVersion, payload),
        ]
        for row in rows {
            try await store.append(NewEvent(
                workspaceID   : workspaceID,
                subjectID     : UUID(),
                workerID      : nova,
                type          : row.type,
                payloadVersion: row.version,
                payload       : row.payload
            ))
        }

        let read = try await store.usage(
            of: nova,
            on: .claudeCode,
            in: workspaceID
        )
        #expect(read.turns == 1)
        #expect(read.lastTurn == reported)
        #expect(read.context?.tokens == 11)
    }

    @Test func onlyUsageRowsCarryTheKeyTheStoreSelectsThemBy() {
        func key(_ type: EventType) -> String {
            NewEvent(
                workspaceID: UUID(),
                subjectID  : UUID(),
                type       : type
            ).deduplicationKey
        }
        #expect(key(.turnUsage).hasPrefix(NewEvent.usageKeyPrefix))
        // A tool record carries a whole scene, so it must never match the usage read.
        #expect(!key(.toolActivity).hasPrefix(NewEvent.usageKeyPrefix))
        #expect(key(.executionCompleted).hasPrefix("terminal:"))
    }

    @Test func aCompactionCountsInTheLifetimeButIsNeitherTheLastMessageNorAMessage() {
        let message = TurnUsage(
            provider     : .codex,
            model        : "gpt-5.6-luna",
            session      : "thread",
            turn         : ProviderUsage.Tokens(input: 100, output: 10),
            sessionTotal : nil,
            contextTokens: 90,
            contextWindow: 1_000,
            rateLimits   : []
        )
        var compaction          = message
        compaction.isCompaction = true

        let usage = WorkerUsage(
            turns     : [message, compaction],
            provider  : .codex,
            rateLimits: []
        )
        #expect(usage.lifetime.input == 200)
        #expect(usage.turns == 1)
        #expect(usage.lastTurn == message)
        // An old payload without the field reads as a message.
        let old = Data(#"{"provider":"codex","turn":{"input":1,"output":1,"cacheReads":0,"cacheWrites":0,"reasoning":0},"rateLimits":[]}"#.utf8)
        #expect(TurnUsage.decoded(old)?.isCompaction == nil)
    }
}
