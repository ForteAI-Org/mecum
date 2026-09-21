import Foundation

// PROCEDURAL MEMORY (learn-from-use): when the agent achieves a goal, the verb sequence that worked is
// saved as a named ROUTE — and next time the same goal is asked, it replays deterministically in one
// tool call instead of N model rounds. Completes the learning trio: the brain knows OBJECTS (anchors),
// TRANSITIONS (click X → menu opens); routes know PROCEDURES ("simone chat" = click '¿ Simone').
//
// Invariants (same spine as everything else):
//  • A step stores SEMANTIC TARGETS (labels / menu paths) — NEVER coordinates. Replay re-dispatches
//    through the same gated verbs (act/run_menu/reach/type), which re-perceive live every time.
//  • Typed TEXT is never stored (user content); a type step may only be the Return-only confirm.
//  • Replay passes every gate again (allowlist, destructive, ambiguity) — a route is a shortcut for
//    the MODEL, never a bypass of policy.
//  • Evidence + failure bookkeeping: reuse strengthens a route; repeated failure forgets it (UIs change).

/// One replayable step — a verb call by semantic target.
public struct RouteStep: Codable, Equatable, Sendable {
    public var tool: String        // "act" | "run_menu" | "reach" | "type" | "focus_app" | "launch_app"
    public var target: String?     // act/reach target; type's optional focus target; focus_app's app
    public var verb: String?       // act: "click" | "set_toggle"
    public var value: String?      // act set_toggle: "on" | "off"
    public var path: String?       // run_menu path ("File > Export" or a single component)
    public var submit: Bool?       // type: press Return (the only type step allowed — no text is ever stored)
    public var expect: String?     // effect FAMILY observed when learned (a verification hint, not a gate)
    /// Letters-family of the WINDOW TITLE after this step ran when learned — the last step's value is the
    /// route's END STATE, which makes replay IDEMPOTENT: "go to simone" when already on Simone is a noop,
    /// not a doomed re-click through the sidebar (measured: the replay navigated AWAY then failed).
    public var afterTitle: String?

    public init(tool: String, target: String? = nil, verb: String? = nil, value: String? = nil,
                path: String? = nil, submit: Bool? = nil, expect: String? = nil, afterTitle: String? = nil) {
        self.tool = tool; self.target = target; self.verb = verb; self.value = value
        self.path = path; self.submit = submit; self.expect = expect; self.afterTitle = afterTitle
    }

    /// Identity of the ACTION itself (ignores observational fields like afterTitle/expect) — used to
    /// decide whether a re-saved route is "the same way" (evidence++) or a new procedure (reset).
    public var actionKey: String {
        [tool, target ?? "", verb ?? "", value ?? "", path ?? "", submit == true ? "⏎" : ""].joined(separator: "|")
    }

    /// Human-readable one-liner ("act click 'Elimina messaggio...'").
    public var summary: String {
        switch tool {
        case "act": return "act \(verb ?? "click") '\(target ?? "?")'\(value.map { " → \($0)" } ?? "")"
        case "run_menu": return "run_menu '\(path ?? "?")'"
        case "reach": return "reach '\(target ?? "?")'"
        case "type": return "press Return\(target.map { " (focus '\($0)')" } ?? "")"
        case "focus_app": return "focus app '\(target ?? "?")'"
        default: return tool
        }
    }
}

/// A named, replayable procedure learned from a successful use.
///
/// A Route is a BELIEF (`CONTEXT.md`), so ADR 0001 governs it: only a Proof may create one (`proof`
/// records what earned it — see `RouteEarning`), a Contradiction demotes it, and demotion never
/// erases. The corpse is what makes the next audit possible: `demotedAt`/`demotionCause` keep the
/// steps and say who contradicted them.
public struct Route: Codable, Equatable, Sendable {
    public var name: String
    public var steps: [RouteStep]
    public var evidence: Int           // independent confirmations (1 at learn)
    public var failStreak: Int         // consecutive replay failures — ≥2 demotes the route
    public var firstLearned: Date
    public var lastUsed: Date
    /// What VERIFIED the goal when this route was written ("4 verified steps, none missed"). Absent on
    /// rows written before routes had to be earned.
    public var proof: String?
    /// When a Contradiction retracted it — a replay that failed twice, the user's correction, or the
    /// retrofit sweep. Non-nil means: kept, readable, never replayed.
    public var demotedAt: Date?
    /// What contradicted it, verbatim where the user said it.
    public var demotionCause: String?

    public init(name: String, steps: [RouteStep], evidence: Int = 1, failStreak: Int = 0,
                firstLearned: Date, lastUsed: Date, proof: String? = nil,
                demotedAt: Date? = nil, demotionCause: String? = nil) {
        self.name = name; self.steps = steps; self.evidence = evidence; self.failStreak = failStreak
        self.firstLearned = firstLearned; self.lastUsed = lastUsed; self.proof = proof
        self.demotedAt = demotedAt; self.demotionCause = demotionCause
    }

