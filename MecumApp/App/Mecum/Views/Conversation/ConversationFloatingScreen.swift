//
//  ConversationFloatingScreen.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// The worker's live screen at the top right, below the title bar, when the
/// person moved it here from the inspector and there is a window to watch.
struct ConversationFloatingScreen: View {

    let team          : TeamModel
    let worker        : WorkerSnapshot
    let titleBarHeight: CGFloat

    var body: some View {
        if team.showsScreenInConversation, team.hasScreen(worker.id) {
            WorkerScreenCard(
                team  : team,
                worker: worker,
                place : .conversation
            )
            .padding(6)
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style       : .continuous
                )
            )
            .shadow(
                color : .black.opacity(0.18),
                radius: 10,
                y     : 4
            )
            .frame(width: 280)
            .padding(
                .top,
                titleBarHeight + 8
            )
            .padding(
                .trailing,
                16
            )
            .ignoresSafeArea(
                .container,
                edges: .top
            )
            .transition(.scale(
                scale : 0.85,
                anchor: .topTrailing
            ).combined(with: .opacity))
        }
    }
}
