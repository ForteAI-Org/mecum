import Foundation

public enum ModelProvider: String, Sendable, CaseIterable, Codable, Identifiable {
    case codex, claudeCode, anthropic, gemini, ollama
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: "Codex · ChatGPT"
        case .claudeCode: "Claude · Claude Code"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        }
    }

    /// Models offered before the person edits the favorites. Ollama's come
    /// from the local server instead.
    public var defaultModels: [String] {
        switch self {
        case .codex: ["gpt-5.6-luna", "gpt-5.4-mini"]
        case .claudeCode, .anthropic: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        case .gemini: ["gemini-3-pro-preview", "gemini-3-flash-preview"]
        case .ollama: []
        }
    }

    /// Every model id the provider serves today, for the + menu when the
    /// provider has no listing endpoint. Claude ids from the official models
    /// overview (platform.claude.com, September 2026): current line first,
    /// then the legacy models still available.
    public var knownModels: [String] {
        switch self {
        case .codex: ["gpt-5.6-luna", "gpt-5.4-mini"]
        case .claudeCode, .anthropic: [
            "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
            "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
            "claude-sonnet-4-6", "claude-sonnet-4-5",
        ]
        case .gemini: ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash"]
        case .ollama: []
        }
    }

    /// Where the person gets access, shown next to the key field.
    public var accessHint: String {
        switch self {
        case .codex: "Uses the Codex CLI and your ChatGPT subscription. Sign in with “codex login” in Terminal; no key is stored here."
        case .claudeCode: "Uses the Claude Code CLI and your claude.ai subscription. Sign in with “claude auth login” in Terminal; no key is stored here."
        case .anthropic: "Paste an API key from console.anthropic.com. It is kept in your keychain and sent only to api.anthropic.com."
        case .gemini: "Paste an API key from aistudio.google.com. It is kept in your keychain and sent only to Google's Generative Language API."
        case .ollama: "Runs models on this Mac through the local Ollama server. Pull models with “ollama pull <name>”."
        }
    }

    public var consoleURL: URL? {
        switch self {
        case .codex, .claudeCode: nil
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")
        case .ollama: URL(string: "https://ollama.com/library")
        }
    }
}

/// How hard the model may think. Each provider maps this onto its own knob:
/// Codex and Anthropic take it as reasoning effort, Gemini as thinking level,
/// Ollama as thinking off (`low`) or on (`high`).
public enum ReasoningEffort: String, Sendable, CaseIterable, Codable, Identifiable {
    case low, medium, high, xhigh, max
    public var id: String { rawValue }
    public var title: String { rawValue == "xhigh" ? "XHigh" : rawValue.capitalized }

    /// What the level means for a provider. Ollama only knows thinking on or off.
    public func title(for provider: ModelProvider) -> String {
        guard provider == .ollama else { return title }
        return self == .low ? "No thinking" : "Thinking"
    }
}

/// The model a run is planned with.
public struct ModelSelection: Sendable, Hashable, Codable {
    public var provider: ModelProvider
    public var model: String
    public var effort: ReasoningEffort

    public init(provider: ModelProvider, model: String, effort: ReasoningEffort = .medium) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    /// Efforts a provider/model pair accepts.
    public static func supportedEfforts(provider: ModelProvider, model: String) -> [ReasoningEffort] {
        switch provider {
        case .codex: model == "gpt-5.6-luna" ? ReasoningEffort.allCases : [.low, .medium, .high, .xhigh]
        // Haiku 4.5 has no effort parameter (extended thinking only).
        case .claudeCode, .anthropic: model.contains("haiku") ? [.medium] : ReasoningEffort.allCases
        case .gemini: [.low, .medium, .high]
        case .ollama: [.low, .high]
        }
    }

    public static let `default` = ModelSelection(provider: .codex, model: "gpt-5.6-luna", effort: .medium)
}

/// Keys and knobs the HTTP providers need. The app owns persistence; the
/// kit only reads them for one run.
public struct ProviderSettings: Sendable, Hashable, Codable {
    public var anthropicAPIKey: String
    public var geminiAPIKey: String
    public var ollamaHost: String
    public var ollamaTemperature: Double
    public var ollamaTopP: Double
    public var ollamaTopK: Int
    public var ollamaPresencePenalty: Double
    public var ollamaContextTokens: Int
    public var ollamaMaxOutputTokens: Int
    /// How long one Ollama answer may take. Local thinking models are slow:
    /// a 9B model reasoning over a 12k budget can need several minutes.
    public var ollamaTimeoutSeconds: Double

    /// Defaults follow Qwen's published recommendation for thinking mode on
    /// precise tasks (temperature 0.6, top_p 0.95, top_k 20); thinking tokens
    /// count against the output budget, so it is 8k rather than 1k.
    public init(anthropicAPIKey: String = "", geminiAPIKey: String = "",
                ollamaHost: String = "http://127.0.0.1:11434", ollamaTemperature: Double = 0.6,
                ollamaTopP: Double = 0.95, ollamaTopK: Int = 20, ollamaPresencePenalty: Double = 0,
                ollamaContextTokens: Int = 32768, ollamaMaxOutputTokens: Int = 8192,
                ollamaTimeoutSeconds: Double = 600) {
        self.anthropicAPIKey = anthropicAPIKey
        self.geminiAPIKey = geminiAPIKey
        self.ollamaHost = ollamaHost
        self.ollamaTemperature = ollamaTemperature
        self.ollamaTopP = ollamaTopP
        self.ollamaTopK = ollamaTopK
        self.ollamaPresencePenalty = ollamaPresencePenalty
        self.ollamaContextTokens = ollamaContextTokens
        self.ollamaMaxOutputTokens = ollamaMaxOutputTokens
        self.ollamaTimeoutSeconds = ollamaTimeoutSeconds
    }

    /// Qwen's recommended sampling for a thinking or non-thinking run.
    public mutating func applyQwenRecommendation(thinking: Bool) {
        if thinking {
            ollamaTemperature = 0.6; ollamaTopP = 0.95; ollamaTopK = 20; ollamaPresencePenalty = 0
            ollamaMaxOutputTokens = 8192
        } else {
            ollamaTemperature = 0.7; ollamaTopP = 0.8; ollamaTopK = 20; ollamaPresencePenalty = 1.5
            ollamaMaxOutputTokens = 2048
        }
    }
}

/// What one model call cost, as far as the provider reports it.
public struct ModelUsage: Sendable, Hashable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let duration: Duration

    public init(inputTokens: Int?, outputTokens: Int?, duration: Duration) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.duration = duration
    }

    /// Output tokens per second of generation, when both are known.
    public var tokensPerSecond: Double? {
        guard let outputTokens, outputTokens > 0 else { return nil }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds > 0 ? Double(outputTokens) / seconds : nil
    }
}
