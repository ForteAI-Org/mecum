//
//  TeamOutline.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// TeamOutline puts the team in the order the sidebar shows it.
///
/// The team is a flat list, in the order the workers arrive, which is the
/// order the store sorted them by, so a worker changing state does not move.
/// The sidebar is a list of people, not a queue of what is busy.
public enum TeamOutline {

    /// The rows for `workers`, in their order.
    ///
    /// `modelUnavailable` names workers whose model a check found missing,
    /// `activities` what a worker is doing, and `unread` what its direct
    /// conversation holds unseen, by worker. They change what a row says and
    /// never where it is.
    public static func rows(
        of workers      : [WorkerSnapshot],
        modelUnavailable: Set<UUID>           = [],
        activities      : [UUID: String]      = [:],
        unread          : [UUID: UnreadState] = [:]
    ) -> [TeamRow] {
        workers.map { worker in
            TeamRow(
                worker            : worker,
                isModelUnavailable: modelUnavailable.contains(worker.id),
                activity          : activities[worker.id],
                unread            : unread[worker.id] ?? .none
            )
        }
    }
}
