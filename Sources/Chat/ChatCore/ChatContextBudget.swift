/// ChatContextBudget limits how much accumulated tool history an agent carries before summarizing.
/// The complete visible transcript is retained. Unknown usage never triggers speculative compaction.
public enum ChatContextBudget {
    /// A latency budget, independent of a model's larger maximum context capacity.
    public static let preferredTokens = 64_000

    /// Uses the smaller of the latency budget and 90 percent of a known model window.
    public static func shouldCompact(usedTokens: Int?, windowTokens: Int?) -> Bool {
        guard let usedTokens, usedTokens > 0 else { return false }
        let threshold: Int
        if let windowTokens, windowTokens > 0 {
            threshold = min(preferredTokens, max(1, Int(Double(windowTokens) * 0.9)))
        } else { threshold = preferredTokens }
        return usedTokens >= threshold
    }
}
