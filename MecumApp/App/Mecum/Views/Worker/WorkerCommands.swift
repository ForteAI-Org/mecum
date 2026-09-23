//
//  WorkerCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

/// WorkerCommands is what can be done to one worker, as menu items.
///
/// The same content fills the row's context menu and the Team menu,
/// so archiving is reachable from the keyboard and not only from a right
/// click.
struct WorkerCommands: View {

    let worker: WorkerSnapshot
    let team  : TeamModel

    var body: some View {
        if team.isAnswering(worker.id) {
            Button("Stop answering") { team.stopAnswering(worker.id) }
            Divider()
        }

        // The composer's release button has this command behind it, reachable without a pointer (§3.3).
        if team.holdsComputer(worker.id) {
            Button("Release the computer") { Task { await team.releaseComputer(worker.id) } }
            Divider()
        }

        if !worker.isArchived {
            Button("Model and connection…") { team.profileWorkerID = worker.id }
            Divider()
        }

        if worker.isArchived {
            Button("Restore to the team") {
                Task {
                    await team.setArchived(
                        false,
                        for: worker.id
                    )
                }
            }
        } else {
            Button("Archive") {
                Task {
                    await team.setArchived(
                        true,
                        for: worker.id
                    )
                }
            }
        }
    }
}
