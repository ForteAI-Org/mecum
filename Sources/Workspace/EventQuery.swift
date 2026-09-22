//
//  EventQuery.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// EventQuery selects a slice of the operational record.
///
/// One scope rather than a set of optional filters: each case is a read the
/// schema has an index for, and a free combination of four optional
/// predicates would only look more general while scanning.
public struct EventQuery: Sendable, Hashable {

    public enum Scope: Sendable, Hashable {
        case workspace(UUID)
        case worker(UUID)
        case conversation(UUID)

        /// Everything recorded about one entity, whichever column it sat in.
        case subject(UUID)
    }

    public var scope: Scope

    /// Ascending local order by default, which is the order they happened in.
    public var isAscending: Bool

    /// Bounds the result. The record grows without bound, so a reader that
    /// wants all of it says so by leaving this nil.
    public var limit: Int?

    public init(scope: Scope, isAscending: Bool = true, limit: Int? = nil) {
        self.scope       = scope
        self.isAscending = isAscending
        self.limit       = limit
    }
}
