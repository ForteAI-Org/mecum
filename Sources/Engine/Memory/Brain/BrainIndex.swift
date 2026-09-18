//
//  BrainIndex.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// BrainIndex is the prebuilt lookup over one brain snapshot, so matching costs a dictionary probe
/// instead of a scan per element. Per-element scans were the measured cause of a scene description
/// slowing from four to ten seconds as a brain learned. The index is valid only for the exact
/// snapshot it was built from.
public struct BrainIndex: Sendable {

    /// Normalized label or alias to object indices, each object once per normal.
    let byNormalizedLabel: [String: [Int]]
    /// Model-named anchors by kind; they hold positional pull.
    let modelNamedByKind: [ElementKind: [Int]]
    let indexByKey: [String: Int]

    public init(_ brain: UIBrain) {
        var byLabel: [String: [Int]] = [:]
        var modelNamed: [ElementKind: [Int]] = [:]
        var byKey: [String: Int] = Dictionary(minimumCapacity: brain.objects.count)
        for (index, object) in brain.objects.enumerated() {
            byKey[object.anchorKey] = index
            var normals: Set<String> = []
            let label = LabelText.normalize(object.label)
            if !label.isEmpty { normals.insert(label) }
            for alias in object.aliases {
                let normal = LabelText.normalize(alias)
                if !normal.isEmpty { normals.insert(normal) }
            }
            for normal in normals { byLabel[normal, default: []].append(index) }
            if object.labelSource == .llm { modelNamed[object.kind, default: []].append(index) }
        }
        byNormalizedLabel = byLabel
        modelNamedByKind  = modelNamed
        indexByKey        = byKey
    }

    /// The anchor with this key in the indexed snapshot.
    func object(_ key: String, in brain: UIBrain) -> ObjectAnchor? {
        indexByKey[key].map { brain.objects[$0] }
    }
}
