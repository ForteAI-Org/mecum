import Foundation

/// THE RECALL SEAM — the one place that decides whether a remembered Experience may replay.
///
/// Recall answers exactly one of three things: `fire` (a tool and its arguments — no model round),
/// `hint` (something worth whispering into the model round, no action), or `abstain` (no action, with a
/// reason). Before this existed the answer was `imitate`'s `Optional`, so "I have nothing" and "I have
/// something I refuse to trust" were the same `nil`, and neither could be narrated.
///
/// The whole world a decision reads arrives as DATA (`World`: remembered Experiences + the entity
/// `Evidence`), so recall is a pure function of a value a test can construct — no store, no session, no
/// driven app. `Tests/LocatorCoreTests/Fixtures/misfire-corpus.json` (the real failure history) is the
/// suite that runs against it.
///
/// Policy lives here, not in the frontends: a frontend decides what to DO with an answer, never whether
/// the answer was trustworthy.
public enum Recall {

    // MARK: - what recall may treat as real

    /// The evidence recall is allowed to call CONCRETE: the app graphs the engine holds, and the entity
    /// cores it has SIGHTED in each. A word that resolves to nothing here is not an entity, however
    /// grammatical it looks — that is the whole content of the gate below.
    public struct Evidence: Sendable {
        public let graph: LocatorMemory.GraphContext
        public init(graph: LocatorMemory.GraphContext = LocatorMemory.GraphContext()) { self.graph = graph }

        /// What a spoken word NAMES, among the apps the engine knows.
        public enum App: Sendable, Equatable {
            case one(String)            // exactly one known app — the only answer that is evidence
            case unknown                // nothing: the word names no app
            case several([String])      // ambiguous, which is not evidence either (the launch tools
                                        // already refuse this and ask for the exact bundle id)
        }

        /// Naming is NOT containment. The word must be a whole bundle-id component or sit at one of its
        /// ends: "premiere" names `com.adobe.premierepro` (prefix) and "resolve" names
        /// `…davinciresolve` (suffix), but "check" does NOT name `com.forte-ai.aafchecker`, because it
        /// sits in the middle of "aafchecker". That distinction is ticket 03's second defect —
        /// substring-of-a-bundle-id was taken for evidence, and an English verb became an app.
        /// Punctuation inside a component is stripped first, so `hylo.aaf-checker` cannot smuggle
        /// "check" back in as the prefix of a "checker" fragment.
        public func app(named word: String) -> App {
            let w = KnowledgeText.normalize(word)
            // Under three characters nothing is a name: "it" is inside "textedit".
            guard w.count >= 3 else { return .unknown }
            let lower = word.lowercased()
            if let exact = graph.sighted.keys.first(where: { $0.lowercased() == lower }) { return .one(exact) }
            let hits = graph.sighted.keys.filter { bundle in
                bundle.split(separator: ".")
                    .map { KnowledgeText.normalize(String($0)) }
                    .contains { $0 == w || $0.hasPrefix(w) || $0.hasSuffix(w) }
            }.sorted()
            switch hits.count {
            case 0: return .unknown
            case 1: return .one(hits[0])
            default: return .several(hits)
            }
        }

        /// Has the engine SIGHTED `value` inside the app that `appWord` names? Sighting identity is the
        /// same core the sighting table stores, so "z Simone" and "simone" are one entity.
        public func sighting(_ value: String, inAppNamed appWord: String) -> Bool {
            guard case .one(let bundle) = app(named: appWord) else { return false }
            return graph.sighted[bundle]?.contains(LocatorMemory.core(value)) == true
        }
    }

    // MARK: - the answer

    public struct Fire: Sendable, Equatable {
        public let tool: String
        public let argsJSON: String
        /// The line a frontend prints on a ⚡ replay ("generalized from \"go to finder\" ✓×2 · → premiere").
        public let note: String
    }

