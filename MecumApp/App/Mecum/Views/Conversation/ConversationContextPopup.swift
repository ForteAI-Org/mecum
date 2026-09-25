//
//  ConversationContextPopup.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// ConversationContextPopup is what the context ring opens above the composer:
/// the ring drawn larger, how full the context is, and the tokens that fill it
/// against the model's window. The summary is one row of a stack, so what acts
/// on the context can follow it.
struct ConversationContextPopup: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context: WorkerUsage.Context

    /// Fixed, so a longer number changes only the text, never the popup.
    static let width: CGFloat = 260

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 14
        ) {
            summary
        }
        .padding(16)
        .frame(
            width    : Self.width,
            alignment: .leading
        )
        .modifier(ConversationPopupSurface())
    }

    private var summary: some View {
        let wording = UsageWording()

        return HStack(spacing: 12) {
            ConversationContextRing(
                fraction : context.fraction ?? 0,
                side     : 44,
                lineWidth: 4
            )

            VStack(
                alignment: .leading,
                spacing  : 2
            ) {
                Text(wording.contextTitle(context))
                    .font(.headline)
                    .contentTransition(.numericText())

                Text(wording.contextTokens(context))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context")
        .accessibilityValue(wording.contextSpoken(context))
    }
}
