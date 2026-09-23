//
//  TeamSidebarArchive.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

/// The archive's title, which folds and unfolds it, and its rows while unfolded.
struct TeamSidebarArchive: View {

    let team: TeamModel

    /// Whether the archive is unfolded, which the sidebar's Up and Down also read.
    @Binding var showsArchive: Bool

    let isCompact: Bool

    /// True while the team's sidebar has focus in the active window.
    let isFocused: Bool

    /// The sidebar's folding animation, nil under Reduce Motion.
    let motion: Animation?

    /// Selects a worker and focuses the sidebar, as a click on a row does.
    let select: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(motion) { showsArchive.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(isCompact ? "Archive" : "Archive (\(team.archived.count))")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsArchive ? 90 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(
                .horizontal,
                isCompact ? 0 : SidebarBlock.contentInset - SidebarBlock.gutter
            )
            .padding(
                .top,
                14
            )
            .padding(
                .bottom,
                4
            )
            .accessibilityValue(showsArchive ? "Expanded" : "Collapsed")

            if showsArchive {
                ForEach(team.archived) { worker in
                    archivedRow(worker)
                }
            }
        }
    }

    /// An archived worker, quieter than the team: a small mascot and the name,
    /// or the mascot alone in the compact sidebar, with the name in its tooltip.
    /// It has no block of its own, only the selection's while it is selected.
    private func archivedRow(_ worker: WorkerSnapshot) -> some View {
        let isSelected   = team.selection == worker.id
        let isEmphasized = isSelected && isFocused

        return HStack(spacing: 8) {
            MascotView(
                appearance: worker.appearance,
                size      : 20
            )
            if !isCompact {
                Text(worker.name)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(
            maxWidth : .infinity,
            minHeight: 28,
            alignment: isCompact ? .center : .leading
        )
        .padding(
            .horizontal,
            SidebarBlock.contentInset - SidebarBlock.gutter
        )
        .background {
            if isSelected {
                SidebarBlock(
                    isSelected  : true,
                    isEmphasized: isEmphasized
                )
            }
        }
        .padding(
            .vertical,
            SidebarBlock.spacing / 2
        )
        .contentShape(Rectangle())
        .onTapGesture { select(worker.id) }
        .help(worker.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worker.name), archived")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(worker.id) }
        .contextMenu {
            WorkerCommands(
                worker: worker,
                team  : team
            )
        }
        .id(worker.id)
    }
}
