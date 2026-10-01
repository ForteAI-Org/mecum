//
//  ExperienceID.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// ExperienceID is an experience's persistent identity, assigned by the store when the
/// experience is first recorded and never derived from a session, process, window or scene id.
public struct ExperienceID: Sendable, Hashable, Codable, Comparable {

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ExperienceID, rhs: ExperienceID) -> Bool { lhs.rawValue < rhs.rawValue }
}
