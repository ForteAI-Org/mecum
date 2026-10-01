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
nonisolated struct ContextCompaction: Sendable, Hashable, Codable {

    /// The `payloadVersion` a `contextCompacted` event is written with. A row at
    /// any other version is skipped, never guessed at.
    static let payloadVersion = 1

    /// Who asked for the compaction.
    enum Trigger: String, Sendable, Hashable, Codable {

        /// The person, from the context popover.
        case manual

        /// Mecum, after a turn that left the context at the context budget.
        case automatic
    }

    let provider     : ModelProvider
    let trigger      : Trigger
    let preTokens    : Int?
    let postTokens   : Int?

    /// The model's window, so the ring can draw `postTokens` against it.
    let contextWindow: Int?

    /// What Mecum's loop remembers of the conversation before the compaction; nil for a command line.
    let summary      : String?

    /// The payload a `contextCompacted` event stores.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// A stored payload, or nil when it is not one this build can read.
    static func decoded(_ payload: Data) -> ContextCompaction? {
        // Absence is the documented result: a row this build cannot read has no size to show.
        try? JSONDecoder().decode(
            ContextCompaction.self,
            from: payload
        )
    }
}