    /// Was this Route ever earned? `proof` is the answer for anything written under the law. The
    /// evidence clause is a GRANDFATHER for the rows that predate it: a pre-law route the engine
    /// independently confirmed at least once has the substance of a Proof even though nobody wrote it
    /// down; one that fired once and was never seen again has nothing.
    public var isEarned: Bool { proof != nil || evidence >= RoutePolicy.confirmationsInsteadOfProof }

    /// May the engine ACT on this route? Actionability is what a Contradiction removes — never the row.
    public var isActionable: Bool {
        demotedAt == nil && failStreak < RoutePolicy.forgetAfterFails && isEarned
    }

    /// Retract this Belief. The FIRST cause is the true one — a route already demoted keeps the reason
    /// it was demoted for, and a later contradiction does not overwrite the history.
    mutating func demote(cause: String, now: Date) -> Bool {
        guard demotedAt == nil else { return false }
        demotedAt = now
        demotionCause = cause
        return true
    }

    /// Route names are GOAL phrases ("go to simone") and queries are too ("simone chat") — filler words
    /// must not count against the match (measured: "Simone chat" scored 0.5 vs 'go to simone' and missed,
    /// though it's obviously the same goal). Score on CONTENT tokens; fall back to the raw phrase when
    /// filtering empties one side.
    public func matchScore(query: String) -> Double {
        let q = Route.contentPhrase(query), n = Route.contentPhrase(name)
        let filtered = (q.isEmpty || n.isEmpty) ? 0 : KnowledgeText.matchScore(query: q, against: n)
        return max(filtered, KnowledgeText.matchScore(query: query, against: name))
    }

    /// English + Italian navigation filler that carries no goal content.
    static let stopwords: Set<String> = ["go", "to", "open", "the", "a", "an", "in", "on", "at", "of",
                                         "my", "and", "with", "vai", "apri", "su", "nel", "nella", "il",
                                         "la", "lo", "le", "da", "di", "e", "con", "al", "alla",
                                         // messaging-domain filler: "simone chat" ≡ "go to simone"
                                         "chat", "chats", "conversation", "conversazione", "message",
                                         "messages", "messaggio", "messaggi", "dm"]
    static func contentPhrase(_ s: String) -> String {
        KnowledgeText.tokens(s).filter { !stopwords.contains($0) }.joined(separator: " ")
    }

    /// The route's learned END STATE (letters-family window title after the final step), if recorded.
    public var endTitleFamily: String? {
        steps.last?.afterTitle.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Is a navigation goal ALREADY satisfied by the current window title? "go to simone" is done when
    /// the title reads "Simone (MD) - …" — needs no stored state, so it works for routes learned before
    /// end-state recording and survives afterTitle captured before the UI settled (measured: the click's
    /// 300ms-later capture still showed the OLD title). ALL content tokens (≥3 chars) must appear.
    public static func goalSatisfied(byTitle title: String, goal: String) -> Bool {
        let fam = KnowledgeText.letters(title)
        guard !fam.isEmpty else { return false }
        let phrase = contentPhrase(goal)
        let toks = KnowledgeText.tokens(phrase.isEmpty ? goal : phrase)
            .map { KnowledgeText.letters($0) }.filter { $0.count >= 3 }
        return !toks.isEmpty && toks.allSatisfy { fam.contains($0) }
    }
}

public enum RoutePolicy {
    public static let maxSteps = 10
    public static let maxRoutesPerApp = 50
    public static let staleAfterDays: Double = 30
    public static let forgetAfterFails = 2
    /// How many independent confirmations stand in for a missing Proof on a pre-law row.
    public static let confirmationsInsteadOfProof = 2
    /// Fewer verified steps than this is an Experience (one verb, ⚡-replayable), not a procedure.
    public static let minimumRouteSteps = 2
}

public extension AppKnowledge {
    /// The routes the engine may ACT on. Everything else is kept and readable, but never replayed.
    var actionableRoutes: [Route] { routes.filter(\.isActionable) }

