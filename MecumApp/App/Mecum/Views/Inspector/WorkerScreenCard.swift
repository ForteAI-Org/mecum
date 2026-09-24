//
//  WorkerScreenCard.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// WorkerScreenCard is the worker's live screen with the one control it needs:
/// moving it between the inspector and the top right of the conversation.
///
/// It keeps the window's proportions, 16 by 10 until a window is measured.
/// While there is no window to watch it draws nothing; the inspector says why.
struct WorkerScreenCard: View {

    enum Place { case inspector, conversation }

    let team  : TeamModel
    let worker: WorkerSnapshot
    let place : Place

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
            .overlay(alignment: .topTrailing) { moveButton.padding(6) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(worker.name)'s screen")
        }
    }

    private var moveButton: some View {
        let toConversation = place == .inspector

        return Button {
            withAnimation(.snappy) { team.showsScreenInConversation = toConversation }
        } label: {
            Image(systemName: toConversation ? "pip.enter" : "pip.exit")
                .font(.system(
                    size  : 11,
                    weight: .semibold
                ))
                .frame(
                    width : 22,
                    height: 22
                )
                .background(
                    .regularMaterial,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(toConversation ? "Show the screen over the conversation" : "Put the screen back in the inspector")
        .accessibilityLabel(toConversation ? "Show over the conversation" : "Put back in the inspector")
    }
}
