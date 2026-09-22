import ModelTransports
import SeatBroker
import Foundation
import Observation

/// Persisted model preferences: favorite models per provider, provider
/// knobs, API keys (keychain), and which providers are usable right now.
/// Favorites are what the composer's model picker shows.
@Observable
@MainActor
final class ModelSettingsStore {
    private let defaults = UserDefaults.standard
    private let broker: SeatBroker

    var favorites: [ModelProvider: [String]] {
        didSet { save(favorites.mapKeys { $0.rawValue }, key: "favorites") }
    }
    var anthropicAPIKey: String { didSet { Keychain.set(anthropicAPIKey, for: "anthropic"); scheduleAvailabilityRefresh() } }
    var geminiAPIKey: String { didSet { Keychain.set(geminiAPIKey, for: "gemini"); scheduleAvailabilityRefresh() } }
    var ollamaHost: String { didSet { defaults.set(ollamaHost, forKey: "ollama.host"); scheduleAvailabilityRefresh() } }
    var ollamaTemperature: Double { didSet { defaults.set(ollamaTemperature, forKey: "ollama.temperature") } }
    var ollamaTopP: Double { didSet { defaults.set(ollamaTopP, forKey: "ollama.topP") } }
    var ollamaTopK: Int { didSet { defaults.set(ollamaTopK, forKey: "ollama.topK") } }
    var ollamaPresencePenalty: Double { didSet { defaults.set(ollamaPresencePenalty, forKey: "ollama.presencePenalty") } }
    var ollamaContextTokens: Int { didSet { defaults.set(ollamaContextTokens, forKey: "ollama.numCtx") } }
    var ollamaMaxOutputTokens: Int { didSet { defaults.set(ollamaMaxOutputTokens, forKey: "ollama.numPredict") } }
    var ollamaTimeoutSeconds: Double { didSet { defaults.set(ollamaTimeoutSeconds, forKey: "ollama.timeout") } }
    var lastSelection: ModelSelection { didSet { save(lastSelection, key: "selection") } }

    /// Reason a provider cannot be used, nil when it can. Missing key = not yet checked.
    private(set) var unavailability: [ModelProvider: String?] = [:]
    private(set) var isCheckingAvailability = false
    private var refreshTask: Task<Void, Never>?

    init(broker: SeatBroker) {
        self.broker = broker
        let base = ProviderSettings()
        let stored: [String: [String]] = Self.load(UserDefaults.standard, key: "favorites") ?? [:]
        favorites = Dictionary(uniqueKeysWithValues: ModelProvider.allCases.map { provider in
            (provider, stored[provider.rawValue] ?? provider.defaultModels)
        })
        anthropicAPIKey = Keychain.string(for: "anthropic")
        geminiAPIKey = Keychain.string(for: "gemini")
        ollamaHost = defaults.string(forKey: "ollama.host") ?? base.ollamaHost
        ollamaTemperature = defaults.object(forKey: "ollama.temperature") as? Double ?? base.ollamaTemperature
        ollamaTopP = defaults.object(forKey: "ollama.topP") as? Double ?? base.ollamaTopP
        ollamaTopK = defaults.object(forKey: "ollama.topK") as? Int ?? base.ollamaTopK
        ollamaPresencePenalty = defaults.object(forKey: "ollama.presencePenalty") as? Double ?? base.ollamaPresencePenalty
        ollamaContextTokens = defaults.object(forKey: "ollama.numCtx") as? Int ?? base.ollamaContextTokens
        ollamaMaxOutputTokens = defaults.object(forKey: "ollama.numPredict") as? Int ?? base.ollamaMaxOutputTokens
        ollamaTimeoutSeconds = defaults.object(forKey: "ollama.timeout") as? Double ?? base.ollamaTimeoutSeconds
        lastSelection = Self.load(UserDefaults.standard, key: "selection") ?? .default
        scheduleAvailabilityRefresh()
    }

    var providerSettings: ProviderSettings {
        ProviderSettings(anthropicAPIKey: anthropicAPIKey, geminiAPIKey: geminiAPIKey, ollamaHost: ollamaHost,
                         ollamaTemperature: ollamaTemperature, ollamaTopP: ollamaTopP, ollamaTopK: ollamaTopK,
                         ollamaPresencePenalty: ollamaPresencePenalty, ollamaContextTokens: ollamaContextTokens,
                         ollamaMaxOutputTokens: ollamaMaxOutputTokens, ollamaTimeoutSeconds: ollamaTimeoutSeconds)
    }

    /// Qwen's published sampling for thinking on or off, applied to the Ollama knobs.
    func applyQwenRecommendation(thinking: Bool) {
        var settings = providerSettings
        settings.applyQwenRecommendation(thinking: thinking)
        ollamaTemperature = settings.ollamaTemperature
        ollamaTopP = settings.ollamaTopP
        ollamaTopK = settings.ollamaTopK
        ollamaPresencePenalty = settings.ollamaPresencePenalty
        ollamaMaxOutputTokens = settings.ollamaMaxOutputTokens
    }

    // MARK: Availability

    /// A provider is usable when its check passed and it has at least one model to pick.
    func isAvailable(_ provider: ModelProvider) -> Bool {
        guard let status = unavailability[provider] else { return false }
        return status == nil && !models(for: provider).isEmpty
    }

    var availableProviders: [ModelProvider] { ModelProvider.allCases.filter(isAvailable) }

    /// The reason shown in Settings: the check's verdict, or the missing models.
    func statusText(_ provider: ModelProvider) -> String {
        guard let status = unavailability[provider] else { return "Checking…" }
        if let status { return status }
        return models(for: provider).isEmpty ? "No models in the list. Add one with +." : "Ready"
    }

    func scheduleAvailabilityRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refreshAvailability() }
    }

    func refreshAvailability() async {
        isCheckingAvailability = true
        let settings = providerSettings
        for provider in ModelProvider.allCases {
            let status = await broker.providerStatus(provider, settings: settings)
            guard !Task.isCancelled else { return }
            unavailability[provider] = .some(status)
        }
        isCheckingAvailability = false
        // Keep the selection on a provider that works.
        if !isAvailable(lastSelection.provider), let first = availableProviders.first {
            lastSelection = ModelSelection(provider: first, model: models(for: first).first ?? "",
                                           effort: ModelSelection.supportedEfforts(provider: first, model: "").contains(.medium) ? .medium : .high)
        }
    }

    /// Models the provider reports, for the + menu.
    func discoverModels(for provider: ModelProvider) async throws -> [String] {
        try await broker.availableModels(for: provider, settings: providerSettings)
    }

    // MARK: Favorites

    func models(for provider: ModelProvider) -> [String] {
        favorites[provider] ?? []
    }

    func add(_ model: String, to provider: ModelProvider) {
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !models(for: provider).contains(name) else { return }
        favorites[provider, default: []].append(name)
    }

    func remove(_ model: String, from provider: ModelProvider) {
        favorites[provider]?.removeAll { $0 == model }
        if lastSelection.provider == provider, lastSelection.model == model {
            lastSelection.model = models(for: provider).first ?? ""
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ defaults: UserDefaults, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

private extension Dictionary {
    func mapKeys<K: Hashable>(_ transform: (Key) -> K) -> [K: Value] {
        Dictionary<K, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
