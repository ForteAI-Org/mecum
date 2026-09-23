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

    /// The worker's model is no longer in its provider's catalogue (§7.4). The
    /// worker keeps its place and its configuration, and needs configuring.
    public let isModelUnavailable: Bool

    /// What the worker is doing right now, in the words its row shows, such
    /// as "Waiting for the computer". Nil while there is no work in progress.
    /// The consumer supplies it; nothing here reads a queue or a seat.
    public let activity: String?

    /// What the worker's direct conversation holds that the person has not
    /// seen. It changes the badge and the label, never the row's place.
    public let unread: UnreadState

    /// The most the badge counts; beyond it the badge reads "99+".
    public static let badgeLimit = 99

    /// The number the badge shows, or nil when there is none. An unseen
    /// problem takes the attention mark instead, and the mark carries no number.
    public var badgeText: String? {
        guard !unread.hasUnseenProblem, unread.replies > 0 else { return nil }
        return unread.replies > Self.badgeLimit ? "\(Self.badgeLimit)+" : String(unread.replies)
    }

    /// True when the row shows the attention mark: a turn failed or stopped
    /// and the person has not looked since.
    public var needsAttention: Bool { unread.hasUnseenProblem }

    public init(
        worker            : WorkerSnapshot,
        depth             : Int,
        hasReports        : Bool,
        isCollapsed       : Bool,
        isModelUnavailable: Bool,
        activity          : String?,
        unread            : UnreadState = .none
    ) {
        self.worker             = worker
        self.depth              = depth
        self.hasReports         = hasReports
        self.isCollapsed        = isCollapsed
        self.isModelUnavailable = isModelUnavailable
        self.activity           = activity
        self.unread             = unread
    }

    /// Whether the row reads as to configure: no model, or one that is gone.
    public var needsConfiguring: Bool { !worker.isConfigured || isModelUnavailable }

    public var id  : UUID   { worker.id }
    public var name: String { worker.name }

    /// The role while there is no work in progress and the activity while
    /// there is (§4.2), and the missing configuration before either, because
    /// a worker that cannot answer must say so before it says what it is for.
    /// A worker with no role has no idle subtitle; nothing invents a
    /// specialisation from the name.
    public var subtitle: String {
        guard !needsConfiguring else { return Self.toConfigure }
        return activity ?? role
    }

    /// The whole name, then the role, then the states, so a long name stays
    /// readable to assistive technology after the view has truncated it.
    public var accessibilityLabel: String {
        var parts = [worker.name]
        if !role.isEmpty { parts.append(role) }
        if let activity { parts.append(activity) }
        if needsConfiguring { parts.append(Self.toConfigure) }
        if needsAttention { parts.append("Last turn did not finish") }
        if unread.replies > 0 {
            parts.append(unread.replies == 1 ? "1 unread reply" : "\(unread.replies) unread replies")
        }
        if worker.isArchived { parts.append("Archived") }
        return parts.joined(separator: ", ")
    }

    private var role: String {
        worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
