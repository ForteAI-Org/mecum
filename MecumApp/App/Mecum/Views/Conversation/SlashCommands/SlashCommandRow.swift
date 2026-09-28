//
//  SlashCommandRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import SwiftUI

/// SlashCommandRow is one row of the command popup, drawn as a model row is:
/// the command's symbol, its name, the argument it takes in a tertiary style
/// and, a size smaller, what it does; or a model, a level or a place, with a
/// check on the worker's own. A row that cannot run now is dimmed and says why
/// in place of what it does. The selected row has the quiet highlight a model row has
/// under the pointer, and the pointer selects the row it passes over.
struct SlashCommandRow: View {

    let row       : SlashCommandSuggestions.Row
    let isSelected: Bool
    let select    : () -> Void
    let choose    : () -> Void

    /// Fixed, so the popup's height follows from its number of rows.
    static let height: CGFloat = 30

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                if let symbol = row.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }

                HStack(spacing: 4) {
                    Text(row.title)
                        .foregroundStyle(.primary)

                    if let hint = row.argumentHint {
                        Text(hint)
                            .foregroundStyle(.tertiary)
                    }
                }
                .fixedSize()

                // Wide as what is left, so the line gets all the room a long reason needs.
                if let line {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(
                            .leading,
                            4
                        )
                        .frame(
                            maxWidth : .infinity,
                            alignment: .leading
                        )
                } else {
                    Spacer(minLength: 0)
                }

                if row.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(
                .horizontal,
                10
            )
            .frame(height: Self.height)
            .background(
                .quaternary.opacity(isSelected ? 0.8 : 0),
                in: RoundedRectangle(
                    cornerRadius: 8,
                    style       : .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.unavailableReason != nil)
        .onHover { if $0 { select() } }
        .help(row.unavailableReason ?? "")
        .accessibilityLabel(row.title)
        .accessibilityHint(line ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// What it does, or why it cannot run now.
    private var line: String? {
        row.unavailableReason ?? row.summary
    }
}
