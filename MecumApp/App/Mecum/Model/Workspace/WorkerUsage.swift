//
//  WorkerUsage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import ChatCore
import Foundation
import ModelTransports

/// WorkerUsage is what a worker's turns used over its life, and how full the
/// model's context is now, summed from its `turnUsage`, `contextCompacted` and
/// `contextReset` events on every read.
///
/// Tokens used and context fill are kept apart: `lifetime` and `lastTurn` are
/// what the turns cost, `context` is how much of the window the conversation
/// fills on the worker's current provider. `rateLimits` are the account's, the
/// newest any worker's turn on that provider recorded.
nonisolated struct WorkerUsage: Sendable, Hashable {

    /// One recorded event that moves the context, in the order it was recorded.
    enum Record: Sendable, Hashable {
        case turn(TurnUsage)
        case compacted(ContextCompaction)

        /// A fresh context, on every provider: nothing is known of it until the next turn.
        case reset
    }

    /// How much of the model's context the conversation fills.
    struct Context: Sendable, Hashable {
        let tokens: Int

        /// The model's window, nil when neither the provider nor its catalogue states it.
        let window: Int?

        /// `tokens` over `window`, nil without a window.
        var fraction: Double? {
            guard let window, window > 0 else { return nil }
            return Double(tokens) / Double(window)
        }
    }

    /// Every turn's own usage added up, compactions included, and how many of those turns
    /// answered a message.
    let lifetime  : ProviderUsage.Tokens
    let turns     : Int

    /// The same totals by the model each turn named, the provider's name when it named none.
    let byModel   : [String: ProviderUsage.Tokens]

    /// The worker's latest turn that answered a message and reported usage, on any provider.
    let lastTurn  : TurnUsage?

    /// From the newest of the latest turn on `provider` that reported a context,
    /// the latest compaction on `provider`, and a fresh context: a compaction
    /// leaves its size after, and a fresh context or a compaction of unknown size
    /// leaves nil. Nil before any, and when the worker has no provider.
    let context   : Context?

    let rateLimits: [ProviderUsage.RateLimit]

    /// `turns` are the worker's, oldest first. `provider` is the one it answers
    /// with now, whose session the next turn resumes.
    init(
        turns     : [TurnUsage],
        provider  : ModelProvider?,
        rateLimits: [ProviderUsage.RateLimit]
    ) {
        self.init(
            records   : turns.map(Record.turn),
            provider  : provider,
            rateLimits: rateLimits
        )
    }

    /// `records` are the worker's, oldest first.
    init(
        records   : [Record],
        provider  : ModelProvider?,
        rateLimits: [ProviderUsage.RateLimit]
    ) {
        let turns = records.compactMap { record -> TurnUsage? in
            if case .turn(let usage) = record { usage } else { nil }
        }
        var byModel: [String: ProviderUsage.Tokens] = [:]
        for usage in turns {
            let model      = usage.model ?? usage.provider.rawValue
            byModel[model] = (byModel[model] ?? ProviderUsage.Tokens()) + usage.turn
        }

        // A compaction's tokens were spent, so they count; it answered no message, so it is none.
        let messages    = turns.filter { $0.isCompaction != true }
        self.lifetime   = turns.reduce(ProviderUsage.Tokens()) { $0 + $1.turn }
        self.turns      = messages.count
        self.byModel    = byModel
        self.lastTurn   = messages.last
        self.context    = Self.context(
            of: records,
            on: provider
        )
        self.rateLimits = rateLimits
    }

    /// The context the newest record that says anything about it on `provider` leaves.
    private static func context(
        of records : [Record],
        on provider: ModelProvider?
    ) -> Context? {
        for record in records.reversed() {
            switch record {
            case .turn(let usage) where usage.provider == provider && usage.contextTokens != nil:
                return usage.contextTokens.map {
                    Context(
                        tokens: $0,
                        window: usage.contextWindow
                    )
                }
            case .compacted(let compaction) where compaction.provider == provider:
                return compaction.postTokens.map {
                    Context(
                        tokens: $0,
                        window: compaction.contextWindow
                    )
                }
            case .reset:
                return nil
            case .turn, .compacted:
                continue
            }
        }
        return nil
    }
}
