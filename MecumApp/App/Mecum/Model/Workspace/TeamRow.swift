//
//  TeamRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports

/// TeamRow is one line of the team sidebar: a worker, its states, and the
/// two texts the row is read with.
///
/// The texts live here rather than in the view so they can be checked without
/// running one. `name` is always the whole name: the view truncates it
/// visually, and the tooltip and `accessibilityLabel` keep what was cut.
nonisolated struct TeamRow: Sendable, Hashable, Identifiable {

    /// What the subtitle says while no model is attached. It is a state, not
    /// an error, and it is what keeps the row from implying the worker can
    /// answer.
    static let toConfigure = "To configure"

    let worker: WorkerSnapshot

    /// The worker's model is no longer in its provider's catalogue (§7.4). The
    /// worker keeps its place and its configuration, and needs configuring.
    let isModelUnavailable: Bool

    /// What the worker is doing right now, in the words its row shows, such
    /// as "Waiting for the computer". Nil while there is no work in progress.
    /// The consumer supplies it; nothing here reads a queue or a seat.
    let activity: String?

    /// What the worker's direct conversation holds that the person has not
    /// seen. It changes the badge and the label, never the row's place.
    let unread: UnreadState

    /// The most the badge counts; beyond it the badge reads "99+".
    static let badgeLimit = 99

    /// The number the badge shows, or nil when there is none. An unseen
    /// problem takes the attention mark instead, and the mark carries no number.
    var badgeText: String? {
        guard !unread.hasUnseenProblem, unread.replies > 0 else { return nil }
        return unread.replies > Self.badgeLimit ? "\(Self.badgeLimit)+" : String(unread.replies)
    }

    /// True when the row shows the attention mark: a turn failed or stopped
    /// and the person has not looked since.
    var needsAttention: Bool { unread.hasUnseenProblem }

    init(
        worker            : WorkerSnapshot,
        isModelUnavailable: Bool,
        activity          : String?,
        unread            : UnreadState = .none
    ) {
        self.worker             = worker
        self.isModelUnavailable = isModelUnavailable
        self.activity           = activity
        self.unread             = unread
    }

    /// Whether the row reads as to configure: no model, or one that is gone.
    var needsConfiguring: Bool { !worker.isConfigured || isModelUnavailable }

    var id  : UUID   { worker.id }
    var name: String { worker.name }

    /// The line under the name: the model the worker answers with, the
    /// activity in its place while there is work in progress (§4.2), and the
    /// missing configuration before either, because a worker that cannot
    /// answer must say so first. The activity is the passing fact and the
    /// model the lasting one, so the row shows one at a time; the inspector
    /// keeps the model in view.
    var subtitle: String {
        guard !needsConfiguring, let selection = worker.configuration else { return Self.toConfigure }
        return activity ?? selection.line
    }

    /// The line under the name as the sidebar shows it: nil when it would be the model and the
    /// model is not to be shown. The activity and the missing configuration are shown either way.
    func subtitle(showingModel: Bool) -> String? {
        showingModel || needsConfiguring || activity != nil ? subtitle : nil
    }

    /// Whether the row answers a search for `query`, by the worker's name or role.
    func matches(_ query: String) -> Bool {
        worker.name.localizedStandardContains(query) || role.localizedStandardContains(query)
    }

    /// The whole name, then the role, then the states and the model, so a
    /// long name stays readable to assistive technology after the view has
    /// truncated it, and a compact tile that shows only the name reads the rest.
    var accessibilityLabel: String {
        var parts = [worker.name]
        if !role.isEmpty { parts.append(role) }
        if let activity { parts.append(activity) }
        if needsConfiguring {
            parts.append(Self.toConfigure)
        } else if let selection = worker.configuration {
            parts.append(selection.line)
        }
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
