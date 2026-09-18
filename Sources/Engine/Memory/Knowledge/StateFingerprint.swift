//
//  StateFingerprint.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// StateFingerprint is the identity of a window state, built only from what does not move with live
/// data or scrolling, so one screen is one node rather than a new node per meter tick or scroll
/// position. Three channels: the title family, the role multiset, and the numeric-stripped labels.
public struct StateFingerprint: Sendable, Equatable, Codable {

    /// The letters-only family of the window title.
    public var titleBucket: String
    /// Sorted "role:log2(count)" pairs; empty for an opaque tree.
    public var structureSig: String
    /// Sorted, deduplicated, numeric-stripped static labels.
    public var labelSet: [String]

    public init(titleBucket: String, structureSig: String, labelSet: [String]) {
        self.titleBucket  = titleBucket
        self.structureSig = structureSig
        self.labelSet     = labelSet
    }

    /// Same UI state? The title family is a hard gate; then either the structure signatures match or
    /// the label sets are at least `minLabelJaccard` similar. Scrolling a list changes which
    /// "Audio N" rows show, not the numeric-stripped labels or the bucketed role counts.
    public func matches(_ other: StateFingerprint, minLabelJaccard: Double = 0.6) -> Bool {
        guard titleBucket == other.titleBucket else { return false }
        if !structureSig.isEmpty, structureSig == other.structureSig { return true }
        let mine = Set(labelSet), theirs = Set(other.labelSet)
        let union = mine.union(theirs)
        guard !union.isEmpty else { return true }
        return Double(mine.intersection(theirs).count) / Double(union.count) >= minLabelJaccard
    }

    /// Builds the fingerprint of a harvested window from its title and observed objects.
    public static func make(title: String, objects: [ObservedObject]) -> StateFingerprint {
        StateFingerprint(
            titleBucket : LabelText.letters(title),
            structureSig: structureSignature(roles: objects.map { $0.role ?? "cv" }),
            labelSet    : canonicalLabels(objects.compactMap(\.selfText))
        )
    }

    /// The role multiset with counts bucketed by log2, so twelve versus fifteen rows after a scroll
    /// do not fork, joined in a process-stable order.
    static func structureSignature(roles: [String]) -> String {
        var counts: [String: Int] = [:]
        for role in roles { counts[role, default: 0] += 1 }
        return counts.keys.sorted()
            .map { "\($0):\(Int(log2(Double(counts[$0, default: 0] + 1))))" }
            .joined(separator: "|")
    }

    /// Tokens that contain a letter and are at least two characters; numeric, timecode and version
    /// tokens are volatile and dropped.
    static func canonicalLabels(_ texts: [String]) -> [String] {
        var labels = Set<String>()
        for text in texts {
            for token in LabelText.tokens(text) where token.count >= 2 && token.contains(where: \.isLetter) {
                labels.insert(token)
            }
        }
        return labels.sorted()
    }
}
