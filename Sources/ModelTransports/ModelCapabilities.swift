//
//  ModelCapabilities.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

/// ModelCapabilities is what a transport has confirmed its model can do beyond
/// answering in text. A model being present says nothing about these (§7.2),
/// so each is asked of the provider separately.
///
/// A flag is true only when the provider confirmed it. False means the model
/// lacks it or the transport has not asked, and a caller treats both alike:
/// it does not send what the model may refuse.
public struct ModelCapabilities: Sendable, Hashable {

    /// The model can be handed tools and call them.
    public let supportsTools: Bool

    /// The model can reason in a trace kept apart from its answer.
    public let supportsThinking: Bool

    /// The model can read images.
    public let supportsVision: Bool

    public init(supportsTools: Bool = false, supportsThinking: Bool = false, supportsVision: Bool = false) {
        self.supportsTools = supportsTools
        self.supportsThinking = supportsThinking
        self.supportsVision = supportsVision
    }
}
