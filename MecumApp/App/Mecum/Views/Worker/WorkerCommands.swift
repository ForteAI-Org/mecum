//
//  WorkerCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// WorkerCommands is what can be done to one worker, as menu items.
///
/// The same content fills the row's context menu and the Team menu,
/// so archiving is reachable from the keyboard and not only from a right
/// click. Deleting for good comes last and asks first, in the team window;
/// it waits while the worker is answering.
struct WorkerCommands: View {

    let worker: WorkerSnapshot
    let team  : TeamModel

    var body: some View {
        if team.isAnswering(worker.id) {
            Button("Stop Response") { team.stopAnswering(worker.id) }
            Divider()
        }

        // The composer's release button has this command behind it, reachable without a pointer (§3.3).
        if team.holdsComputer(worker.id) {
            Button("Release Computer") { Task { await team.releaseComputer(worker.id) } }
            Divider()
        }

        if !worker.isArchived {
            Button("Choose Provider…") {
                team.selection = worker.id
                withAnimation(.snappy(duration: 0.25)) { team.choosingProviderFor = worker.id }
            }
            Divider()
        }

        if worker.isArchived {
            Button("Restore to Team") {
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

        Divider()

        Button(
            "Delete…",
            role: .destructive
        ) {
            team.deletingWorker = worker.id
        }
        .disabled(team.isAnswering(worker.id))
    }
}
