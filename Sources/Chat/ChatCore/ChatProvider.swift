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
    /// A web search or page read by the command line's own tool: once as it starts, once as it finishes.
    /// `id` pairs the two when the provider names one. `detail` is the query or the page's address, nil
    /// until the provider says it: Codex names it only as it finishes.
    case web(id: String?, kind: WebKind, detail: String?, phase: WebPhase)
    case completed

    public enum WebKind: Sendable, Equatable {
        case search
        case fetch
    }

    public enum WebPhase: Sendable, Equatable {
        case started
        case finished(failed: Bool)
    }
}
