//
//  WorkerRowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// WorkerRowView is one worker of the team, as a block: mascot, name, the
/// line under it and the indicator that says the worker wants attention, or,
/// in the compact sidebar, a tile with the mascot and the name under it.
///
/// The block is 48 points with a 28 point mascot; the tile has a 32 point
/// mascot and carries its indicator on the mascot's corner, as a pinned
/// conversation does. The line under the name is `TeamRow.subtitle`, one fact
/// at a time. A tile shows only the name, and its tooltip and accessibility
/// label carry everything else.
///
/// The indicators are a symbol or a number and not a colour, so they survive a
/// person who cannot tell the colours apart, and they never repaint the mascot.
/// A badge changes the row's trailing edge only, never its height or place.
///
/// A change of `isCompact` made in an animation morphs the block into the
/// tile: the mascot and the name move and resize in place, the line under the
/// name fades, and the indicator travels between the trailing edge and the
/// mascot's corner. Under Reduce Motion nothing fades either.
struct WorkerRowView: View {

    let row       : TeamRow
    let isCompact : Bool
    let isSelected: Bool

    /// True while the team's sidebar has focus in the active window: a selected
    /// block is then the accent colour, and what is on it turns white.
    let isFocused: Bool

    private var isEmphasized: Bool { isSelected && isFocused }

    @Namespace private var morph

    private var showsModel      : Bool { AppPreferenceValues.shared.sidebarShowsModel }
    private var showsUnreadCount: Bool { AppPreferenceValues.shared.sidebarShowsUnreadCount }

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        content
            .frame(
                maxWidth : .infinity,
                alignment: isCompact ? .center : .leading
            )
            .background {
                SidebarBlock(
                    isSelected  : isSelected,
                    isEmphasized: isEmphasized
                )
            }
            .padding(
                .vertical,
                SidebarBlock.spacing / 2
            )
            .help(isCompact ? "\(row.name), \(row.subtitle)" : row.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One layout that is a line in the full sidebar and a tile in the compact
    /// one, with the same mascot and name in both, so the change moves them.
    private var content: some View {
        let layout = isCompact ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            MascotView(
                appearance: row.worker.appearance,
                size      : isCompact ? 32 : 28
            )
            .overlay(alignment: .topTrailing) {
                if isCompact {
                    indicator
                        .matchedGeometryEffect(
                            id: "indicator",
                            in: morph
                        )
                        .offset(
                            x: 7,
                            y: -4
                        )
                }
            }

            VStack(
                alignment: isCompact ? .center : .leading,
                spacing  : 1
            ) {
                Text(row.name)
                    .font(isCompact ? .caption : .body)
                    .fontWeight(isCompact ? .regular : .medium)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !isCompact, let subtitle = row.subtitle(showingModel: showsModel) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(isEmphasized ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // It fades in once the name has nearly reached it, and out quickly as the name leaves.
                        .transition(reducesMotion ? .identity : .asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.15)),
                            removal  : .opacity.animation(.easeOut(duration: 0.1))
                        ))
                }
            }

            if !isCompact {
                Spacer(minLength: 4)
                indicator
                    .matchedGeometryEffect(
                        id: "indicator",
                        in: morph
                    )
            }
        }
        // The mascot and the name take their new size at once and move, rather than fading one into another.
        .contentTransition(.identity)
        .padding(
            .top,
            8
        )
        .padding(
            .bottom,
            isCompact ? 7 : 8
        )
        .padding(
            .horizontal,
            isCompact ? 0 : SidebarBlock.contentInset - SidebarBlock.gutter
        )
        .frame(minHeight: isCompact ? nil : 48)
    }

    /// The attention mark when a turn failed or stopped unseen, else the unread
    /// replies as an accent capsule unless Settings turns the count off, else
    /// nothing; a quiet row shows neither (§4.3). On the accent selection the mark and the capsule turn white, so
    /// they stay apart from the block they sit on.
    @ViewBuilder
    private var indicator: some View {
        if row.needsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.red))
                .font(isCompact ? .caption : .body)
        } else if showsUnreadCount, let count = row.badgeText {
            Text(count)
                .font((isCompact ? Font.caption2 : .caption).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isEmphasized ? Color(nsColor: .selectedContentBackgroundColor) : .white)
                .padding(
                    .horizontal,
                    isCompact ? 4 : 6
                )
                .frame(
                    minWidth : isCompact ? 16 : 20,
                    minHeight: isCompact ? 16 : 20
                )
                .background(Capsule().fill(isEmphasized ? Color.white : .accentColor))
        }
    }
}
