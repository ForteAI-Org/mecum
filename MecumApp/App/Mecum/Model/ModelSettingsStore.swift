//
//  ModelSettingsStore.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Observation

/// Persisted model preferences: favorite models per provider, provider
/// knobs, API keys (keychain), and what the last check of each connection
/// found. Favorites are what the lab composer's model picker shows.
///
/// It is team state as much as the lab's: the team window's connection cards
/// and worker profiles read the same object, so it asks `ProviderCatalog`
/// directly and holds no seat. Nothing is checked at construction. A check
/// runs when a connection card or a model picker appears, when a key or the
/// Ollama address changes, and when a worker is configured, because checking
/// runs the `codex` and `claude` command lines and probes a server.
@Observable
@MainActor
final class ModelSettingsStore {

    private let defaults = UserDefaults.standard

    var favorites: [ModelProvider: [String]] {
        didSet {
            save(
                favorites.mapKeys { $0.rawValue },
                key: "favorites"
            )
        }
    }

    var anthropicAPIKey: String {
        didSet {
            store(
                anthropicAPIKey,
                for: .anthropic
            )
        }
    }

    var geminiAPIKey: String {
        didSet {
            store(
                geminiAPIKey,
                for: .gemini
            )
        }
    }

    var ollamaHost: String {
        didSet {
            defaults.set(
                ollamaHost,
                forKey: "ollama.host"
            )
            refresh([.ollama])
        }
    }

    var ollamaTemperature: Double {
        didSet {
            defaults.set(
                ollamaTemperature,
                forKey: "ollama.temperature"
            )
        }
    }

    var ollamaTopP: Double {
        didSet {
            defaults.set(
                ollamaTopP,
                forKey: "ollama.topP"
            )
        }
    }

    var ollamaTopK: Int {
        didSet {
            defaults.set(
                ollamaTopK,
                forKey: "ollama.topK"
            )
        }
    }

    var ollamaPresencePenalty: Double {
        didSet {
            defaults.set(
                ollamaPresencePenalty,
                forKey: "ollama.presencePenalty"
            )
        }
    }

    var ollamaContextTokens: Int {
        didSet {
            defaults.set(
                ollamaContextTokens,
                forKey: "ollama.numCtx"
            )
        }
    }

    var ollamaMaxOutputTokens: Int {
        didSet {
            defaults.set(
                ollamaMaxOutputTokens,
                forKey: "ollama.numPredict"
            )
        }
    }

    var ollamaTimeoutSeconds: Double {
        didSet {
            defaults.set(
                ollamaTimeoutSeconds,
                forKey: "ollama.timeout"
            )
        }
    }

    var lastSelection: ModelSelection {
        didSet {
            save(
                lastSelection,
                key: "selection"
            )
        }
    }

    /// What the last check of each connection found. Absent means not checked yet.
    private(set) var states: [ModelProvider: ConnectionState] = [:]

    /// When each of those checks finished.
    private(set) var checkedAt: [ModelProvider: Date] = [:]

    /// Why a key typed for a provider is not in the keychain, nil once it is.
    /// The sentence names the keychain's status, never the key.
    private(set) var credentialFailure: [ModelProvider: String] = [:]

    /// One check in flight per provider. A newer check of the same provider
    /// cancels the older one, and checks of different providers run side by side.
    private var checks: [ModelProvider: Task<Void, Never>] = [:]

    init() {
        let base = ProviderSettings()
        let stored: [String: [String]] = Self.load(
            UserDefaults.standard,
            key: "favorites"
        ) ?? [:]

        favorites = Dictionary(uniqueKeysWithValues: ModelProvider.allCases.map { provider in
            (provider, stored[provider.rawValue] ?? provider.defaultModels)
        })
        anthropicAPIKey       = Keychain.string(for: "anthropic")
        geminiAPIKey          = Keychain.string(for: "gemini")
        ollamaHost            = defaults.string(forKey: "ollama.host") ?? base.ollamaHost
        ollamaTemperature     = defaults.object(forKey: "ollama.temperature") as? Double ?? base.ollamaTemperature
        ollamaTopP            = defaults.object(forKey: "ollama.topP") as? Double ?? base.ollamaTopP
        ollamaTopK            = defaults.object(forKey: "ollama.topK") as? Int ?? base.ollamaTopK
        ollamaPresencePenalty = defaults.object(forKey: "ollama.presencePenalty") as? Double
            ?? base.ollamaPresencePenalty
        ollamaContextTokens   = defaults.object(forKey: "ollama.numCtx") as? Int ?? base.ollamaContextTokens
        ollamaMaxOutputTokens = defaults.object(forKey: "ollama.numPredict") as? Int ?? base.ollamaMaxOutputTokens
        ollamaTimeoutSeconds  = defaults.object(forKey: "ollama.timeout") as? Double ?? base.ollamaTimeoutSeconds
        lastSelection         = Self.load(
            UserDefaults.standard,
            key: "selection"
        ) ?? .default
    }

    var providerSettings: ProviderSettings {
        ProviderSettings(
            anthropicAPIKey      : anthropicAPIKey,
            geminiAPIKey         : geminiAPIKey,
            ollamaHost           : ollamaHost,
            ollamaTemperature    : ollamaTemperature,
            ollamaTopP           : ollamaTopP,
            ollamaTopK           : ollamaTopK,
            ollamaPresencePenalty: ollamaPresencePenalty,
            ollamaContextTokens  : ollamaContextTokens,
            ollamaMaxOutputTokens: ollamaMaxOutputTokens,
            ollamaTimeoutSeconds : ollamaTimeoutSeconds
        )
    }

