//
//  ContextSeparatorTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A compaction or a fresh context draws a quiet line where it happened, in
/// the day separator's style, and says the same to VoiceOver.
@Suite("Context separators in the transcript")
struct ContextSeparatorTests {

    @Test func eachContextChangeIsASeparatorWithItsWordsAndTime() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say(
            "Check the build.",
            at: 0
        )
        try await fixture.record(
            .executionStarted,
            subject: execution,
            at     : 1
        )
        try await fixture.say(
            "Two bundles failed.",
            at      : 2,
            byWorker: true
        )
        try await fixture.record(
            .executionCompleted,
            subject: execution,
            at     : 3
        )
        for (trigger, second) in [(ContextCompaction.Trigger.manual, 10.0), (.automatic, 20)] {
            let compaction = ContextCompaction(
                provider     : .codex,
                trigger      : trigger,
                preTokens    : 240_000,
                postTokens   : 38_200,
                contextWindow: 258_400,
                summary      : nil
            )
            try await fixture.record(
                .contextCompacted,
                subject: fixture.conversation,
                at     : second,
                text   : String(
                    decoding: try compaction.encoded(),
                    as      : UTF8.self
                )
            )
        }
        try await fixture.record(
            .contextReset,
            subject: fixture.conversation,
            at     : 30
        )
        try await fixture.say(
            "Rerun it.",
            at: 40
        )

        let items      = TranscriptFixture.withoutDays(try await fixture.items())
        let separators = items.filter(\.isSeparator)
        #expect(separators.map(\.kind) == [
            .contextSeparator(.compacted),
            .contextSeparator(.compactedAutomatically),
            .contextSeparator(.freshStart),
        ])
        #expect(separators.map(\.date) == [10, 20, 30].map(TranscriptFixture.at))
        #expect(items.last?.messageID != nil, "the message after them comes last")

        let words = ["Context compacted", "Context compacted automatically", "Started a fresh context"]
        for (separator, words) in zip(separators, words) {
            let line = words + " · " + TranscriptWording.time(separator.date)
            let text = RowPreparation.preparedText(
                for       : separator,
                workerName: "Atlas",
                pipeline  : MarkdownContent()
            )
            #expect(text.string == line)
            #expect(TranscriptWording.accessibilityLabel(
                for       : separator,
                workerName: "Atlas"
            ) == line)
            #expect(separator.copyText == line)
            #expect(RowGeometry.shape(of: separator.kind) == .divider, "never a bubble")
            #expect(separator.authorWorkerID == nil)
            #expect(!separator.continuesGroup)
        }

        let reply = try #require(items.first { if case .workerReply = $0.kind { true } else { false } })
        #expect(reply.endsGroup, "the separator under a reply ends its group")
    }
}
