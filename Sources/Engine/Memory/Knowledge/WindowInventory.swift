//
//  WindowInventory.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// WindowInventory is every object observed in one window state of one application.
public struct WindowInventory: Sendable, Equatable, Codable {

    public var windowTitlePattern: String
    public var objects: [ObservedObject]
    public var lastObserved: Date
    /// The identity of the state these objects belong to; nil for inventories that match by title.
    public var fingerprint: StateFingerprint?

    public init(
        windowTitlePattern: String,
        objects           : [ObservedObject] = [],
        lastObserved      : Date,
        fingerprint       : StateFingerprint? = nil
    ) {
        self.windowTitlePattern = windowTitlePattern
        self.objects            = objects
        self.lastObserved       = lastObserved
        self.fingerprint        = fingerprint
    }

    /// Merges a fresh observation: a known object (by identity key) moves to its latest bounds, gains
    /// any newly available text, role, hash or affordance, and bumps its count; an unknown one is
    /// appended. The order is most recently seen first, then by key.
    public mutating func merge(_ incoming: [ObservedObject], now: Date) {
        var byKey = Dictionary(objects.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
        for object in incoming {
            if var existing = byKey[object.identityKey] {
                existing.boundsNormalized = object.boundsNormalized
                existing.selfText         = existing.selfText ?? object.selfText
                existing.role             = existing.role ?? object.role
                existing.edgeHash         = object.edgeHash ?? existing.edgeHash
                existing.affordance       = object.affordance ?? existing.affordance
                existing.lastSeen         = now
                existing.observationCount += 1
                byKey[object.identityKey] = existing
            } else {
                var fresh = object
                fresh.firstSeen        = now
                fresh.lastSeen         = now
                fresh.observationCount = 1
                byKey[object.identityKey] = fresh
            }
        }
        objects = byKey.values.sorted { ($0.lastSeen, $0.identityKey) > ($1.lastSeen, $1.identityKey) }
        lastObserved = now
    }

    /// Ranked candidates for a query: positive score, best first; ties go to the more observed
    /// object, then to the key, for determinism.
    public func candidates(for query: String, limit: Int = 8) -> [ObservedObject] {
        objects.map { ($0, $0.matchScore(query: query)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.observationCount != rhs.0.observationCount {
                    return lhs.0.observationCount > rhs.0.observationCount
                }
                return lhs.0.identityKey < rhs.0.identityKey
            }
            .prefix(limit).map(\.0)
    }
}
