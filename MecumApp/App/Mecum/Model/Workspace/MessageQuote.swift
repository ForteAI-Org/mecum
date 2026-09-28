//
//  MessageQuote.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation

/// MessageQuote is what a reply quotes: the message it answers, who wrote it,
/// and the words taken from it, the whole text or the part the reader selected.
///
/// It is a copy taken when the reply is started, not a reference looked up
/// later, so a quote still reads when its message is far outside the loaded
/// window or the context it was sent in was compacted.
nonisolated struct MessageQuote: Codable, Sendable, Hashable {

    let messageID: UUID

    /// The worker that wrote the quoted message, or nil for the person.
    let authorWorkerID: UUID?

    let text: String

    init(
        messageID     : UUID,
        authorWorkerID: UUID?,
        text          : String
    ) {
        self.messageID      = messageID
        self.authorWorkerID = authorWorkerID
        self.text           = text
    }

    /// True when the person wrote the quoted message.
    var isFromPerson: Bool { authorWorkerID == nil }

    /// The quote as one line: every run of line breaks and spaces becomes one
    /// space, so a strip or a bubble shows words rather than blank lines.
    var excerpt: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
