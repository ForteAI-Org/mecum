//
//  InspectorScreenSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// The live screen while there is a window to watch and it is not over the
/// conversation, where the toolbar's screen toggle puts it; nothing otherwise.
struct InspectorScreenSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        if team.hasScreen(worker.id), !team.showsScreenInConversation {
            Section("Screen") {
                WorkerScreenCard(
                    team  : team,
                    worker: worker
                )
            }
        }
    }
}
