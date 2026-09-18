//
//  UIBrain+Enrichment.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

public extension UIBrain {

    /// Annotates a scene's elements with what the brain knows, read-only, positions staying live: a
    /// matched element gains its sibling-group tag and its trusted affordances, and an unlabeled
    /// element whose anchor carries a name inherits it, marked recalled, with its id rebuilt from the
    /// recalled label so targeting and scene tokens stay stable. One index is built for the whole
    /// scene; per-element scans were what made description degrade as knowledge grew.
    func enrich(_ elements: [SceneElement]) -> [SceneElement] {
        let index = BrainIndex(self)
        let groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transitionsByAnchor = Dictionary(grouping: transitions, by: \.anchorKey)
        return elements.map { element in
            guard element.kind == .control || element.kind == .icon else { return element }
            let detection = BrainDetection(element)
            guard case .found(let key) = BrainMatcher.match(detection, in: self, index: index),
                  let anchor = index.object(key, in: self) else { return element }
            var enriched = element
            if let groupID = anchor.groupID, let group = groupByID[groupID] {
                enriched.group = group.tag(forMember: key)
            }
            enriched.does = Self.doesSummary(transitionsByAnchor[key] ?? [])
            if element.isUnlabeled, !anchor.label.isEmpty {
                enriched.label       = anchor.label
                enriched.isUnlabeled = false
                enriched.isRecalled  = true
                enriched.id = SceneIdentity.key(kind: element.kind, label: anchor.label, bounds: element.bounds,
                                                isUnlabeled: false)
            }
            return enriched
        }
    }
}
