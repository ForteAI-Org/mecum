//
//  ModelSettingsStore.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Observation

/// Persisted provider settings: the Ollama knobs, the API keys (keychain),
/// what the last check of each connection found, and each provider's
/// catalogue of models.
///
/// Connections, the inspector, the composer and Settings read the same
/// object, so it asks `ProviderCatalog` directly and holds no seat. Nothing is
/// checked at construction; the app checks every connection once at launch
/// (`AppModel`) unless Settings turns that off. A check runs again
/// when a connection card or a model picker appears, when a key or the Ollama
/// address changes, and when a worker is configured. Checking runs the `codex`
/// and `claude` command lines and probes a server.
@Observable
@MainActor
final class ModelSettingsStore {

    private let defaults = UserDefaults.standard

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

    /// What the last check of each connection found. Absent means not checked yet.
    private(set) var states: [ModelProvider: ConnectionState] = [:]

    /// Each provider's models as its catalogue listed them after its last check
    /// that passed. Absent until then, and kept when a later listing fails.
    private(set) var catalogues: [ModelProvider: [ModelInfo]] = [:]

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

    // MARK: Checking

    func isChecking(_ provider: ModelProvider) -> Bool { checks[provider] != nil }

    /// Checks the named connections again, each on its own.
    func refresh(_ providers: [ModelProvider] = ModelProvider.inApp) {
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

                if state.isReady, let listed = try? await ProviderCatalog.catalogue(
                    provider,
                    settings: settings
                ), !Task.isCancelled {
                    catalogues[provider] = listed
                }
                guard !Task.isCancelled else { return }

                checks[provider] = nil
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
            credentialFailure[provider] = "Couldn’t save the API key to Keychain. It will remain available only until you quit Mecum. Try again. Details: \(error)"
        }
        refresh([provider])
    }

    /// Stands `models` in for `provider`'s catalogue, for the offscreen snapshots.
    func recordCatalogue(
        _ models    : [ModelInfo],
        for provider: ModelProvider
    ) {
        catalogues[provider] = models
    }

    /// Lists `provider`'s catalogue now and keeps it, for the profile and the composer's popup.
    func loadCatalogue(for provider: ModelProvider) async throws -> [ModelInfo] {
        let listed = try await ProviderCatalog.catalogue(
            provider,
            settings: providerSettings
        )
        catalogues[provider] = listed
        return listed
    }
}
