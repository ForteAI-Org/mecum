//
//  ConversationModelRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// ConversationModelRow is one model in the popup's list: its name, a check
/// on the worker's model, and a quiet highlight under the pointer.
struct ConversationModelRow: View {

    let title     : String
    let isSelected: Bool
    let choose    : () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(
                .horizontal,
                10
            )
            .frame(height: 30)
            .background(
                .quaternary.opacity(isHovered ? 0.8 : 0),
                in: RoundedRectangle(
                    cornerRadius: 8,
                    style       : .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
