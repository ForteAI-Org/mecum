//
//  RouteCorpus.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import Memory

/// RouteCorpus is the real turns that minted routes, as data, loaded from the bundled
/// `route-corpus.json`. Every case is one turn from a driving session: the outcome kind the engine
/// printed for each call, how many steps the auto-save stored, and the model's final answer verbatim.
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

        var outcome: RouteEarning.Outcome? {
            ActOutcomeKind(rawValue: kind).map { RouteEarning.Outcome(tool: tool, kind: $0) }
        }
    }

    enum Expected: String, Decodable { case recorded, withheld }

    /// Which guard must catch a withheld turn: `outcomes` (the span was not clean) or `answer` (the
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
        let source: String
        let ref: String
        let when: String
        let quote: String
    }

    static func load() throws -> RouteCorpus {
        try JSONDecoder().decode(RouteCorpus.self, from: Data(contentsOf: Fixtures.url("route-corpus", "json")))
    }
}

extension RouteCorpus.Turn {

    var outcomes: [RouteEarning.Outcome] { tape.compactMap(\.outcome) }

    /// What the engine decides for this turn's span, the same call the route save makes.
    var outcomeVerdict: RouteEarning.Verdict {
        RouteEarning.verdict(over: RouteEarning.span(of: outcomes, steps: steps))
    }

    var answerEarns: Bool { RouteEarning.answerEarnsARoute(answer) }

    /// A route is recorded only when nothing withholds it.
    var recorded: Bool {
        if case .withheld = outcomeVerdict { return false }
        return answerEarns
    }
}
