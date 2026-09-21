import Foundation
@testable import LocatorCore

/// The recall path's real failure history, as data. Loaded from
/// `Tests/LocatorCoreTests/Fixtures/misfire-corpus.json`; the human-readable table of the same cases
/// is `docs/misfire-corpus.md`.
///
/// Every case is ONE input phrase against ONE remembered Experience, so what a test built on it
/// asserts is recall POLICY — never which candidate ranked first, and never which internal branch ran.
/// `expected` is the decision recall SHOULD reach; `today` is the decision it reaches as of the
/// corpus's `measured` date. Where the two disagree is exactly where the bug is.
struct MisfireCorpus: Decodable {
    let schema: Int
    let measured: String
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let input: String
        let language: String          // "en" | "it"
        let classKind: String          // deictic | junk | verb-as-entity | antonym | entity-swap | app-swap | exact-replay | paraphrase
        let memory: Memory
        let graph: [String: [String]]?
        let observed: Fired?           // what the engine actually did, when the case was seen in the field
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
        /// Recall must NOT fire. Firing is the bug.
        case wrong
        /// Recall MUST fire, with exactly `expected.args`. Refusing is over-abstention.
        case correct
        /// Recall does not fire today and must never fire WRONG; firing with `expected.args` is an
        /// improvement (lemmatisation, ticket 05), never a regression.
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

    /// `fire` carries the tool + arguments; `abstain` carries neither.
    struct Decision: Decodable, Equatable {
        let decision: Kind
        let tool: String?
        let args: [String: String]?
        enum Kind: String, Decodable { case fire, abstain }
    }

    struct Provenance: Decodable {
        let source: String            // session | live-store | measurement | derived
        let ref: String
        let when: String
        let quote: String
    }

    // MARK: loading

    static let jsonURL = URL(fileURLWithPath: #filePath)      // …/Tests/LocatorCoreTests/Support/MisfireCorpus.swift
        .deletingLastPathComponent()                          // …/Support
        .deletingLastPathComponent()                          // …/LocatorCoreTests
        .appendingPathComponent("Fixtures/misfire-corpus.json")

    /// The human table documents the source application that owns this
    /// corpus. The reusable test fixture lives in Mecum; the application
    /// documentation remains in the sibling forte_locator checkout.
    static let docURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                          // …/Support
        .deletingLastPathComponent()                          // …/LocatorCoreTests
        .deletingLastPathComponent()                          // …/Perception
        .deletingLastPathComponent()                          // …/Tests
        .deletingLastPathComponent()                          // Mecum
        .deletingLastPathComponent()                          // Forte_Projects
        .appendingPathComponent("forte_locator/docs/misfire-corpus.md")

    static func load() throws -> MisfireCorpus {
        try JSONDecoder().decode(MisfireCorpus.self, from: Data(contentsOf: jsonURL))
    }
}

extension MisfireCorpus.Case {
    /// The remembered Experience exactly as the store would hold it — tokens are derived, never
    /// hand-written, so a change to tokenisation moves the corpus with the engine.
    var experience: LocatorMemory.Experience {
        LocatorMemory.Experience(phrase: memory.phrase,
                                 tokens: LocatorMemory.tokens(memory.phrase),
                                 tool: memory.tool,
                                 argsJSON: MisfireCorpus.json(memory.args),
                                 ok: memory.ok, fail: memory.fail)
    }

    var graphContext: LocatorMemory.GraphContext {
        LocatorMemory.GraphContext(sighted: (graph ?? [:]).mapValues { Set($0) })
    }

    /// What recall answers RIGHT NOW for this case — asked of the seam itself, so the corpus tests the
    /// module the spec names rather than one adapter over it.
    func askRecallAnswer() -> Recall.Answer {
        Recall.decide(input: input, in: Recall.World(memories: [experience], graph: graphContext))
    }

    /// The same answer as a `Decision` comparable to `expected`/`today`. A `hint` collapses to
    /// `abstain`: the corpus judges what recall ACTS on, and a hint is not an action.
    func askRecall() -> MisfireCorpus.Decision {
        switch askRecallAnswer() {
        case .fire(let f):
            return MisfireCorpus.Decision(decision: .fire, tool: f.tool,
                                          args: MisfireCorpus.args(f.argsJSON))
        case .hint, .abstain:
            return MisfireCorpus.Decision(decision: .abstain, tool: nil, args: nil)
        }
    }
}

extension MisfireCorpus {
    static func json(_ args: [String: String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: args),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func args(_ json: String) -> [String: String] {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] else { return [:] }
        return o
    }
}
