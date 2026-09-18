//
//  AppKnowledge+Menus.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

public extension AppKnowledge {

    /// Merges a fresh read-only menu enumeration: a known command (by key) refreshes its fields and
    /// keeps its first sighting; a new one is appended. The order is by path.
    mutating func observeMenus(_ incoming: [MenuCommand], now: Date) {
        var byKey = Dictionary(menuCommands.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for var command in incoming {
            if let existing = byKey[command.key] { command.firstSeen = existing.firstSeen }
            command.lastSeen = now
            byKey[command.key] = command
        }
        menuCommands = byKey.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    /// The one executable menu command a query names, or nil. Submenu parents are never returned,
    /// because pressing one only flashes the menu open. The winner must be clear: a runner-up within
    /// 0.5 is an ambiguity. And the winner's own words must explain at least half the query, or a
    /// modifier gesture such as "Option + Click Solo" runs a command it never named (measured).
    func bestMenuCommand(for query: String, minScore: Double = 2) -> MenuCommand? {
        guard let top = topMenuMatch(for: query, minScore: minScore) else { return nil }
        let queryTokens = Set(LabelText.tokens(query))
        let commandTokens = Set(LabelText.tokens(top.leaf)).union(LabelText.tokens(top.path.joined(separator: " ")))
        guard !queryTokens.isEmpty else { return nil }
        let coverage = Double(queryTokens.intersection(commandTokens).count) / Double(queryTokens.count)
        return coverage >= 0.5 ? top : nil
    }

    /// The raw unique winner without the coverage gate, for a "did you mean" in a miss message,
    /// where naming a near match helps and running it would be a wrong action.
    func menuSuggestion(for query: String) -> MenuCommand? {
        topMenuMatch(for: query, minScore: 1.0)
    }

    private func topMenuMatch(for query: String, minScore: Double) -> MenuCommand? {
        var scored: [(command: MenuCommand, score: Double)] = []
        for command in menuCommands where !command.hasSubmenu {
            let score = command.matchScore(query: query)
            if score >= minScore { scored.append((command, score)) }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.command.path.count < rhs.command.path.count
        }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].score > top.score - 0.5 { return nil }
        return top.command
    }
}
