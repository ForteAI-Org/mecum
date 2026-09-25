//
//  ConversationContextButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import SwiftUI

/// ConversationContextButton is the context ring on a round button of its own,
/// left of the composer's pill and as tall as the pill at one line. It is
/// drawn on the pill's own surface (`ComposerSurface`), the material, or the
/// solid surface with Reduce Transparency, so the two read as one family; the
/// pill is never Liquid Glass, so neither is this. Its tooltip says how full
/// the context is, and it opens a popover of the context and the last message
/// (`ConversationContextPopover`) above itself.
struct ConversationContextButton: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context : WorkerUsage.Context

    let lastTurn: ProviderUsage.Tokens?

    @State private var isShowingDetail = false

    @Environment(\.accessibilityReduceTransparency)
    private var reducesTransparency

    var body: some View {
        let wording = UsageWording()
        let side    = ComposerBar.restingHeight

        Button { isShowingDetail.toggle() } label: {
            ConversationContextRing(
                fraction : context.fraction ?? 0,
                side     : 20,
                lineWidth: 2.2
            )
            .frame(
                width : side,
                height: side
            )
            .modifier(ComposerSurface(
                shape: RoundedRectangle(
                    cornerRadius: side / 2,
                    style       : .circular
                ),
                kind : .resolved(reducesTransparency: reducesTransparency)
            ))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(wording.contextTip(context))
        .accessibilityLabel("Context")
        .accessibilityValue(wording.contextSpoken(context))
        .popover(
            isPresented: $isShowingDetail,
            arrowEdge  : .top
        ) {
            ConversationContextPopover(
                context : context,
                lastTurn: lastTurn
            )
        }
    }
}
