//
//  MemoryHint.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// MemoryHint is the best partial match worth whispering into a model round: a remembered phrase the
/// input covers well enough to mention, not well enough to act on.
public enum MemoryHint {

    /// The hint line, or nil. Coverage is of the remembered phrase, not of the input, so a chatty
    /// phrasing still fully covers a short memory. Only a trustworthy memory is hinted, the same rule
    /// recall replays by, so a memory refused as unreliable never comes back as a positive hint.
    public static func hint(input: String, from memories: [Experience]) -> String? {
        let inputTokens = Set(GoalPhrase.tokens(input))
        guard !inputTokens.isEmpty else { return nil }
        var best: (coverage: Double, memory: Experience)?
        for memory in memories where memory.isTrustworthy {
            guard let coverage = coverage(of: memory.tokens, by: inputTokens) else { continue }
            if coverage > (best?.coverage ?? 0) { best = (coverage, memory) }
        }
        guard let best else { return nil }
        let memory = best.memory
        return "[memory: \"\(memory.phrase)\" was solved by \(memory.tool)(\(memory.argsJSON)), worked \(memory.ok)×]"
    }

    /// How much of a remembered phrase's goal tokens the input covers, when it is enough to mention:
    /// at least two shared tokens and three quarters of the remembered ones. Nil otherwise.
    public static func coverage(of memoryTokens: [String], by inputTokens: Set<String>) -> Double? {
        guard !memoryTokens.isEmpty else { return nil }
        let hits = Set(memoryTokens).intersection(inputTokens).count
        let coverage = Double(hits) / Double(memoryTokens.count)
        return hits >= 2 && coverage >= 0.75 ? coverage : nil
    }
}
