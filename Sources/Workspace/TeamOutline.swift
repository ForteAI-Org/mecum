//
//  TeamOutline.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// TeamOutline puts the team in the order the sidebar shows it.
///
/// A manager comes before the workers that report to it, and depth is what
/// the view indents by. Nothing else decides the order: siblings keep the
/// order they arrive in, which is the order the store sorted them by, so a
/// worker changing state does not move. The sidebar is a list of people, not
/// a queue of what is busy.
public enum TeamOutline {

    /// The rows for `workers`, managers first.
    ///
    /// A worker whose manager is not in `workers`, because it is archived or
    /// was removed, is listed at the top level rather than dropped: a report
    /// must not disappear with its manager.
    ///
    /// `collapsed` names managers whose reports are hidden. The manager
    /// itself stays, with `isCollapsed` set, so the row can say that it has
    /// more behind it.
    ///
    /// `modelUnavailable` names workers whose model a check found missing,
    /// `activities` what a worker is doing, and `unread` what its direct
    /// conversation holds unseen, by worker. They change what a row says and
    /// never where it is.
    public static func rows(
        of workers      : [WorkerSnapshot],
        collapsed       : Set<UUID>      = [],
        modelUnavailable: Set<UUID>      = [],
        activities      : [UUID: String] = [:],
        unread          : [UUID: UnreadState] = [:]
    ) -> [TeamRow] {

        let present = Set(workers.map(\.id))
        var reports: [UUID: [WorkerSnapshot]] = [:]
        var roots  : [WorkerSnapshot]         = []

        for worker in workers {
            if let manager = worker.managerID, present.contains(manager) {
                reports[manager, default: []].append(worker)
            } else {
                roots.append(worker)
            }
        }

        var rows   : [TeamRow] = []
        var visited: Set<UUID> = []

        // A folded subtree is walked and not emitted: an unwalked worker looks
        // unreachable to the sweep below and would come back at the top level.
        func visit(_ worker: WorkerSnapshot, depth: Int, isHidden: Bool) {
            guard visited.insert(worker.id).inserted else { return }
            let children = reports[worker.id] ?? []
            let isFolded = collapsed.contains(worker.id)

            if !isHidden {
                rows.append(
                    TeamRow(
                        worker            : worker,
                        depth             : depth,
                        hasReports        : !children.isEmpty,
                        isCollapsed       : isFolded,
                        isModelUnavailable: modelUnavailable.contains(worker.id),
                        activity          : activities[worker.id],
                        unread            : unread[worker.id] ?? .none
                    )
                )
            }

            for child in children {
                visit(child, depth: depth + 1, isHidden: isHidden || isFolded)
            }
        }

        for root in roots { visit(root, depth: 0, isHidden: false) }

        // A cycle among managers leaves its members unreachable from any root.
        // The store refuses to write one; a store that holds one lists them.
        for worker in workers where !visited.contains(worker.id) {
            visit(worker, depth: 0, isHidden: false)
        }

        return rows
    }
}
