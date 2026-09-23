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
/// The same content fills the row's context menu and a menu in the toolbar,
/// so changing a manager and archiving are reachable from the keyboard and
/// not only from a right click or a drag. That is the point: dragging a row
/// onto another is a convenience this increment does not build, and the
/// command is the function.
///
/// Every active worker is offered as a manager, including one that would
/// close a loop. The store owns that invariant and refuses before it saves;
/// the refusal comes back as a sentence rather than as a menu item that was
/// quietly missing.
struct WorkerCommands: View {

    let worker: WorkerSnapshot
    let team  : TeamModel

    var body: some View {
        if team.isAnswering(worker.id) {
            Button("Stop answering") { team.stopAnswering(worker.id) }
            Divider()
        }

        if !worker.isArchived {
            Button("Model and connection…") { team.profileWorkerID = worker.id }
            Divider()
        }

        Menu("Change manager") {
            Button("No manager") {
                Task { await team.changeManager(of: worker.id, to: nil) }
            }
            .disabled(worker.managerID == nil)

            Divider()

            ForEach(team.candidateManagers(for: worker.id)) { candidate in
                Button(candidate.name) {
                    Task { await team.changeManager(of: worker.id, to: candidate.id) }
                }
                .disabled(candidate.id == worker.managerID)
            }
        }

        Divider()

        if worker.isArchived {
            Button("Restore to the team") {
                Task { await team.setArchived(false, for: worker.id) }
            }
        } else {
            Button("Archive") {
                Task { await team.setArchived(true, for: worker.id) }
            }
        }
    }
}
