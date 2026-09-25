//
//  ConversationContextButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// ConversationContextButton is the small context ring above the composer's
/// trailing edge. Its tooltip says how full the context is; it opens and
/// closes the context popup, which the composer presents above itself
/// (`ConversationPopupPresenter`), and reports where it is so the popup can
/// be placed over it.
struct ConversationContextButton: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context: WorkerUsage.Context

    @Binding var isOpen: Bool

    /// Where the button is in the window, for the popup and for telling a click outside.
    @Binding var frame: CGRect

    var body: some View {
        let wording = UsageWording()

        Button { isOpen.toggle() } label: {
            ConversationContextRing(
                fraction : context.fraction ?? 0,
                side     : 18,
                lineWidth: 2.2
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(wording.contextTip(context))
        .accessibilityLabel("Context")
        .accessibilityValue(wording.contextSpoken(context))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}
