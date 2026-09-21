import Foundation

/// Whether a provider can be used right now, and which models it offers.
/// Codex asks the CLI's login state, the API providers need a key, Ollama a
/// reachable server. Model lists come from the providers themselves where an
/// endpoint exists.
enum ProviderCatalog {
    /// nil when the provider is usable, otherwise the reason it is not.
    static func status(_ provider: ModelProvider, settings: ProviderSettings) async -> String? {
        switch provider {
        case .codex:
            do {
                try await CodexCLIClient.checkAuthentication()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .claudeCode:
            do {
                try await ClaudeCLIClient.checkAuthentication()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .anthropic:
            return settings.anthropicAPIKey.isEmpty ? "No API key. Add one in Settings." : nil
        case .gemini:
            return settings.geminiAPIKey.isEmpty ? "No API key. Add one in Settings." : nil
        case .ollama:
            do {
                let models = try await OllamaClient.models(host: settings.ollamaHost)
                return models.isEmpty ? "The Ollama server has no models pulled." : nil
            } catch {
                return "Ollama is not reachable at \(settings.ollamaHost)."
            }
        }
    }

    /// Models the provider reports as available to this account or server.
    static func models(_ provider: ModelProvider, settings: ProviderSettings) async throws -> [String] {
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
}
