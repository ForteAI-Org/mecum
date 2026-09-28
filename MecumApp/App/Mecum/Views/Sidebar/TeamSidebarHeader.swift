//
//  TeamSidebarHeader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// The sidebar's title and the button that adds a worker, at the trailing
/// end of the same line as in a grouped form's header; alone and centred
/// over the tiles.
struct TeamSidebarHeader: View {

    let team     : TeamModel
    let isCompact: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        ZStack {
            // Laid out in both widths and faded, so the change never squeezes it into a column.
            Text("Team")
                .font(.title3.weight(.semibold))
                .fixedSize()
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .padding(
                    .leading,
                    SidebarBlock.contentInset
                )
                .opacity(isCompact ? 0 : 1)
                // Gone before the plus crosses it, and back once the plus has passed.
                .animation(
                    reducesMotion ? nil : (isCompact ? .easeOut(duration: 0.1) : .easeIn(duration: 0.15).delay(0.15)),
                    value: isCompact
                )
                .accessibilityHidden(isCompact)
                .accessibilityAddTraits(.isHeader)

            Button(
                "New Worker",
                systemImage: "plus"
            ) {
                team.isCreatingWorker = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3.weight(.medium))
            .frame(
                width : 28,
                height: 28
            )
            .contentShape(Rectangle())
            .help("Create a new worker.")
            .keyboardShortcut(
                "n",
                modifiers: .command
            )
            .frame(
                maxWidth : .infinity,
                alignment: isCompact ? .center : .trailing
            )
            // The plus sits about 6 points inside its 28 point frame, so its edge meets the badges' edge.
            .padding(
                .trailing,
                isCompact ? 0 : SidebarBlock.contentInset - 6
            )
        }
        .padding(
            .top,
            2
        )
        .padding(
            .bottom,
            6
        )
    }
}
