//
//  WorkerUsage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports

/// WorkerUsage is what a worker's turns used over its life, and how full the
/// model's context is now, summed from its `turnUsage` events on every read.
///
/// Tokens used and context fill are kept apart: `lifetime` and `lastTurn` are
/// what the turns cost, `context` is how much of the window the conversation
/// fills on the worker's current provider. `rateLimits` are the account's, the
/// newest any worker's turn on that provider recorded.
nonisolated struct WorkerUsage: Sendable, Hashable {

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

    /// Every turn's own usage added up, and how many turns reported one.
    let lifetime  : ProviderUsage.Tokens
    let turns     : Int

    /// The same totals by the model each turn named, the provider's name when it named none.
    let byModel   : [String: ProviderUsage.Tokens]

    /// The worker's latest turn that reported usage, on any provider.
    let lastTurn  : TurnUsage?

    /// From the latest turn on `provider` that reported a context. Nil before one,
    /// and when the worker has no provider.
    let context   : Context?

    let rateLimits: [ProviderUsage.RateLimit]

    /// `turns` are the worker's, oldest first. `provider` is the one it answers
    /// with now, whose session the next turn resumes.
    init(
        turns     : [TurnUsage],
        provider  : ModelProvider?,
        rateLimits: [ProviderUsage.RateLimit]
    ) {
        var byModel: [String: ProviderUsage.Tokens] = [:]
        for usage in turns {
            let model      = usage.model ?? usage.provider.rawValue
            byModel[model] = (byModel[model] ?? ProviderUsage.Tokens()) + usage.turn
        }
        let current = turns.last { $0.provider == provider && $0.contextTokens != nil }

        self.lifetime   = turns.reduce(ProviderUsage.Tokens()) { $0 + $1.turn }
        self.turns      = turns.count
        self.byModel    = byModel
        self.lastTurn   = turns.last
        self.context    = current?.contextTokens.map {
            Context(
                tokens: $0,
                window: current?.contextWindow
            )
        }
        self.rateLimits = rateLimits
    }
}
