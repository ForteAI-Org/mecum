//
//  MessageContentPipeline.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// MessageContentPipeline turns a message's text into what a row lays out and
/// draws (§12.2).
///
/// It is the pluggable step between projection and measurement: this ticket
/// ships `PlainTextContent`, and Markdown, code blocks and streaming flushes
/// replace it without touching the engine. A conformer is called off the main
/// thread, once per row being prepared, and must not touch a view.
public protocol MessageContentPipeline: Sendable {

    /// The prepared form of `text`. `isOnAccent` is true for the person's
    /// bubble, whose surface is the accent colour.
    func prepare(_ text: String, isOnAccent: Bool) -> PreparedText
}

/// PlainTextContent renders a message as one run of body text.
public struct PlainTextContent: MessageContentPipeline {

    public init() {}

    public func prepare(_ text: String, isOnAccent: Bool) -> PreparedText {
        PreparedText(text, role: isOnAccent ? .bodyOnAccent : .body)
    }
}
