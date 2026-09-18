//
//  BrainRetention.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// BrainRetention is what the brain keeps, measured in observations of the application rather than
/// in days, with one wall-clock backstop for a row not observed in a year.
public struct BrainRetention: Sendable, Equatable {

    /// A seen-once object unseen for this many observations was a transient: a menu item, a misread.
    public var transientIngests = 12
    /// Any observed object unseen for this many observations: the application moved on.
    public var staleIngests = 150
    /// An evidence-one transition unseen for this many observations was a coincidence.
    public var coincidenceIngests = 30
    /// Every transition dies unseen for this many observations.
    public var transitionStaleIngests = 300
    /// The only date rule left.
    public var backstopDays = 365.0

    public static let standard = BrainRetention()

    public init() {}
}
