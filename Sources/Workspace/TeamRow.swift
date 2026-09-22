//
//  TeamRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// TeamRow is one line of the team sidebar: a worker, its place in the
/// outline, and the two texts the row is read with.
///
/// The texts live here rather than in the view so they can be checked without
/// running one. `name` is always the whole name: the view truncates it
/// visually, and the tooltip and `accessibilityLabel` keep what was cut.
public struct TeamRow: Sendable, Hashable, Identifiable {

    /// What the subtitle says while no model is attached. It is a state, not
    /// an error, and it is what keeps the row from implying the worker can
    /// answer.
    public static let toConfigure = "To configure"

    public let worker     : WorkerSnapshot
    public let depth      : Int
    public let hasReports : Bool
    public let isCollapsed: Bool

    public var id  : UUID   { worker.id }
    public var name: String { worker.name }

    /// The role while there is no work in progress, and the missing
    /// configuration before it, because a worker that cannot answer must say
    /// so before it says what it is for. A worker with no role has no
    /// subtitle; nothing invents a specialisation from the name.
    public var subtitle: String {
        guard worker.isConfigured else { return Self.toConfigure }
        return role
    }

    /// The whole name, then the role, then the states, so a long name stays
    /// readable to assistive technology after the view has truncated it.
    public var accessibilityLabel: String {
        var parts = [worker.name]
        if !role.isEmpty { parts.append(role) }
        if !worker.isConfigured { parts.append(Self.toConfigure) }
        if worker.isArchived { parts.append("Archived") }
        return parts.joined(separator: ", ")
    }

    private var role: String {
        worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
