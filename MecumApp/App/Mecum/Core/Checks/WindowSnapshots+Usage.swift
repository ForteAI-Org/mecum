//
//  WindowSnapshots+Usage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports

extension WindowSnapshots {

    /// Atlas's one turn on Codex, which leaves `contextTokens` of GPT-5.6-Luna's
    /// 258,400 in the context and 1.2M new tokens on the counter.
    static func atlasUsage(contextTokens: Int) -> TurnUsage {
        TurnUsage(
            provider     : .codex,
            model        : "gpt-5.6-luna",
            session      : "snapshot-session",
            turn         : ProviderUsage.Tokens(
                input     : 1_642_300,
                cacheReads: 452_100,
                output    : 12_480,
                reasoning : 3_900
            ),
            sessionTotal : nil,
            contextTokens: contextTokens,
            contextWindow: 258_400,
            rateLimits   : []
        )
    }

    /// A worker on Claude that used two models, with the plan's five hour and
    /// weekly limits, for the token counter's popover drawn alone. The resets
    /// are in half an hour and in three days, so both kinds of phrase are drawn.
    static func planUsage(now: Date = Date()) -> WorkerUsage {
        let limits = [
            ProviderUsage.RateLimit(
                window      : "five_hour",
                usedFraction: 0.13,
                resetsAt    : now.addingTimeInterval(1_800)
            ),
            ProviderUsage.RateLimit(
                window      : "seven_day",
                usedFraction: 0.79,
                resetsAt    : now.addingTimeInterval(3 * 86_400)
            ),
        ]
        let opus   = TurnUsage(
            provider     : .claudeCode,
            model        : "claude-opus-5",
            session      : "snapshot-session",
            turn         : ProviderUsage.Tokens(
                input      : 1_212_400,
                cacheReads : 1_104_000,
                cacheWrites: 61_000,
                output     : 24_800,
                reasoning  : 6_100
            ),
            sessionTotal : nil,
            contextTokens: 96_000,
            contextWindow: 1_000_000,
            rateLimits   : limits
        )
        let sonnet = TurnUsage(
            provider     : .claudeCode,
            model        : "claude-sonnet-5",
            session      : "snapshot-session",
            turn         : ProviderUsage.Tokens(
                input     : 18_200,
                cacheReads: 16_100,
                output    : 610
            ),
            sessionTotal : nil,
            contextTokens: 18_810,
            contextWindow: 1_000_000,
            rateLimits   : limits
        )
        return WorkerUsage(
            turns     : [opus, opus, sonnet],
            provider  : .claudeCode,
            rateLimits: limits
        )
    }
}