    /// Why recall answered with no action. `refused` names the remembered phrase recall HAD and would
    /// not trust — the difference between "never seen it" (silence is right) and "seen but not trusted"
    /// (the user is owed a sentence).
    public struct Abstention: Sendable, Equatable {
        public let reason: String
        public let refused: String?
        /// The one line to narrate, in the same register as an imitated hit — `nil` when there is
        /// nothing to say, which is every turn the engine simply has no memory of.
        public var narration: String? { refused == nil ? nil : "memory: \(reason)" }
    }

    public enum Answer: Sendable, Equatable {
        case fire(Fire)
        case hint(String)
        case abstain(Abstention)
    }

    /// Everything a decision reads. Construct one by hand in a test; `live()` is the only edge that
    /// touches the process-wide store.
    public struct World: Sendable {
        public let memories: [LocatorMemory.Experience]
        public let evidence: Evidence

        public init(memories: [LocatorMemory.Experience], evidence: Evidence) {
            self.memories = memories
            self.evidence = evidence
        }

        public init(memories: [LocatorMemory.Experience],
                    graph: LocatorMemory.GraphContext = LocatorMemory.GraphContext()) {
            self.init(memories: memories, evidence: Evidence(graph: graph))
        }

        /// The living memory as it stands right now — the seam's one impure edge.
        public static func live(limit: Int = 50) -> World {
            World(memories: LocatorMemory.shared.recentExperiences(limit: limit),
                  graph: LocatorMemory.shared.graphContext())
        }
    }

    // MARK: - the decision

    /// Match `input` against remembered Experiences and answer once. Exact token match replays as-is;
    /// a one-token difference substitutes into the remembered arguments; an extra token naming another
    /// app graph retargets the verb there. Every SUBSTITUTED slot must then pass the entity-evidence
    /// gate, or recall abstains and says why.
    public static func decide(input: String, in world: World) -> Answer {
        let inToks = Set(LocatorMemory.tokens(input))
        guard !inToks.isEmpty else {
            return .abstain(Abstention(reason: "nothing to match on in \"\(input)\"", refused: nil))
        }
        var refusal: Abstention?
        for m in world.memories where m.ok > m.fail && m.tool != "send_message" {
            switch consider(m, inToks: inToks, evidence: world.evidence) {
            case .fire(let f):
                return .fire(f)
            case .refuse(let a):
                // Keep looking: a DIFFERENT memory may still earn its replay. The first refusal is what
                // we tell the user if none does — refusing one candidate is not refusing the turn.
                if refusal == nil { refusal = a }
            case .noMatch:
                continue
            }
        }
        if let refusal { return .abstain(refusal) }
        if let h = LocatorMemory.hint(input: input, from: world.memories) { return .hint(h) }
        return .abstain(Abstention(reason: "nothing remembered matches \"\(input)\"", refused: nil))
    }

    private enum Candidate {
        case fire(Fire)
        case refuse(Abstention)
        case noMatch
    }

    private static func consider(_ m: LocatorMemory.Experience, inToks: Set<String>,
                                 evidence: Evidence) -> Candidate {
        let memToks = Set(m.tokens)
        // Exact replay: nothing is substituted, so there is nothing for the gate to judge.
        if memToks == inToks {
            return .fire(Fire(tool: m.tool, argsJSON: m.argsJSON,
                              note: "remembered: \"\(m.phrase)\" ✓×\(m.ok)"))
        }
        var onlyMem = memToks.subtracting(inToks)
        var onlyIn = inToks.subtracting(memToks)
        // Cross-graph hop: an extra token naming a KNOWN app graph retargets the verb there ("call
        // michele on whatsapp" from a slack-learned "call simone"). App words on either side leave the
        // entity diff; whether the hop is EVIDENCED is settled below, not here — this only nominates a
        // candidate, and a nominee is not a fact.
        var hopToken: String?
        if let t = onlyIn.first(where: { !evidence.graph.bundles(matching: $0).isEmpty }) {
            hopToken = t; onlyIn.remove(t)
            if let o = onlyMem.first(where: { !evidence.graph.bundles(matching: $0).isEmpty }) { onlyMem.remove(o) }
        }
        let pureHop = hopToken != nil && onlyMem.isEmpty && onlyIn.isEmpty
        let oneSwap = onlyMem.count == 1 && onlyIn.count == 1
        guard pureHop || oneSwap else { return .noMatch }
        guard let data = m.argsJSON.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return .noMatch }

