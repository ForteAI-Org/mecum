//
//  ConversationModelButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ConversationModelButton is the worker's model and effort in the composer's
/// own row, quiet text with a light highlight under the pointer. It opens and
/// closes the model popup, which the composer presents above itself
/// (`ConversationModelPresenter`), and reports where it is so the popup can be
/// centred on it.
struct ConversationModelButton: View {

    let selection: ModelSelection

    let catalogue: [ModelInfo]?

    @Binding var isOpen: Bool

    /// Where the button is in the window, for the popup and for telling a click outside.
    @Binding var frame: CGRect

    /// False while the worker answers: its turn has already fixed its model.
    let isEnabled: Bool

    @State private var isHovered = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)

                if !scale.isEmpty {
                    Text("·")
                    Text(selection.effort.title(for: selection.provider))
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(isOpen ? .primary : .secondary)
            .padding(
                .horizontal,
                8
            )
            .frame(height: ComposerBar.circleSide)
            .background(
                .quaternary.opacity(isOpen ? 1 : isHovered ? 0.5 : 0),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 && isEnabled }
        .disabled(!isEnabled)
        .help("Model and Effort")
        .accessibilityLabel("Model and Effort: \(selection.line)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onChange(of: isEnabled) {
            if !isEnabled { isOpen = false }
        }
    }

    private var title: String {
        catalogue?.first { $0.id == selection.model }?.title ?? selection.model
    }

    private var scale: EffortScale {
        EffortScale(
            provider: selection.provider,
            model   : selection.model
        )
    }
}
