//
//  TextDeliveryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import SeatCore
import Testing

@Suite("Text delivery outcome")
struct TextDeliveryTests {

    static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // 1 cluster, 8 code units

    private static func receipt() -> InputReceipt {
        InputReceipt(
            eventCount: 2,
            route     : InputRoute(
                poster           : .publicProcess,
                routedEventCount : 0,
                windowNumber     : 1,
                ownerConnectionID: 1
            )
        )
    }

    private static func outcome(
        chunks  : [String],
        mode    : TextDeliveryMode,
        posted  : Int,
        of text : String
    ) -> TextDeliveryOutcome {
        TextDeliveryOutcome.of(
            chunks       : chunks,
            mode         : mode,
            receipts     : (0 ..< posted).map { _ in receipt() },
            requestedText: text
        )
    }

    @Test("a complete delivery posts everything it asked for, in the mode's own unit")
    func completeDeliveryMatchesItsRequest() {
        let result = Self.outcome(
            chunks: ["abcd", "efgh"], mode: .inserted, posted: 2, of: "abcdefgh"
        )

        #expect(result.commit == .allChunksPosted)
        #expect(result.requested == TextMeasure(8, .utf16CodeUnits))
        #expect(result.posted    == TextMeasure(8, .utf16CodeUnits))
        #expect(result.chunkCount == 2)
    }

    @Test("the unit follows the mode, and the same text measures differently in each")
    func unitFollowsTheMode() {
        let text   = String(repeating: Self.family, count: 4)
        let chunks = [Self.family + Self.family, Self.family + Self.family]

        let typed    = Self.outcome(chunks: chunks, mode: .typed,    posted: 2, of: text)
        let inserted = Self.outcome(chunks: chunks, mode: .inserted, posted: 2, of: text)

        // Four keystrokes, or thirty two code units. The same string.
        #expect(typed.posted    == TextMeasure(4,  .graphemeClusters))
        #expect(inserted.posted == TextMeasure(32, .utf16CodeUnits))
    }

    @Test("a delivery that stopped says how many chunks are already in the target")
    func partialDeliveryCountsWhatWentOut() {
        let result = Self.outcome(
            chunks: ["abcd", "efgh", "ijkl"], mode: .inserted, posted: 2, of: "abcdefghijkl"
        )

        // Not a boolean, because there is no rollback: a caller that retries
        // from the beginning types the first eight code units twice.
        #expect(result.commit == .stoppedAfter(chunks: 2))
        #expect(result.requested == TextMeasure(12, .utf16CodeUnits))
        #expect(result.posted    == TextMeasure(8,  .utf16CodeUnits))
    }

    @Test("a delivery that never started posted nothing, not a partial something")
    func refusedDeliveryPostedNothing() {
        let result = Self.outcome(
            chunks: ["abcd", "efgh"], mode: .inserted, posted: 0, of: "abcdefgh"
        )

        #expect(result.commit == .stoppedAfter(chunks: 0))
        #expect(result.posted == TextMeasure(0, .utf16CodeUnits))
        #expect(result.receipts.isEmpty)
    }

    @Test("what was posted is counted from the receipts, never from the chunks built")
    func postedIsCountedFromReceipts() {
        // The arithmetic that can be wrong without anybody noticing: counting
        // the chunks that were built rather than the ones a Receipt came back
        // for turns a partial delivery into a clean one.
        let result = Self.outcome(
            chunks: ["aaaa", "bbbb", "cccc", "dddd"], mode: .inserted, posted: 1, of: "aaaabbbbccccdddd"
        )

        #expect(result.posted.count == 4)
        #expect(result.requested.count == 16)
        #expect(result.chunkCount == 4)
    }

    @Test("every chunk is its own Command, which is what re-verifies the recipient")
    func oneReceiptPerChunk() {
        let result = Self.outcome(
            chunks: ["ab", "cd", "ef"], mode: .inserted, posted: 3, of: "abcdef"
        )

        // The driver re-reads the window's identity before building a Command
        // and again before its first event, so a Receipt per chunk *is* the
        // revalidation between chunks.
        #expect(result.receipts.count == result.chunkCount)
    }
}
