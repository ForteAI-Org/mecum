//
//  ConversationContextPopover.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import SwiftUI

/// ConversationContextPopover is what the context ring opens, laid out as the
/// token counter's popover is: how full the model's context is, as a share and
/// in tokens against the window with a bar, then the last message's tokens.
/// Its sections are a stack, so what acts on the context can follow them.
struct ConversationContextPopover: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context : WorkerUsage.Context

    /// The worker's latest turn's own tokens, nil before one reported them.
    let lastTurn: ProviderUsage.Tokens?

    var body: some View {
        UsagePopover {
            contextSection

            if let lastTurn {
                Divider()

                UsageLastMessage(tokens: lastTurn)
            }
        }
    }

    private var contextSection: some View {
        let wording  = UsageWording()
        let fraction = context.fraction ?? 0

        return VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            UsageSectionTitle("Context")

            UsageMeter(
                label   : "Used",
                value   : wording.contextUsed(context),
                fraction: fraction,
                fill    : ConversationContextRing.style(of: UsageWording.contextLevel(fraction)),
                spoken  : "Context used: \(wording.contextSpoken(context))"
            )
        }
    }
}
