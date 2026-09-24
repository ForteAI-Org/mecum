//
//  ModelInfo.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// ModelInfo is one model a provider offers, as its catalogue names it: the
/// id a request sends, the name a person reads, and the efforts the model
/// accepts, lowest first, with the one it starts at.
public struct ModelInfo: Sendable, Hashable, Identifiable {

    public let id: String

    /// The provider's own display name, or the id when it gives none.
    public let title: String

    /// Empty when the model takes no effort at all.
    public let efforts: [ReasoningEffort]

    /// The provider's default level, when it names one the model accepts.
    public let defaultEffort: ReasoningEffort?

    public init(
        id           : String,
        title        : String? = nil,
        efforts      : [ReasoningEffort],
        defaultEffort: ReasoningEffort? = nil
    ) {
        self.id            = id
        self.title         = title ?? id
        self.efforts       = efforts
        self.defaultEffort = defaultEffort.flatMap { efforts.contains($0) ? $0 : nil }
    }

    /// The level a worker starts at on this model: its catalogue's default, else medium, else
    /// its highest, and medium for a model with no levels.
    public var startingEffort: ReasoningEffort {
        defaultEffort ?? (efforts.contains(.medium) ? .medium : efforts.last ?? .medium)
    }

    /// A model the catalogue knows only by id, with the efforts the provider takes for it.
    static func known(
        _ id    : String,
        provider: ModelProvider,
        title   : String? = nil
    ) -> ModelInfo {
        ModelInfo(
            id     : id,
            title  : title,
            efforts: ModelSelection.supportedEfforts(provider: provider, model: id)
        )
    }
}
