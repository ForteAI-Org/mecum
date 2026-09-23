import Foundation

/// Whether a provider can be used right now, and which models it offers.
/// `check` is the one authority for the first; see ProviderCatalog+Check.
/// Model lists come from the providers themselves where an endpoint exists.
public enum ProviderCatalog {
    /// nil when the provider is usable, otherwise the reason it is not.
    ///
    /// It is `check` read as a sentence, so the two never disagree: the
    /// state's own message, never a second wording of the same fact.
    public static func status(_ provider: ModelProvider, settings: ProviderSettings) async -> String? {
        let state = await check(provider, settings: settings)
        return state.isReady ? nil : state.message
    }

    /// Models the provider reports as available to this account or server.
    public static func models(_ provider: ModelProvider, settings: ProviderSettings) async throws -> [String] {
        switch provider {
        case .codex, .claudeCode:
            return provider.knownModels
        case .anthropic:
            guard !settings.anthropicAPIKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!, timeoutInterval: 15)
            request.setValue(settings.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await HTTPTransport.getJSON(request)
            let data = json["data"] as? [[String: Any]] ?? []
            return data.compactMap { $0["id"] as? String }.sorted()
        case .gemini:
            guard !settings.geminiAPIKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!,
                                     timeoutInterval: 15)
            request.setValue(settings.geminiAPIKey, forHTTPHeaderField: "x-goog-api-key")
            let json = try await HTTPTransport.getJSON(request)
            let models = json["models"] as? [[String: Any]] ?? []
            return models.compactMap { model -> String? in
                guard let methods = model["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                      let name = model["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            }.sorted()
        case .ollama:
            return try await OllamaClient.models(host: settings.ollamaHost)
        }
    }

    /// Models the local Ollama server has pulled, for a host that is not the
    /// one in the settings yet.
    public static func ollamaModels(host: String) async throws -> [String] {
        try await OllamaClient.models(host: host)
    }
}
