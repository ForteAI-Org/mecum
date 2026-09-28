//
//  QueuedMessage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation

/// QueuedMessage is a message sent while its worker was answering: its text
/// and the quote it replies to, waiting in its conversation's queue to go out
/// when the turn ends, or when the person sends it on.
nonisolated struct QueuedMessage: Codable, Sendable, Hashable {

    let text: String

    let quote: MessageQuote?

    init(
        text : String,
        quote: MessageQuote? = nil
    ) {
        self.text  = text
        self.quote = quote
    }

    /// The text as one line, as the queue's strip shows it.
    var excerpt: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A queue as `Conversation` stores it, JSON in one column, nil for none.
    static func encoded(_ queue: [QueuedMessage]) throws -> Data? {
        queue.isEmpty ? nil : try JSONEncoder().encode(queue)
    }

    /// A stored queue read back in order; nil, and data that no longer decodes, read as empty.
    static func decoded(_ data: Data?) -> [QueuedMessage] {
        data.flatMap { try? JSONDecoder().decode([QueuedMessage].self, from: $0) } ?? []
    }
}
