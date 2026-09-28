//
//  TurnProgress.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// What a provider's stream has said so far about one turn, apart from the
/// text itself. A provider's event decoder fills this as events arrive: the
/// counts come in their own events, sometimes before the first delta and
/// sometimes with the last.
struct TurnProgress: Sendable {

    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?

    /// Generation time the provider measures itself, when it reports one. Nil
    /// leaves the wall clock to answer for the turn.
    var generated: Duration?

    /// The provider declared the turn finished. Nothing else may declare it.
    var isFinished = false

    /// Why the provider says it stopped, in its own spelling. Nil until it says.
    var stopReason: String?

    /// Every tool call the provider completed so far, in order. A decoder
    /// appends a call only once its arguments are whole.
    var toolCalls: [ToolCall] = []

    /// Content blocks still streaming, by the provider's own index, for a
    /// provider that streams its turn as indexed blocks (Anthropic).
    var streamingBlocks: [Int: StreamingBlock] = [:]

    /// The turn's content in the provider's own shape, each block encoded
    /// whole, for the `TurnRecord` a provider that keeps one sends back.
    var contentBlocks: [Data] = []

    /// The stop reason names a whole answer. Only the provider's decoder can
    /// say so, because only it knows the vocabulary; an unknown reason leaves
    /// this false, so a turn that stopped for a reason nobody recognises fails
    /// closed rather than passing as complete.
    var isWholeAnswer = false

    /// Records the provider's stop reason and whether it is one of the few that
    /// mean the answer is whole.
    mutating func recordStop(_ reason: String?, wholeAnswerReasons: Set<String>) {
        stopReason    = reason
        isWholeAnswer = reason.map(wholeAnswerReasons.contains) ?? false
    }

    func usage(wallClock: Duration) -> ModelUsage {
        ModelUsage(inputTokens: inputTokens, outputTokens: outputTokens, duration: generated ?? wallClock,
                   cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }
}

/// One content block while it streams: the block as its start carried it, and
/// what its deltas appended (text, thinking or partial JSON) and signed.
struct StreamingBlock: Sendable {
    let start: Data
    var appended = ""
    var signature = ""
}
