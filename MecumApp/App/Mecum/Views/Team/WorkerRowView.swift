//
//  WorkerRowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

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
struct WorkerRowView: View {

    let row       : TeamRow
    let isCompact : Bool
    let isSelected: Bool

    /// True while the team's list has focus in the active window: a selected
    /// block is then the accent colour, and what is on it turns white.
    let isFocused: Bool

    private var isEmphasized: Bool { isSelected && isFocused }

    var body: some View {
        Group {
            if isCompact { tile } else { line }
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .background { SidebarBlock(isSelected: isSelected, isEmphasized: isEmphasized) }
        .padding(.vertical, SidebarBlock.spacing / 2)
        .listRowInsets(EdgeInsets())
        .help(isCompact ? "\(row.name), \(row.subtitle)" : row.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var line: some View {
        HStack(spacing: 10) {
            MascotView(appearance: row.worker.appearance, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .fontWeight(.medium)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            indicator
        }
        .padding(.vertical, 8)
        .padding(.horizontal, SidebarBlock.contentInset - SidebarBlock.listContentInset)
        .frame(minHeight: 48)
    }

    private var tile: some View {
        VStack(spacing: 4) {
            MascotView(appearance: row.worker.appearance, size: 32)
                .overlay(alignment: .topTrailing) {
                    indicator.offset(x: 7, y: -4)
                }
            Text(row.name)
                .font(.caption)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    /// The attention mark when a turn failed or stopped unseen, else the unread
    /// replies as an accent capsule, else nothing; a quiet row shows neither
    /// (§4.3). On the accent selection the mark and the capsule turn white, so
    /// they stay apart from the block they sit on.
    @ViewBuilder
    private var indicator: some View {
        if row.needsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.red))
                .font(isCompact ? .caption : .body)
        } else if let count = row.badgeText {
            Text(count)
                .font((isCompact ? Font.caption2 : .caption).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isEmphasized ? Color(nsColor: .selectedContentBackgroundColor) : .white)
                .padding(.horizontal, isCompact ? 4 : 6)
                .frame(minWidth: isCompact ? 16 : 20, minHeight: isCompact ? 16 : 20)
                .background(Capsule().fill(isEmphasized ? Color.white : .accentColor))
        }
    }
}
