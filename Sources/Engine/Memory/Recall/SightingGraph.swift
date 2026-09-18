//
//  SightingGraph.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// SightingGraph is which application graphs memory holds and which entity cores each has sighted, so
/// a phrase learned in one application can hop to another only when the target graph actually
/// contains the entity: evidence, not hope.
public struct SightingGraph: Sendable, Equatable {

    /// Lowercased bundle id to sighted entity cores (`LabelText.coreKey`).
    public let sighted: [String: Set<String>]

    public init(sighted: [String: Set<String>] = [:]) {
        self.sighted = sighted
    }

    /// The bundles a spoken token names by containment in a bundle-id component ("slack" names
    /// com.tinyspeck.slackmacgap). Nominates candidates; whether a nomination is evidence is
    /// `RecallEvidence`'s question.
    public func bundles(matching token: String) -> [String] {
        guard token.count >= 3 else { return [] }
        return sighted.keys.filter { $0.split(separator: ".").contains { $0.contains(token) } }
    }
}
