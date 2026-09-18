//
//  AppKnowledge+Routes.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

public extension AppKnowledge {

    /// The routes the engine may act on. Everything else is kept and readable, never replayed.
    var actionableRoutes: [Route] { routes.filter(\.isActionable) }

    /// Learns or refreshes a route. The same normalized name replaces: identical actions add evidence,
    /// different actions reset it to one. `proof` is what verified the goal; a write without one is
    /// stored as an observation and is not actionable until independently confirmed. A fresh proof
    /// lifts an earlier demotion while the cause stays as the record that it was once wrong.
    mutating func learnRoute(name: String, steps: [RouteStep], proof: String? = nil, now: Date) {
        let clipped = Array(steps.prefix(RoutePolicy.maxSteps))
        if let i = routeIndex(named: name) {
            let sameWay = routes[i].steps.count == clipped.count
                && zip(routes[i].steps, clipped).allSatisfy { $0.actionKey == $1.actionKey }
            routes[i].name       = name
            routes[i].steps      = clipped
            routes[i].evidence   = sameWay ? routes[i].evidence + 1 : 1
            routes[i].failStreak = 0
            routes[i].lastUsed   = now
            if let proof {
                routes[i].proof     = proof
                routes[i].demotedAt = nil
            }
        } else {
            routes.append(Route(name: name, steps: clipped, firstLearned: now, lastUsed: now, proof: proof))
        }
        pruneRoutes(now: now)
    }

    /// Retracts a route on a contradiction: it stops being actionable, its steps and the cause stay.
    /// Returns the demoted route so the caller can say what was forgotten, nil when there was no such
    /// actionable-or-not route or it was already demoted.
    @discardableResult
    mutating func demoteRoute(named name: String, cause: String, now: Date) -> Route? {
        guard let i = routeIndex(named: name), routes[i].demote(cause: cause, now: now) else { return nil }
        return routes[i]
    }

    /// Demotes every route that was never earned, with that stated as the cause. Returns what it
    /// demoted, so an operator sees the list rather than a store that quietly stopped answering.
    @discardableResult
    mutating func demoteUnearnedRoutes(now: Date) -> [Route] {
        var demoted: [Route] = []
        let cause = "written before a Route had to be earned: no verified goal recorded, "
            + "and never independently confirmed"
        for i in routes.indices where !routes[i].isEarned {
            guard routes[i].demote(cause: cause, now: now) else { continue }
            demoted.append(routes[i])
        }
        return demoted
    }

    /// The one actionable route a query names, or nil. A runner-up within 0.5 makes the query
    /// ambiguous, and an ambiguous query is refused rather than guessed.
    func bestRoute(for query: String, minScore: Double = 2) -> Route? {
        var scored: [(route: Route, score: Double)] = []
        for route in routes where route.isActionable {
            let score = route.matchScore(query: query)
            if score >= minScore { scored.append((route, score)) }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.route.evidence > rhs.route.evidence
        }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].score > top.score - 0.5 { return nil }
        return top.route
    }

    /// Records a replay result. A success adds evidence and clears the streak; a second consecutive
    /// failure is a contradiction and demotes, because deleting made the next audit impossible.
    mutating func recordRouteUse(name: String, success: Bool, now: Date) {
        guard let i = routeIndex(named: name) else { return }
        if success {
            routes[i].evidence   += 1
            routes[i].failStreak = 0
            routes[i].lastUsed   = now
        } else {
            routes[i].failStreak += 1
            if routes[i].failStreak >= RoutePolicy.forgetAfterFails {
                let cause = "replay failed \(routes[i].failStreak)× in a row: the UI it was learned on has moved"
                _ = routes[i].demote(cause: cause, now: now)
            }
        }
        pruneRoutes(now: now)
    }

    /// Drops routes unused past the stale span and caps the store. Demoted rows are kept for the
    /// audit but go first when the cap bites.
    mutating func pruneRoutes(now: Date) {
        routes.removeAll { now.timeIntervalSince($0.lastUsed) > RoutePolicy.staleAfterDays * 86_400 }
        guard routes.count > RoutePolicy.maxRoutesPerApp else { return }
        routes.sort { lhs, rhs in
            if lhs.isActionable != rhs.isActionable { return lhs.isActionable }
            return lhs.evidence != rhs.evidence ? lhs.evidence > rhs.evidence : lhs.lastUsed > rhs.lastUsed
        }
        routes.removeSubrange(RoutePolicy.maxRoutesPerApp...)
    }

    private func routeIndex(named name: String) -> Int? {
        let key = LabelText.normalize(name)
        return routes.firstIndex { LabelText.normalize($0.name) == key }
    }
}
