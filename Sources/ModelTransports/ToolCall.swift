//
//  ToolCall.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation

/// ToolCall is one call a model made to a tool during a turn, whole: the
/// arguments are complete before a transport hands the call on.
///
/// `id` is the provider's own when it gives one. Ollama's documented shape has
/// no id, though current servers send one; a call that arrives without one is
/// numbered in the order the turn's calls arrived, unique within that turn.
public struct ToolCall: Sendable, Hashable {

    public let id: String
    public let name: String

    /// The arguments as one JSON object, encoded.
    public let arguments: Data

    public init(id: String, name: String, arguments: Data) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
