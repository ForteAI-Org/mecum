//
//  SlashCommandPopup.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import SwiftUI

/// SlashCommandPopup is what a draft that starts with `/` opens above the
/// composer, at its leading edge: the commands that match it, or after
/// `/model `, `/effort ` or `/screen ` what the command takes, on the model
/// popup's surface. It grows with its rows up to about eight, then scrolls,
/// keeping the selected row in view.
///
/// The keyboard never leaves the composer's field, which hands the popup its
/// keys (`SlashCommandMenu`), so VoiceOver is told each row the keys move to.
struct SlashCommandPopup: View {

    let rows    : [SlashCommandSuggestions.Row]
    let selected: SlashCommandSuggestions.Row.ID?
    let select  : (SlashCommandSuggestions.Row) -> Void
    let choose  : (SlashCommandSuggestions.Row) -> Void

    /// The row the pointer selected, which is in view already, so the list does not scroll to it.
    @State private var hovered: SlashCommandSuggestions.Row.ID?

    /// Fixed, so a longer reason changes only its own line, never the popup.
    static let width: CGFloat = 420

    static let padding   : CGFloat = 16
    static let rowSpacing: CGFloat = 2

    /// Eight rows and half of a ninth, which says the list scrolls.
    static let maximumListHeight = 8.5 * (SlashCommandRow.height + rowSpacing)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        SlashCommandRow(
                            row       : row,
                            isSelected: row.id == selected,
                            select    : {
                                hovered = row.id
                                select(row)
                            },
                            choose    : { choose(row) }
                        )
                        .id(row.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maximumListHeight)
            .fixedSize(
                horizontal: false,
                vertical  : true
            )
            .onChange(of: selected) {
                defer { hovered = nil }
                guard let selected, selected != hovered else { return }
                proxy.scrollTo(selected)
            }
        }
        .padding(Self.padding)
        .frame(
            width    : Self.width,
            alignment: .top
        )
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: 16,
                style       : .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 16,
                style       : .continuous
            )
            .strokeBorder(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        )
        .shadow(
            color : .black.opacity(0.16),
            radius: 12,
            y     : 4
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
        .onChange(
            of     : selected,
            initial: true
        ) { announce() }
    }

    /// Says the selected row, what it does or why it cannot run, from the field the keyboard stays in.
    private func announce() {
        guard let row = rows.first(where: { $0.id == selected }) else { return }

        let line = row.unavailableReason ?? row.summary
        AccessibilityNotification.Announcement(line.map { "\(row.title), \($0)" } ?? row.title).post()
    }
}
