import Foundation

/// ChatProvider identifies the signed-in CLI responsible for inference and context persistence.
public enum ChatProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String { self == .claude ? "Claude" : "OpenAI / Codex" }
}

/// ProviderEvent distinguishes completion from an interrupted or failed stdout stream.
public enum ProviderEvent: Sendable, Equatable {
    case session(String)
    case assistant(String)
    case activity(String)
    case failure(String)
    /// What the turn cost, once, just before `completed` or `failure`, when the provider reported it.
    case usage(ProviderUsage)
    /// The provider compacted the session's context, with its size in tokens before and after when it said.
    case compacted(preTokens: Int?, postTokens: Int?)
    case completed
}
