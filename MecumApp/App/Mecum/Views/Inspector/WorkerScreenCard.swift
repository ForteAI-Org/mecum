//
//  WorkerScreenCard.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// WorkerScreenCard is the worker's live screen, in the inspector or at the top
/// right of the conversation; the toolbar's screen toggle moves it.
///
/// It keeps the window's proportions, 16 by 10 until a window is measured.
/// While there is no window to watch it draws nothing; the inspector says why.
struct WorkerScreenCard: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        if team.hasScreen(worker.id) {
            let frame = team.screenFrame(of: worker.id)
            let ratio = frame.width > 0 && frame.height > 0 ? frame.width / frame.height : 16.0 / 10.0
            WorkerScreenView(
                team    : team,
                workerID: worker.id
            )
            .id(worker.id)
            .aspectRatio(
                ratio,
                contentMode: .fit
            )
            .clipShape(RoundedRectangle(
                cornerRadius: 8,
                style       : .continuous
            ))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(worker.name)'s screen")
        }
    }
}
