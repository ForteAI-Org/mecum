//
//  ObservedObject.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// ObservedObject is one UI object seen inside a window, kept as a lightweight hypothesis: its text,
/// its normalized bounds, its role when one is known, and how often it was seen. No pixel crop is
/// stored. A retrieval hit is re-verified live before any action; the knowledge base never answers
/// with a clickable coordinate.
public struct ObservedObject: Sendable, Equatable, Codable {

    /// Stable key for merging within an application (see `makeIdentityKey`).
    public var identityKey: String
    /// The accessibility title, description or value, or the recognized text.
    public var selfText: String?
    /// The accessibility role, nil for a pure vision object.
    public var role: String?
    public var source: ObjectSource
    /// The latest normalized bounds, kept for disambiguation only.
    public var boundsNormalized: NormalizedRect
    /// An optional perceptual hash for change detection.
    public var edgeHash: String?
    /// An optional cursor-shape hint sampled while hovering.
    public var affordance: CursorAffordance?
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int

    public init(
        identityKey     : String,
        selfText        : String?,
        role            : String?,
        source          : ObjectSource,
        boundsNormalized: NormalizedRect,
        edgeHash        : String? = nil,
        affordance      : CursorAffordance? = nil,
        firstSeen       : Date,
        lastSeen        : Date,
        observationCount: Int = 1
    ) {
        self.identityKey      = identityKey
        self.selfText         = selfText
        self.role             = role
        self.source           = source
        self.boundsNormalized = boundsNormalized
        self.edgeHash         = edgeHash
        self.affordance       = affordance
        self.firstSeen        = firstSeen
        self.lastSeen         = lastSeen
        self.observationCount = observationCount
    }

    /// Coarse match score of this object against a free-text query, 0 for no relation. A candidate
    /// selector only; final correctness is the caller's live verification.
    public func matchScore(query: String) -> Double {
        selfText.map { LabelText.matchScore(query: query, against: $0) } ?? 0
    }

    /// Builds a stable identity key. An identifier wins; a text-bearing object keys on role and
    /// normalized text; a text-less one falls back to a coarse ten-by-ten position bucket so the same
    /// icon slot merges across frames without one-pixel jitter spawning duplicates.
    public static func makeIdentityKey(
        role            : String?,
        identifier      : String?,
        text            : String?,
        boundsNormalized: NormalizedRect
    ) -> String {
        if let identifier, !identifier.isEmpty { return "id:\(identifier)" }
        let role = role ?? "?"
        let normalized = LabelText.normalize(text ?? "")
        if !normalized.isEmpty { return "\(role)|\(normalized)" }
        let column = Int((boundsNormalized.x * 10).rounded())
        let row = Int((boundsNormalized.y * 10).rounded())
        return "\(role)|@\(column),\(row)"
    }
}
