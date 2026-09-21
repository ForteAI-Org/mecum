import Foundation
@testable import LocatorCore

/// The real turns that minted Routes, as data. Loaded from
/// `Tests/LocatorCoreTests/Fixtures/route-corpus.json`.
///
/// Every case is ONE turn from a driving session: the outcome word the engine printed for each tool
/// call, how many steps the auto-save stored, and the model's final answer verbatim. What a test built
/// on it asserts is route-earning POLICY — whether that turn deserved a procedure — never which guard
/// happened to be consulted first.
struct RouteCorpus: Decodable {
    let schema: Int
    let measured: String
    let turns: [Turn]
    let corrections: [CorrectionCase]

    struct Turn: Decodable {
        let id: String
        let app: String
        let phrase: String
        let steps: Int
        let tape: [TapeEntry]
        let answer: String
        let expected: Expected
        let caughtBy: CaughtBy
        let why: String
        let provenance: [Provenance]
    }

    struct TapeEntry: Decodable {
        let tool: String
        let kind: String
        var outcome: RouteEarning.Outcome { RouteEarning.Outcome(tool: tool, kind: kind) }
    }

    enum Expected: String, Decodable { case recorded, withheld }

    /// Which guard must catch a withheld turn — `outcomes` (the span was not clean) or `answer` (the
    /// model handed the work back). `none` belongs to a turn that must still be learned.
    enum CaughtBy: String, Decodable { case outcomes, answer, none }

    struct CorrectionCase: Decodable {
        let id: String
        let text: String
        let language: String
        let isCorrection: Bool
        let why: String
        let provenance: [Provenance]
    }

    struct Provenance: Decodable {
        let source: String            // session | live-store | derived
        let ref: String
        let when: String
        let quote: String
    }

    static let jsonURL = URL(fileURLWithPath: #filePath)      // …/Tests/LocatorCoreTests/Support/RouteCorpus.swift
        .deletingLastPathComponent()                          // …/Support
        .deletingLastPathComponent()                          // …/LocatorCoreTests
        .appendingPathComponent("Fixtures/route-corpus.json")

    static func load() throws -> RouteCorpus {
        try JSONDecoder().decode(RouteCorpus.self, from: Data(contentsOf: jsonURL))
    }
}

extension RouteCorpus.Turn {
    /// What the engine decides for this turn's span — the same call `save_route` makes.
    var outcomeVerdict: RouteEarning.Verdict {
        RouteEarning.verdict(over: RouteEarning.span(of: tape.map(\.outcome), steps: steps))
    }

    /// Whether the final answer lets this turn keep what it did.
    var answerEarns: Bool { RouteEarning.answerEarnsARoute(answer) }

    /// Both guards together: a Route is recorded only when nothing withholds it.
    var recorded: Bool {
        if case .withheld = outcomeVerdict { return false }
        return answerEarns
    }
}
