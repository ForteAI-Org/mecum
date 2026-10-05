//
//  ContextCompaction.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import ModelTransports

/// ContextCompaction is one compaction of a conversation's model context, as a
/// `contextCompacted` event records it: the provider that compacted it, who
/// asked, and its size in tokens before and after, each nil when nothing said.
///
/// A command line compacts its own session and keeps it. Mecum's loop has no
/// session, so it asks the model for `summary`, which later loop turns are sent
/// in place of the messages before the compaction (`TeamModel.turnHistory`).
nonisolated public struct ContextCompaction: Sendable, Hashable, Codable {

    /// The `payloadVersion` a `contextCompacted` event is written with. A row at
    /// any other version is skipped, never guessed at.
    public static let payloadVersion = 1

    /// Who asked for the compaction.
    public enum Trigger: String, Sendable, Hashable, Codable {

        /// The person, from the context popover.
        case manual

        /// Mecum, after a turn that left the context at 90% or more.
        case automatic
    }

    public let provider     : ModelProvider
    public let trigger      : Trigger
    public let preTokens    : Int?
    public let postTokens   : Int?

    /// The model's window, so the ring can draw `postTokens` against it.
    public let contextWindow: Int?

    /// What Mecum's loop remembers of the conversation before the compaction; nil for a command line.
    public let summary      : String?

    public init(
        provider     : ModelProvider,
        trigger      : Trigger,
        preTokens    : Int?,
        postTokens   : Int?,
        contextWindow: Int?,
        summary      : String?
    ) {
        self.provider      = provider
        self.trigger       = trigger
        self.preTokens     = preTokens
        self.postTokens    = postTokens
        self.contextWindow = contextWindow
        self.summary       = summary
    }

    /// The payload a `contextCompacted` event stores.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// A stored payload, or nil when it is not one this build can read.
    public static func decoded(_ payload: Data) -> ContextCompaction? {
        // Absence is the documented result: a row this build cannot read has no size to show.
        try? JSONDecoder().decode(
            ContextCompaction.self,
            from: payload
        )
    }
}