    /// Learn (or refresh) a route. Same normalized name → replace: identical steps bump evidence (the
    /// model re-saved after another win); different steps reset to 1 (it found a new/better way).
    ///
    /// `proof` is what VERIFIED the goal (`RouteEarning.verdict`). Writing without one is allowed only
    /// for a caller that has no outcome tape to judge (tests, and the CLI); a Route with no Proof and
    /// no independent confirmation is not actionable, so an unearned write is stored as an Observation
    /// rather than believed. A fresh Proof also LIFTS an earlier demotion — a Belief may be re-earned —
    /// while `demotionCause` stays as the record that it was once wrong.
    mutating func learnRoute(name: String, steps: [RouteStep], proof: String? = nil, now: Date) {
        let clipped = Array(steps.prefix(RoutePolicy.maxSteps))
        let key = KnowledgeText.normalize(name)
        if let i = routes.firstIndex(where: { KnowledgeText.normalize($0.name) == key }) {
            // "Same way" compares ACTIONS only — afterTitle/expect are observations that vary run to run.
            let same = routes[i].steps.count == clipped.count
                && zip(routes[i].steps, clipped).allSatisfy { $0.actionKey == $1.actionKey }
            routes[i].name = name
            routes[i].steps = clipped
            routes[i].evidence = same ? routes[i].evidence + 1 : 1
            routes[i].failStreak = 0
            routes[i].lastUsed = now
            if let proof {
                routes[i].proof = proof
                routes[i].demotedAt = nil
            }
        } else {
            routes.append(Route(name: name, steps: clipped, firstLearned: now, lastUsed: now, proof: proof))
        }
        pruneRoutes(now: now)
    }

    /// A CONTRADICTION retracts (ADR 0001): the route stops being actionable, the steps and the cause
    /// stay. Returns the demoted route, so the caller can say what it forgot — silent forgetting is the
    /// behaviour this replaces. Already-demoted routes are left alone (the first cause is the true one).
    @discardableResult
    mutating func demoteRoute(named name: String, cause: String, now: Date) -> Route? {
        let key = KnowledgeText.normalize(name)
        guard let i = routes.firstIndex(where: { KnowledgeText.normalize($0.name) == key }),
              routes[i].demote(cause: cause, now: now) else { return nil }
        return routes[i]
    }

    /// RETROFIT of the falsifiability law onto the rows that predate it. Every stored Route was written
    /// when a turn merely ENDING was enough, so none of them carries a Proof; the ones that were never
    /// independently confirmed are demoted with that stated as the cause. Returns what it demoted — the
    /// operator sees the list rather than a store that quietly stopped answering.
    @discardableResult
    mutating func demoteUnearnedRoutes(now: Date) -> [Route] {
        var demoted: [Route] = []
        for i in routes.indices where !routes[i].isEarned {
            guard routes[i].demote(cause: "written before a Route had to be earned — no verified goal recorded, and never independently confirmed", now: now) else { continue }
            demoted.append(routes[i])
        }
        return demoted
    }

    /// Best route for a query — unique-accept, same house rule as bestMenuCommand: a runner-up within
    /// 0.5 means the query is ambiguous → nil (refuse to guess). Only ACTIONABLE routes match: a demoted
    /// one, or one that was never earned, is a record — not a procedure the engine will run.
    func bestRoute(for query: String, minScore: Double = 2) -> Route? {
        var scored: [(route: Route, score: Double)] = []
        for r in routes where r.isActionable {
            let s = r.matchScore(query: query)
            if s >= minScore { scored.append((r, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.route.evidence > b.route.evidence }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].score > top.score - 0.5 { return nil }
        return top.route
    }

    /// Record a replay result (evidence/failure bookkeeping). A route that keeps failing is forgotten —
    /// UIs change, and a stale procedure must not shadow re-learning.
    mutating func recordRouteUse(name: String, success: Bool, now: Date) {
        let key = KnowledgeText.normalize(name)
        guard let i = routes.firstIndex(where: { KnowledgeText.normalize($0.name) == key }) else { return }
        if success {
            routes[i].evidence += 1; routes[i].failStreak = 0; routes[i].lastUsed = now
        } else {
            routes[i].failStreak += 1
            // Two failed replays is a Contradiction, and a Contradiction DEMOTES — it does not erase.
            // (It used to delete the row, which made the next audit impossible and let the same wrong
            // procedure be re-learned from scratch with no memory that it had already failed twice.)
            if routes[i].failStreak >= RoutePolicy.forgetAfterFails {
                _ = routes[i].demote(cause: "replay failed \(routes[i].failStreak)× in a row — the UI it was learned on has moved", now: now)
            }
        }
        pruneRoutes(now: now)
    }

    /// Drop stale (unused > 30d) routes; cap the store. Demoted rows are kept for the audit but are the
    /// FIRST to go when the cap bites — a corpse must not crowd out a working procedure.
    mutating func pruneRoutes(now: Date) {
        routes.removeAll { now.timeIntervalSince($0.lastUsed) > RoutePolicy.staleAfterDays * 86_400 }
        if routes.count > RoutePolicy.maxRoutesPerApp {
            routes.sort { a, b in
                if a.isActionable != b.isActionable { return a.isActionable }
                return a.evidence != b.evidence ? a.evidence > b.evidence : a.lastUsed > b.lastUsed
            }
            routes.removeSubrange(RoutePolicy.maxRoutesPerApp...)
        }
    }
}
