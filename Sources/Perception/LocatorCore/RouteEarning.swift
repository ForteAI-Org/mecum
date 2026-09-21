import Foundation

/// THE ROUTE-EARNING SEAM — the one place that decides whether a turn EARNED a procedure, and whether
/// the user's next turn takes it back.
///
/// A Route is a Belief (`CONTEXT.md`), so ADR 0001 governs it: only a Proof may create one, and a
/// Contradiction retracts it. Before this existed a Route was written whenever a turn ended, with no
/// notion of whether the user's goal was met — so three real sessions taught the engine to replay the
/// metronome toggle it mistook for un-soloing, an attempt that never applied a grade, and Ron's own
/// correction ("you went to next, not previous"), steps and all.
///
/// Two guards, because the two failures look nothing alike:
///
///  • **The outcome span** (`verdict(over:)`) — the outcomes the route's own steps cover. A turn that
///    found its way by trial and error (a miss, an ambiguity, an unverified effect, a refusal) did not
///    prove a procedure; it proved the model was lost. Scoped to the STORED steps, so a false start
///    before the route begins is not held against it.
///  • **The answer** (`answerEarnsARoute(_:)`) — a turn whose final answer hands the work back to the
///    user ("here is how you can set it…") did not do the thing, however cleanly its clicks landed.
///    This is the only guard that sees the mexican-yellow case: two clicks that both worked, and no
///    grade applied.
///
/// Everything here is a pure function of values a test can construct — no store, no session, no driven
/// app. `Tests/LocatorCoreTests/Fixtures/route-corpus.json` (the real turns that minted the garbage) is
/// the suite that runs against it.
public enum RouteEarning {

    // MARK: - what a turn did

    /// One acting tool result, as the engine reported it: the tool called and the outcome word it
    /// printed. Reads print no outcome word and never reach the tape.
    public struct Outcome: Equatable, Sendable {
        public let tool: String
        public let kind: String
        public init(tool: String, kind: String) { self.tool = tool; self.kind = kind }
    }

    public enum Verdict: Equatable, Sendable {
        /// The turn proved a procedure; `proof` is what proved it, stored on the Route (ADR 0001: a
        /// Belief must be able to say what earned it).
        case earned(proof: String)
        /// Nothing is written. `reason` is the sentence the operator sees.
        case withheld(reason: String)
    }

    /// The tools a Route is MADE of — the ones that both trace a replayable step and re-dispatch
    /// deterministically. Only these can condemn a route: an `honest_miss` from an API probe says the
    /// API is off, not that the procedure is wrong.
    public static let structuralTools: Set<String> = ["act", "run_menu", "reach", "type", "go_to_folder"]

    /// Outcome words that mean the goal was NOT reached on that call.
    public static let failingKinds: Set<String> = ["honest_miss", "acted_unverified", "ambiguous", "refused"]

    /// Every outcome word the engine prints as the first token of a result. Anything else on the front
    /// of a tool result is prose (a scene map, a listing) and is not an outcome at all.
    public static let outcomeKinds: Set<String> =
        ["found_acted", "acted_unverified", "acted_noop", "honest_miss", "refused", "ambiguous", "dry_run"]

    /// The outcome word of a tool result, or nil when the result is not an outcome (a read's map text).
    public static func outcomeKind(ofResult text: String) -> String? {
        let head = String(text.prefix(while: { $0 != ":" && !$0.isNewline }))
        return outcomeKinds.contains(head) ? head : nil
    }

    /// The slice of the tape the route covers: from the outcome of its FIRST stored step to the end.
    /// A route stores the last `steps` verified structural acts, so anything before them belongs to the
    /// model's search rather than to the procedure (measured: 'can you change it to ron4' opened with
    /// an ambiguity, then did four clean steps — the ambiguity is not the route's fault).
    public static func span(of tape: [Outcome], steps: Int) -> [Outcome] {
        guard steps > 0, !tape.isEmpty else { return tape }
        var counted = 0
        var start = 0
        for i in stride(from: tape.count - 1, through: 0, by: -1) where isVerifiedStep(tape[i]) {
            counted += 1
            if counted == steps { start = i; break }
        }
        return Array(tape[start...])
    }

