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

    /// Models the provider reports as available to this account or server, by id; see `catalogue`.
    public static func models(_ provider: ModelProvider, settings: ProviderSettings) async throws -> [String] {
        try await catalogue(provider, settings: settings).map(\.id)
    }

    /// Models the local Ollama server has pulled, for a host that is not the
    /// one in the settings yet.
    public static func ollamaModels(host: String) async throws -> [String] {
        try await OllamaClient.models(host: host)
    }
}
