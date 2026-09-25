//
//  InspectorNowSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// Where the worker is in the flow: whether it answers, and what it does with the computer.
struct InspectorNowSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        Section("Now") {
            LabeledContent("Status") {
                if team.isAnswering(worker.id) {
                    StatusText(
                        "Answering",
                        tone: .active
                    )
                } else {
                    StatusText(
                        "Idle",
                        tone: .quiet
                    )
                }
            }

            LabeledContent("Computer") { computer }
        }
    }

    @ViewBuilder
    private var computer: some View {
        if team.holdsComputer(worker.id) {
            StatusText(
                team.activity(of: worker.id) ?? "Using This Mac",
                tone: .active
            )
        } else if let activity = team.activity(of: worker.id) {
            StatusText(
                activity,
                tone: .waiting
            )
        } else {
            Text("Not Using This Mac")
                .foregroundStyle(.secondary)
        }
    }
}
