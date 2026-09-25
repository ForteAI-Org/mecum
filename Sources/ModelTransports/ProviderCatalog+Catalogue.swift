//
//  ProviderCatalog+Catalogue.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

extension ProviderCatalog {

    // MARK: Catalogue

    /// Every model the provider offers this account or server, with the efforts each accepts.
    ///
    /// Codex answers from `codex debug models`, its own catalogue, which also
    /// names each model's levels; a hidden model is left out. The API providers
    /// are read page by page to the end. Claude Code has no listing, so its
    /// models are `knownModels`. Ollama lists what the local server has pulled.
    public static func catalogue(
        _ provider: ModelProvider,
        settings  : ProviderSettings
    ) async throws -> [ModelInfo] {
        switch provider {
        case .codex:
            let result = try await CodexCLIClient.run(
                executable: CodexCLIClient.executableURL(),
                arguments : ["debug", "models"],
                input     : Data(),
                schema    : nil,
                timeout   : 20
            )
            guard result.status == 0 else { throw CodexClientError.failed("codex debug models exited \(result.status)") }
            return try codexCatalogue(from: result.output)
        case .claudeCode:
            return provider.knownModels.map { .known($0, provider: provider) }
        case .anthropic:
            return try await anthropicCatalogue(apiKey: settings.anthropicAPIKey)
        case .gemini:
            return try await geminiCatalogue(apiKey: settings.geminiAPIKey)
        case .ollama:
            return try await OllamaClient.models(host: settings.ollamaHost).map { .known($0, provider: provider) }
        }
    }

    /// The listed models of `codex debug models`, in the catalogue's own order of priority.
    /// A level this app does not know is left out rather than guessed at.
    static func codexCatalogue(from data: Data) throws -> [ModelInfo] {
        guard let json   = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { throw CodexClientError.failed("codex debug models printed no catalogue") }

        return models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model -> ModelInfo? in
                guard let slug = model["slug"] as? String else { return nil }
                let levels = model["supported_reasoning_levels"] as? [[String: Any]] ?? []
                return ModelInfo(
                    id           : slug,
                    title        : model["display_name"] as? String,
                    efforts      : levels.compactMap { ($0["effort"] as? String).flatMap(ReasoningEffort.init(rawValue:)) },
                    defaultEffort: (model["default_reasoning_level"] as? String).flatMap(ReasoningEffort.init(rawValue:))
                )
            }
    }

    /// Every page of `/v1/models`, newest first as the API returns them.
    private static func anthropicCatalogue(apiKey: String) async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }

        var models: [ModelInfo] = []
        var after : String?
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await HTTPTransport.getJSON(request)
            let page = json["data"] as? [[String: Any]] ?? []
            models += page.compactMap { entry in
                (entry["id"] as? String).map {
                    .known(
                        $0,
                        provider     : .anthropic,
                        title        : entry["display_name"] as? String,
                        contextWindow: entry["max_input_tokens"] as? Int
                    )
                }
            }
            after = json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        } while after != nil
        return models
    }

    /// Every page of the Generative Language API's models that can generate content.
    private static func geminiCatalogue(apiKey: String) async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }

        var models: [ModelInfo] = []
        var token : String?
        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let json = try await HTTPTransport.getJSON(request)
            let page = json["models"] as? [[String: Any]] ?? []
            models += page.compactMap { entry -> ModelInfo? in
                guard let methods = entry["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                      let name = entry["name"] as? String
                else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return .known(
                    id,
                    provider     : .gemini,
                    title        : entry["displayName"] as? String,
                    contextWindow: entry["inputTokenLimit"] as? Int
                )
            }
            token = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
        return models
    }
}
