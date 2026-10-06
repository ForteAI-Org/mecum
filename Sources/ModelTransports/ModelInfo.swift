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

    /// The provider's own display name, or `displayName(for:)` of the id when it gives none.
    public let title: String

    /// Empty when the model takes no effort at all.
    public let efforts: [ReasoningEffort]

    /// The provider's default level, when it names one the model accepts.
    public let defaultEffort: ReasoningEffort?

    /// The most input tokens the model takes, when the catalogue states it: the Anthropic
    /// listing's `max_input_tokens`, Gemini's `inputTokenLimit`.
    public let contextWindow: Int?

    public init(
        id           : String,
        title        : String? = nil,
        efforts      : [ReasoningEffort],
        defaultEffort: ReasoningEffort? = nil,
        contextWindow: Int?             = nil
    ) {
        self.id            = id
        self.title         = title ?? Self.displayName(for: id)
        self.efforts       = efforts
        self.defaultEffort = defaultEffort.flatMap { efforts.contains($0) ? $0 : nil }
        self.contextWindow = contextWindow
    }

    /// The level a worker starts at on this model: its catalogue's default, else medium, else
    /// its highest, and medium for a model with no levels.
    public var startingEffort: ReasoningEffort {
        defaultEffort ?? (efforts.contains(.medium) ? .medium : efforts.last ?? .medium)
    }

    /// The name a person reads for a model known only by id: "claude-haiku-4-5" is
    /// "Haiku 4.5", "gpt-5.4-mini" "GPT-5.4-Mini", "gemini-3-pro-preview" "Gemini 3 Pro
    /// Preview". An id of any other shape, a local Ollama tag among them, reads as itself.
    public static func displayName(for id: String) -> String {
        let parts = ProviderCatalog.claudeID(id).split(separator: "-")
        switch parts.first ?? "" {
        case "claude" where parts.count >= 3 && parts.dropFirst(2).allSatisfy({ $0.allSatisfy(\.isNumber) }):
            return parts[1].capitalized + " " + parts.dropFirst(2).joined(separator: ".")
        case "gpt" where parts.count >= 2:
            return "GPT-" + parts.dropFirst().map { $0.capitalized }.joined(separator: "-")
        case "gemini" where parts.count >= 2:
            return "Gemini " + parts.dropFirst().map { $0.capitalized }.joined(separator: " ")
        default:
            return id
        }
    }

    /// A model the catalogue knows only by id, with the efforts the provider takes for it.
    static func known(
        _ id         : String,
        provider     : ModelProvider,
        title        : String? = nil,
        contextWindow: Int?    = nil
    ) -> ModelInfo {
        ModelInfo(
            id           : id,
            title        : title,
            efforts      : ModelSelection.supportedEfforts(provider: provider, model: id),
            contextWindow: contextWindow
        )
    }
}