    /// Did the turn earn a Route over this span?
    public static func verdict(over span: [Outcome]) -> Verdict {
        let failures = span.filter { failingKinds.contains($0.kind) && (structuralTools.contains($0.tool) || $0.kind == "refused") }
        if !failures.isEmpty {
            let tally = Dictionary(grouping: failures, by: \.kind)
                .map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: ", ")
            return .withheld(reason: "the run was not clean — \(tally) inside the route's own steps. A Route is earned by a verified goal, not found by trial and error.")
        }
        let acts = span.filter(isVerifiedStep).count
        guard acts >= RoutePolicy.minimumRouteSteps else {
            return .withheld(reason: "only \(acts) verified step\(acts == 1 ? "" : "s") — a Route is a procedure of at least \(RoutePolicy.minimumRouteSteps).")
        }
        return .earned(proof: "\(acts) verified steps, none missed or unverified")
    }

    private static func isVerifiedStep(_ o: Outcome) -> Bool {
        o.kind == "found_acted" && structuralTools.contains(o.tool)
    }

    // MARK: - the answer

    /// Phrases with which a model hands the job back to the user. A BLOCKLIST, deliberately: the
    /// inverse design (require a completion claim) withholds every answer phrased in a language or a
    /// register we failed to enumerate, and the engine answers in whatever language it was asked in.
    /// Every entry below is a phrase taken from a real answer that produced a garbage Route.
    private static let handbackMarkers: [String] = [
        "here is how you can", "here s how you can", "here is how to", "here s how to",
        "you can easily", "you can do it yourself", "you will need to", "you ll need to",
        "i can t", "i cannot", "i am unable", "i m unable", "unable to",
        // Italian — Ron drives in both languages and the model answers in kind.
        "ecco come puoi", "puoi farlo tu", "non posso", "non sono in grado", "dovrai",
    ]

    /// Does the turn's final answer let it keep what it did? False when the answer explains how the
    /// USER could do the thing — a turn that gives instructions did not carry them out.
    public static func answerEarnsARoute(_ answer: String) -> Bool {
        let phrase = padded(answer)
        return !handbackMarkers.contains { phrase.contains(" \($0) ") }
    }

    // MARK: - the correction

    /// A user turn that says the previous one was wrong. Carries the trigger that matched, so the
    /// narration and the stored demotion cause can both quote what was actually said.
    public struct Correction: Equatable, Sendable {
        public let trigger: String
        public let text: String
        public init(trigger: String, text: String) { self.trigger = trigger; self.text = text }
    }

    /// An explicit negation of what the engine just did, in the second person or as a flat verdict.
    /// Every entry is a phrase from a real correction in the live store.
    private static let correctionPhrases: [String] = [
        "not that", "wrong", "you went", "you did not", "you didn t", "you should have",
        "you were supposed", "i said", "didn t say", "that s not", "thats not", "it s not",
        "not what i",
        // Italian.
        "non e", "non hai", "non ha", "non era", "sbagliato", "sbagliata", "non quello",
        "non cosi", "ti ho detto", "avevo detto", "non va bene", "non funziona",
    ]

    /// A turn that OPENS with one of these is a correction whatever follows it ("no in fpost we had
    /// another aaf…"). Only in first position: "now" is not "no", and "no fade" mid-sentence is not a
    /// verdict on the engine.
    private static let openingNegations: Set<String> = ["no", "nope", "nah", "non"]

    /// Does this user turn RETRACT what the last one did?
    ///
    /// CONSERVATIVE by construction, and asymmetrically so: a false positive silently deletes a
    /// procedure the engine earned, a false negative merely keeps a stale one that the next replay
    /// failure will demote anyway. So this reads only explicit negations and reproaches — never a
    /// re-ask, never a follow-up question, never "if you click the numbers you can do it" (a real
    /// correction the corpus records as deliberately missed).
    public static func correction(in userTurn: String) -> Correction? {
        let words = KnowledgeText.tokens(fold(userTurn))
        guard !words.isEmpty else { return nil }
        let phrase = " " + words.joined(separator: " ") + " "
        if let hit = correctionPhrases.first(where: { phrase.contains(" \($0) ") }) {
            return Correction(trigger: hit, text: userTurn)
        }
        if openingNegations.contains(words[0]) {
            return Correction(trigger: words[0], text: userTurn)
        }
        return nil
    }

    // MARK: - text

    /// Diacritic-folded, so "non è quello" and "non e quello" are the same sentence.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func padded(_ s: String) -> String {
        " " + KnowledgeText.tokens(fold(s)).joined(separator: " ") + " "
    }
}
