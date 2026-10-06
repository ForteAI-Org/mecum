//
//  ModelSelection+Line.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

extension ModelSelection {

    /// The model, then the effort when the model takes one, in the provider's
    /// words: "GPT-5.4-Mini, Low Effort", or "qwen3:8b, Thinking".
    public var line: String {
        let name    = ModelInfo.displayName(for: model)
        let efforts = Self.supportedEfforts(provider: provider, model: model)
        guard efforts.contains(effort) else { return name }
        // Ollama's knob is thinking on or off, which reads as itself and not as an effort.
        let title = effort.title(for: provider)
        return "\(name), " + (provider == .ollama ? title : "\(title) Effort")
    }
}
