//
//  MisfireCorpus.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import Memory

/// MisfireCorpus is the recall path's real failure history, as data, loaded from the bundled
/// `misfire-corpus.json`; the human table of the same cases is `misfire-corpus.md` beside it. Every
/// case is one input phrase against one remembered experience, so a test built on it asserts recall
/// policy, never candidate ranking. `expected` is what recall should answer; `today` is what it did
/// answer as of the corpus's measured date.
struct MisfireCorpus: Decodable {

    let schema: Int
    let measured: String
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let input: String
        let language: String
        let classKind: String
        let memory: Memory
        let graph: [String: [String]]?
        let observed: Fired?
        let verdict: Verdict
        let why: String
        let expected: Decision
        let today: Decision
        let provenance: [Provenance]
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case id, input, language, memory, graph, observed, verdict, why, expected, today, provenance, notes
            case classKind = "class"
        }
    }

    enum Verdict: String, Decodable {
        /// Recall must not fire.
        case wrong
        /// Recall must fire with exactly the expected arguments.
        case correct
        /// Recall does not fire today and must never fire wrong; firing correctly is an improvement.
        case watch
    }

    struct Memory: Decodable {
        let phrase: String
        let tool: String
        let args: [String: String]
        let ok: Int
        let fail: Int
    }

    struct Fired: Decodable {
        let tool: String?
        let args: [String: String]?
        let outcome: String?
        let engineSaid: String?

        enum CodingKeys: String, CodingKey { case tool, args, outcome, engineSaid = "engine_said" }
    }

    /// `fire` carries the tool and arguments; `abstain` carries neither.
    struct Decision: Decodable, Equatable {
        let decision: Kind
        let tool: String?
        let args: [String: String]?

        enum Kind: String, Decodable { case fire, abstain }

        static let abstain = Decision(decision: .abstain, tool: nil, args: nil)
    }

    struct Provenance: Decodable {
        let source: String
        let ref: String
        let when: String
        let quote: String
    }

    static func load() throws -> MisfireCorpus {
        try JSONDecoder().decode(MisfireCorpus.self, from: Data(contentsOf: Fixtures.url("misfire-corpus", "json")))
    }

    static func humanTable() throws -> String {
        try String(contentsOf: Fixtures.url("misfire-corpus", "md"), encoding: .utf8)
    }
}

extension MisfireCorpus.Case {

    /// The remembered experience as the store would hold it; tokens are derived, never hand-written.
    var experience: Experience {
        Experience(phrase: memory.phrase, tool: memory.tool, argsJSON: MisfireCorpus.json(memory.args),
                   ok: memory.ok, fail: memory.fail)
    }

    var sightingGraph: SightingGraph {
        SightingGraph(sighted: (graph ?? [:]).mapValues { Set($0) })
    }

    /// What recall answers right now for this case.
    func askRecallAnswer() -> Recall.Answer {
        Recall.decide(input: input, in: Recall.World(memories: [experience], graph: sightingGraph))
    }

    /// The same answer as a decision comparable to `expected` and `today`. A hint collapses to abstain:
    /// the corpus judges what recall acts on.
    func askRecall() -> MisfireCorpus.Decision {
        switch askRecallAnswer() {
            case .fire(let fire):
                return MisfireCorpus.Decision(decision: .fire, tool: fire.tool, args: MisfireCorpus.args(fire.argsJSON))
            case .hint, .abstain:
                return .abstain
        }
    }
}

extension MisfireCorpus {

    static func json(_ args: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func args(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return object
    }
}
