//
//  InspectorScreenSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import Workspace

/// The live screen while there is a window to watch; nothing otherwise, and
/// one line while it floats over the conversation.
struct InspectorScreenSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        if team.hasScreen(worker.id) {
            Section("Screen") {
                if team.showsScreenInConversation {
                    LabeledContent("Shown over the conversation") {
                        Button("Put back") { withAnimation(.snappy) { team.showsScreenInConversation = false } }
                            .controlSize(.small)
                    }
                } else {
                    WorkerScreenCard(
                        team  : team,
                        worker: worker,
                        place : .inspector
                    )
                }
            }
        }
    }
}
