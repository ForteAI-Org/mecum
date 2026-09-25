//
//  TurnUsage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports

/// TurnUsage is what one turn cost, as a `turnUsage` event records it on the
/// turn's execution: the tokens the turn used, and apart from them how full it
/// left the model's context, which is a different number (a turn that rereads
/// a cached history of 100k tokens twice uses 200k and leaves 100k).
///
/// `turn` is the turn's own usage for every provider. A provider that counts
/// its session as a whole (Codex) also leaves `sessionTotal`, the running total
/// the next turn in `session` is counted from. The limits are the account's, as
/// the provider last reported them. Every other field is nil or empty when the
/// provider did not report it.
nonisolated struct TurnUsage: Sendable, Hashable, Codable {

    /// The `payloadVersion` a `turnUsage` event is written with. A row at any
    /// other version is skipped, never guessed at.
    static let payloadVersion = 1

    let provider     : ModelProvider

    /// The model as the provider named it, else as the turn's selection did.
    let model        : String?

    /// The provider session the turn ran in, nil for a turn through Mecum's own loop.
    let session      : String?

    let turn         : ProviderUsage.Tokens
    let sessionTotal : ProviderUsage.Tokens?
    let contextTokens: Int?
    let contextWindow: Int?
    let rateLimits   : [ProviderUsage.RateLimit]

    /// The payload a `turnUsage` event stores.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting     = .sortedKeys
        return try encoder.encode(self)
    }

    /// A stored payload, or nil when it is not one this build can read.
    static func decoded(_ payload: Data) -> TurnUsage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Absence is the documented result: a row this build cannot read is skipped.
        return try? decoder.decode(
            TurnUsage.self,
            from: payload
        )
    }
}

// Token counts add up across turns, and a running total less the one before is a turn's own.
nonisolated extension ProviderUsage.Tokens {

    static func + (
        lhs: Self,
        rhs: Self
    ) -> Self {
        Self(
            input      : lhs.input + rhs.input,
            cacheReads : lhs.cacheReads + rhs.cacheReads,
            cacheWrites: lhs.cacheWrites + rhs.cacheWrites,
            output     : lhs.output + rhs.output,
            reasoning  : lhs.reasoning + rhs.reasoning
        )
    }

    /// What `lhs` counts past `rhs`, never below zero.
    static func - (
        lhs: Self,
        rhs: Self
    ) -> Self {
        Self(
            input      : max(0, lhs.input - rhs.input),
            cacheReads : max(0, lhs.cacheReads - rhs.cacheReads),
            cacheWrites: max(0, lhs.cacheWrites - rhs.cacheWrites),
            output     : max(0, lhs.output - rhs.output),
            reasoning  : max(0, lhs.reasoning - rhs.reasoning)
        )
    }
}
