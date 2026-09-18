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
    /// phrasing still fully covers a short memory.
    public static func hint(input: String, from memories: [Experience]) -> String? {
        let inputTokens = Set(GoalPhrase.tokens(input))
        guard !inputTokens.isEmpty else { return nil }
        var best: (coverage: Double, memory: Experience)?
        for memory in memories where memory.ok > 0 && !memory.tokens.isEmpty {
            let hits = Set(memory.tokens).intersection(inputTokens).count
            let coverage = Double(hits) / Double(memory.tokens.count)
            if hits >= 2, coverage >= 0.75, coverage > (best?.coverage ?? 0) { best = (coverage, memory) }
        }
        guard let best else { return nil }
        let memory = best.memory
        return "[memory: \"\(memory.phrase)\" was solved by \(memory.tool)(\(memory.argsJSON)), worked \(memory.ok)×]"
    }
}
