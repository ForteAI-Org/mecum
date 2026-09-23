//
//  WorkerRowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

/// WorkerRowView is one line of the team: mascot, name, subtitle and the
/// indicator that says the worker wants attention.
///
/// The row is 56 points and the mascot 32, and neither changes with rank: a
/// manager's mascot is the same size as its reports'. Indentation and the
/// disclosure control are the only thing that says who reports to whom.
///
/// The indicators are a symbol or a number and not a colour, so they survive a
/// person who cannot tell the colours apart, and they never repaint the mascot.
/// A badge changes the row's trailing edge only, never its height or place.
struct WorkerRowView: View {

    let row   : TeamRow
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            disclosure
            MascotView(appearance: row.worker.appearance)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            if !row.worker.isConfigured {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            badge
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .frame(minHeight: 56)
        .help(row.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// The unread replies as an accent capsule, or the attention mark when a
    /// turn failed or stopped unseen. The mark is a symbol, never colour alone,
    /// and a quiet row shows neither (§4.3).
    @ViewBuilder
    private var badge: some View {
        if row.needsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let count = row.badgeText {
            Text(count)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(Capsule().fill(Color.accentColor))
        }
    }

    /// The control that folds a manager's reports away. A worker with no
    /// reports keeps the same width, so the names stay on one column.
    @ViewBuilder
    private var disclosure: some View {
        if row.hasReports {
            Button(action: toggle) {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(row.isCollapsed ? "Show the reports of \(row.name)" : "Hide the reports of \(row.name)")
            .accessibilityLabel(row.isCollapsed ? "Show reports" : "Hide reports")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }
}
