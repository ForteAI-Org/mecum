//
//  SiblingGroupDetector.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// SiblingGroupDetector finds aligned runs of same-kind, same-size elements in one scene. Pure
/// geometry: three or more elements within 25 percent of one size, sharing a left edge (column) or a
/// top edge (row). Regular spacing is deliberately not required, because section headers interleave
/// real columns (measured). Columns win ties.
public enum SiblingGroupDetector {

    /// GroupCandidate is one detected run, with member indices into the interactive detections.
    public struct GroupCandidate: Sendable, Equatable {
        public var axis: GroupAxis
        /// Indices into the interactive array, ordered along the axis.
        public var memberIndices: [Int]
        public var sharedKind: ElementKind
        public var cellSize: NormalizedSize
        public var name: String?
    }

    public static func detectGroups(interactive: [BrainDetection], texts: [BrainDetection]) -> [GroupCandidate] {
        var candidates: [GroupCandidate] = []
        var taken = Set<Int>()
        for axis in GroupAxis.allCases {
            let pool = interactive.indices.filter { !taken.contains($0) }
            var used = Set<Int>()
            for i in pool where !used.contains(i) {
                let anchor = interactive[i].bounds
                var cluster = [i]
                for j in pool where j != i && !used.contains(j) {
                    let other = interactive[j].bounds
                    guard interactive[j].kind == interactive[i].kind, sameSize(anchor, other) else { continue }
                    let aligned = axis == .column
                        ? abs(other.x - anchor.x) <= 0.6 * max(anchor.width, 0.004)
                        : abs(other.y - anchor.y) <= 0.6 * max(anchor.height, 0.004)
                    if aligned { cluster.append(j) }
                }
                guard cluster.count >= 3 else { continue }
                cluster.sort {
                    axis == .column ? interactive[$0].bounds.y < interactive[$1].bounds.y
                                    : interactive[$0].bounds.x < interactive[$1].bounds.x
                }
                used.formUnion(cluster)
                taken.formUnion(cluster)
                candidates.append(GroupCandidate(
                    axis         : axis,
                    memberIndices: cluster,
                    sharedKind   : interactive[i].kind,
                    cellSize     : NormalizedSize(of: anchor),
                    name         : groupName(axis: axis, first: interactive[cluster[0]].bounds, texts: texts)
                ))
            }
        }
        return candidates
    }

    static func sameSize(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        guard lhs.width > 0, lhs.height > 0 else { return false }
        return abs(rhs.width - lhs.width) <= 0.25 * lhs.width && abs(rhs.height - lhs.height) <= 0.25 * lhs.height
    }

    /// The group's name: the nearest header text above the first member of a column, or left of the
    /// first member of a row.
    static func groupName(axis: GroupAxis, first: NormalizedRect, texts: [BrainDetection]) -> String? {
        var best: (label: String, gap: Double)?
        for text in texts where text.label.count >= 2 && LabelText.isNameworthy(text.label) {
            let gap: Double
            if axis == .column {
                gap = first.y - text.bounds.maxY
                guard gap >= 0, gap <= 0.12, abs(text.bounds.midX - first.midX) <= 0.25 else { continue }
            } else {
                gap = first.x - text.bounds.maxX
                guard gap >= 0, gap <= 0.15, abs(text.bounds.midY - first.midY) <= 0.05 else { continue }
            }
            if let current = best, gap >= current.gap { continue }
            best = (text.label, gap)
        }
        return best?.label
    }
}