        var swapNote = ""
        // Which slots recall FILLED ITSELF — by slot, so a slot written twice is judged on the value the
        // call would actually carry, never on a value that was overwritten before it could be used.
        var substituted: [String: String] = [:]
        if oneSwap {
            // substitute the changed entity in the remembered args (values are lowercase words here)
            guard let old = onlyMem.first, let new = onlyIn.first else { return .noMatch }
            for (k, v) in obj where LocatorMemory.core(v) == LocatorMemory.core(old) {
                obj[k] = new
                substituted[k] = new
            }
            guard !substituted.isEmpty else { return .noMatch }
            swapNote = ": \(old) → \(new)"
        }
        if let hop = hopToken {
            // The hop's own gate, unchanged: the remembered args must mean something in the TARGET
            // graph — the hop is powered by seeing the other part of the graph, never guessed.
            let targets = evidence.graph.bundles(matching: hop)
            let entities = obj.filter { $0.key != "app" }.map(\.value)
            if !entities.isEmpty {
                guard entities.contains(where: { v in
                    targets.contains { evidence.graph.sighted[$0]?.contains(LocatorMemory.core(v)) == true }
                }) else {
                    return .refuse(refusal(m, "nothing from \"\(m.phrase)\" has been seen in \(hop)"))
                }
            }
            // A hop that overwrites a value the swap just wrote would DROP the word the user said —
            // the call would carry the hop and no trace of the difference that earned the match. An
            // argument nobody asked for is the same class of mistake as a slot filled with a pronoun.
            if let dropped = substituted["app"], dropped != hop {
                return .refuse(refusal(m, "\"\(dropped)\" would be dropped, not used"))
            }
            obj["app"] = hop
            substituted["app"] = hop
            swapNote += " · → \(hop)"
        }
        // THE ENTITY-EVIDENCE GATE. Every slot recall FILLED ITSELF must name something concrete; the
        // slots the memory already held are the memory's business, not the gate's.
        for (slot, value) in substituted.sorted(by: { $0.key < $1.key }) {   // stable narration
            if let why = unevidenced(slot: slot, value: value, args: obj, evidence: evidence) {
                return .refuse(refusal(m, why))
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: out, encoding: .utf8) else { return .noMatch }
        return .fire(Fire(tool: m.tool, argsJSON: json,
                          note: "generalized from \"\(m.phrase)\" ✓×\(m.ok)\(swapNote)"))
    }

    private static func refusal(_ m: LocatorMemory.Experience, _ why: String) -> Abstention {
        Abstention(reason: "remembered \"\(m.phrase)\" ✓×\(m.ok), but \(why)", refused: m.phrase)
    }

    /// Slots that name an APP rather than something inside one. Their evidence is the app graph itself.
    private static let appShapedSlots: Set<String> = ["app", "bundle", "bundle_id"]

    /// The gate, as one sentence: an app-shaped slot must name exactly one app in the graph, and any
    /// other slot must name something SIGHTED inside the app the call targets. Returns why the value
    /// fails, or `nil` when it is evidenced.
    private static func unevidenced(slot: String, value: String, args: [String: String],
                                    evidence: Evidence) -> String? {
        if appShapedSlots.contains(slot) {
            switch evidence.app(named: value) {
            case .one: return nil
            case .unknown: return "\"\(value)\" names no app I know"
            case .several(let bundles): return "\"\(value)\" could be any of \(bundles.count) apps I know"
            }
        }
        guard let appValue = args["app"] ?? args["bundle"], !appValue.isEmpty else {
            return "\"\(value)\" is in no app I can check"
        }
        guard evidence.sighting(value, inAppNamed: appValue) else {
            return "I have never seen \"\(value)\" in \(appValue)"
        }
        return nil
    }
}