    /// Qwen's published sampling for thinking on or off, applied to the Ollama knobs.
    func applyQwenRecommendation(thinking: Bool) {
        var settings = providerSettings
        settings.applyQwenRecommendation(thinking: thinking)

        ollamaTemperature     = settings.ollamaTemperature
        ollamaTopP            = settings.ollamaTopP
        ollamaTopK            = settings.ollamaTopK
        ollamaPresencePenalty = settings.ollamaPresencePenalty
        ollamaMaxOutputTokens = settings.ollamaMaxOutputTokens
    }

    // MARK: Availability

    /// A provider is usable when its check passed and it has at least one model to pick.
    func isAvailable(_ provider: ModelProvider) -> Bool {
        states[provider]?.isReady == true && !models(for: provider).isEmpty
    }

    var availableProviders: [ModelProvider] { ModelProvider.allCases.filter(isAvailable) }

    func isChecking(_ provider: ModelProvider) -> Bool { checks[provider] != nil }

    /// The line shown in the lab's Settings: the check's own message, or the missing models.
    func statusText(_ provider: ModelProvider) -> String {
        guard let state = states[provider] else { return isChecking(provider) ? "Checking…" : "Not checked yet" }
        guard state.isReady else { return state.message }

        return models(for: provider).isEmpty ? "No models in the list. Add one with +." : "Ready"
    }

    /// Checks the named connections again, each on its own.
    func refresh(_ providers: [ModelProvider] = ModelProvider.allCases) {
        let settings = providerSettings
        for provider in providers {
            checks[provider]?.cancel()
            checks[provider] = Task {
                let state = await ProviderCatalog.check(
                    provider,
                    settings: settings
                )
                // A newer check of this provider replaced this one; its answer is the one to keep.
                guard !Task.isCancelled else { return }

                states[provider]    = state
                checkedAt[provider] = Date()
                checks[provider]    = nil
                keepSelectionUsable()
            }
        }
    }

    /// Stands `state` in for a check of `provider` that finished at `date`,
    /// for the offscreen snapshots, which draw the connections without
    /// running a command line or reaching the network.
    func recordCheck(
        _ state     : ConnectionState,
        for provider: ModelProvider,
        at date     : Date
    ) {
        states[provider]    = state
        checkedAt[provider] = date
    }

    /// Waits for every check in flight, first starting one for each provider
    /// never checked. The lab's composer asks this before refusing a goal.
    func refreshAndWait() async {
        refresh(ModelProvider.allCases.filter { states[$0] == nil && checks[$0] == nil })
        for check in checks.values { await check.value }
    }

    /// Checks `model` on `provider`'s connection, for a worker configured with it.
    func check(
        _ provider: ModelProvider,
        model     : String
    ) async -> ConnectionState {
        await ProviderCatalog.check(
            provider,
            model   : model,
            settings: providerSettings
        )
    }

    /// Keeps the lab's selection on a provider that works, once every check
    /// has answered: moving it on a partial answer would drop a working choice.
    private func keepSelectionUsable() {
        guard checks.isEmpty, states.count == ModelProvider.allCases.count else { return }

        if !isAvailable(lastSelection.provider), let first = availableProviders.first {
            lastSelection = ModelSelection(
                provider: first,
                model   : models(for: first).first ?? "",
                effort  : ModelSelection.supportedEfforts(
                    provider: first,
                    model   : ""
                ).contains(.medium) ? .medium : .high
            )
        }
    }

    // MARK: Credentials

    /// Whether a key is held for `provider`. Only the API providers have one.
    func hasCredential(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .anthropic:                   !anthropicAPIKey.isEmpty
        case .gemini:                      !geminiAPIKey.isEmpty
        case .codex, .claudeCode, .ollama: false
        }
    }

    /// Puts the key for `provider` in the keychain, or removes it when empty,
    /// and checks the connection again.
    func setCredential(
        _ value     : String,
        for provider: ModelProvider
    ) {
        switch provider {
        case .anthropic:                   anthropicAPIKey = value
        case .gemini:                      geminiAPIKey    = value
        case .codex, .claudeCode, .ollama: return
        }
    }

    private func store(
        _ value     : String,
        for provider: ModelProvider
    ) {
        let reference = ProviderConnection(provider: provider).credentialReference ?? provider.rawValue
        do {
            try Keychain.set(
                value,
                for: reference
            )
            credentialFailure[provider] = nil
        } catch {
            credentialFailure[provider] = "The keychain did not keep the change (\(error)), so the key "
                + "used from now on is the one typed in this session only. Try again."
        }
        refresh([provider])
    }

    /// Models the provider reports, for the + menu.
    func discoverModels(for provider: ModelProvider) async throws -> [String] {
        try await ProviderCatalog.models(
            provider,
            settings: providerSettings
        )
    }

    // MARK: Favorites

    func models(for provider: ModelProvider) -> [String] {
        favorites[provider] ?? []
    }

    func add(
        _ model    : String,
        to provider: ModelProvider
    ) {
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !models(for: provider).contains(name) else { return }

        favorites[provider, default: []].append(name)
    }

    func remove(
        _ model      : String,
        from provider: ModelProvider
    ) {
        favorites[provider]?.removeAll { $0 == model }
        if lastSelection.provider == provider, lastSelection.model == model {
            lastSelection.model = models(for: provider).first ?? ""
        }
    }

    private func save<T: Encodable>(
        _ value: T,
        key    : String
    ) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(
                data,
                forKey: key
            )
        }
    }

    private static func load<T: Decodable>(
        _ defaults: UserDefaults,
        key       : String
    ) -> T? {
        defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(
                T.self,
                from: $0
            )
        }
    }
}

private extension Dictionary {

    func mapKeys<K: Hashable>(_ transform: (Key) -> K) -> [K: Value] {
        Dictionary<K, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
