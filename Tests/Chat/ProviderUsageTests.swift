//
//  ProviderUsageTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import CLIProviders
import Foundation
import Testing

/// Each row replays a recorded turn, sanitized, through the decoder.
@Suite("What a provider reports a turn cost")
struct ProviderUsageTests {

    private func events(_ provider: ChatProvider, _ fixture: String) throws -> [ProviderEvent] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "jsonl",
                                                 subdirectory: "Fixtures"))
        var decoder = ProviderEventDecoder(provider: provider)
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n")
            .flatMap { try decoder.decode(Data($0.utf8)) }
    }

    private func usage(_ events: [ProviderEvent]) throws -> ProviderUsage {
        let reported = events.compactMap { event -> ProviderUsage? in
            if case .usage(let usage) = event { usage } else { nil }
        }
        #expect(reported.count == 1)
        return try #require(reported.first)
    }

    @Test
    func claudeReportsTheTurnTheContextTheWindowAndTheLimits() throws {
        let events = try events(.claude, "claude-turn1")
        let usage = try usage(events)
        #expect(Array(events.suffix(2)) == [.usage(usage), .completed])
        #expect(events.contains(.assistant("ok")))

        #expect(usage.tokens == ProviderUsage.Tokens(input: 2 + 3555, cacheReads: 0, cacheWrites: 3555,
                                                     output: 4, reasoning: 0))
        #expect(!usage.isSessionTotal)
        #expect(usage.contextTokens == 3561)
        #expect(usage.contextWindow == 1_000_000)
        #expect(usage.model == "claude-opus-5[1m]")
        #expect(usage.rateLimits == [
            ProviderUsage.RateLimit(window: "five_hour", usedFraction: 0.13,
                                    resetsAt: Date(timeIntervalSince1970: 1_790_359_800)),
            ProviderUsage.RateLimit(window: "seven_day", usedFraction: 0.79,
                                    resetsAt: Date(timeIntervalSince1970: 1_790_506_800)),
        ])
    }

    @Test
    func codexReportsTheSessionsRunningTotal() throws {
        let totals = try ["codex-turn1", "codex-compact", "codex-lowlimit"].map { try usage(events(.codex, $0)) }
        #expect(totals.map(\.tokens.input) == [16344, 32701, 49255])
        #expect(totals.allSatisfy { $0.isSessionTotal })
        #expect(totals[1].tokens == ProviderUsage.Tokens(input: 32701, cacheReads: 27904, cacheWrites: 0,
                                                         output: 44, reasoning: 32))
        #expect(totals.allSatisfy { $0.contextTokens == nil && $0.contextWindow == nil && $0.rateLimits.isEmpty })
        #expect(try events(.codex, "codex-turn1").last == .completed)
    }

    @Test
    func aResultWithoutUsageReportsNone() throws {
        var claude = ProviderEventDecoder(provider: .claude)
        #expect(try claude.decode(Data(#"{"type":"result","is_error":false,"result":"Hi"}"#.utf8))
                == [.assistant("Hi"), .completed])
        var codex = ProviderEventDecoder(provider: .codex)
        #expect(try codex.decode(Data(#"{"type":"turn.completed"}"#.utf8)) == [.completed])
    }
}
