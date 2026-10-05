//
//  BrainKeys.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation

/// BrainKeys hands out the identities an ingest creates: the key of a new anchor and the id of a
/// new group. The default draws random UUIDs, exactly what the initializers of `ObjectAnchor` and
/// `SiblingGroup` always drew, so the algorithm's results are unchanged. A test supplies a
/// deterministic sequence so that two runs of one sequence, a pure brain and a stored projection,
/// name the same objects and can be compared field by field. Nothing in matching, thresholds, order
/// or decay reads the keys.
public struct BrainKeys: Sendable {

    public var anchorKey: @Sendable () -> String
    public var groupID: @Sendable () -> UUID

    public init(anchorKey: @escaping @Sendable () -> String, groupID: @escaping @Sendable () -> UUID) {
        self.anchorKey = anchorKey
        self.groupID   = groupID
    }

    /// Random UUIDs, as the brain always generated.
    public static let random = BrainKeys(anchorKey: { UUID().uuidString }, groupID: { UUID() })
}
