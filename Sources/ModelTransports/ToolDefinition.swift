//
//  ToolDefinition.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation

/// ToolDefinition is one tool a model may call during a turn: its name, what
/// it does, and the JSON Schema its arguments must satisfy. A transport maps it
/// onto its provider's own shape.
///
/// The schema stays encoded: this module reads no tool vocabulary of its own,
/// so it takes the caller's JSON as it is, the way `complete(schema:)` does.
public struct ToolDefinition: Sendable, Hashable {

    public let name: String
    public let description: String

    /// The JSON Schema of the arguments, encoded as one JSON object.
    public let parameters: Data

    public init(name: String, description: String, parameters: Data) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
