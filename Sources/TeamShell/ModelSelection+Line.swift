//
//  ModelSelection+Line.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports

extension ModelSelection {

    /// The model, then the effort when the model takes one, in the provider's
    /// words: "gpt-5.4-mini, Low effort", or "qwen3:8b, Thinking".
    public var line: String {
        let efforts = Self.supportedEfforts(provider: provider, model: model)
        guard efforts.contains(effort) else { return model }
        // Ollama's knob is thinking on or off, which reads as itself and not as an effort.
        let title = effort.title(for: provider)
        return "\(model), " + (provider == .ollama ? title : "\(title) effort")
    }
}
