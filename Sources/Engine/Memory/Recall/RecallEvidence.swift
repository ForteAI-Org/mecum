//
//  RecallEvidence.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// RecallEvidence is what recall may call concrete: the application graphs the engine holds and the
/// entity cores it has sighted in each. A word that resolves to nothing here is not an entity,
/// however grammatical it looks.
public struct RecallEvidence: Sendable, Equatable {

    public let graph: SightingGraph

    public init(graph: SightingGraph = SightingGraph()) {
        self.graph = graph
    }

    /// NamedApp is what a spoken word names among the known applications. Only `one` is evidence.
    public enum NamedApp: Sendable, Equatable {
        case one(String)
        case unknown
        case several([String])
    }

    /// Naming is not containment. The word must be a whole bundle-id component or sit at one of its
    /// ends: "premiere" names com.adobe.premierepro and "resolve" names ...davinciresolve, but
    /// "check" does not name com.forte-ai.aafchecker. Under three characters nothing is a name.
    public func app(named word: String) -> NamedApp {
        let normalized = LabelText.normalize(word)
        guard normalized.count >= 3 else { return .unknown }
        let lower = word.lowercased()
        if let exact = graph.sighted.keys.first(where: { $0.lowercased() == lower }) { return .one(exact) }
        let hits = graph.sighted.keys.filter { bundle in
            bundle.split(separator: ".")
                .map { LabelText.normalize(String($0)) }
                .contains { $0 == normalized || $0.hasPrefix(normalized) || $0.hasSuffix(normalized) }
        }.sorted()
        switch hits.count {
            case 0 : return .unknown
            case 1 : return .one(hits[0])
            default: return .several(hits)
        }
    }

    /// Whether the engine has sighted `value` inside the application `appWord` names. Sighting
    /// identity is the core key, so "z Simone" and "simone" are one entity.
    public func sighting(_ value: String, inAppNamed appWord: String) -> Bool {
        guard case .one(let bundle) = app(named: appWord) else { return false }
        return graph.sighted[bundle]?.contains(LabelText.coreKey(value)) == true
    }
}
