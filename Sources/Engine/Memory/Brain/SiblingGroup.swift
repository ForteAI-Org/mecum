//
//  SiblingGroup.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// SiblingGroup is a structural group of aligned, same-size, same-kind elements, such as a column of
/// switches. Membership implies nature (a square in a known switch column is a switch) and ordinal
/// position is part of identity ("3rd switch in Destinations").
public struct SiblingGroup: Sendable, Equatable, Codable {

    public var id: UUID
    public var axis: GroupAxis
    /// Ordered by position along the axis.
    public var memberAnchors: [String]
    public var sharedKind: ElementKind
    /// The typical member size.
    public var cellSize: NormalizedSize
    /// The nearest header text, when one was found.
    public var name: String?
    public var seenCount: Int
    public var lastSeen: Date
    public var lastSeenEpoch: Int?

    public init(
        id           : UUID = UUID(),
        axis         : GroupAxis,
        memberAnchors: [String],
        sharedKind   : ElementKind,
        cellSize     : NormalizedSize,
        name         : String? = nil,
        seenCount    : Int = 1,
        lastSeen     : Date,
        lastSeenEpoch: Int? = nil
    ) {
        self.id            = id
        self.axis          = axis
        self.memberAnchors = memberAnchors
        self.sharedKind    = sharedKind
        self.cellSize      = cellSize
        self.name          = name
        self.seenCount     = seenCount
        self.lastSeen      = lastSeen
        self.lastSeenEpoch = lastSeenEpoch
    }

    /// The tag an enriched element carries: the group's name or axis, then the one-based ordinal.
    public func tag(forMember anchorKey: String) -> String? {
        guard let ordinal = memberAnchors.firstIndex(of: anchorKey) else { return nil }
        return "\(name ?? axis.rawValue)#\(ordinal + 1)"
    }
}
