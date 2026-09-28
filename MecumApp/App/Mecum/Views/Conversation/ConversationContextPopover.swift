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
/// in tokens against the window with a bar, then the last message's tokens,
/// then what acts on the context, below a hairline: compacting it and starting it
/// again, as icons side by side at the trailing edge.
///
/// The actions stay enabled while the worker is busy. Used then, they do
/// nothing, and their tooltip says why (`waitReason`) until the worker is free.
struct ConversationContextPopover: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context   : WorkerUsage.Context

    /// The worker's latest turn's own tokens, nil before one reported them.
    let lastTurn  : ProviderUsage.Tokens?

    /// Why the actions wait, nil while the worker is free to act on its context.
    let waitReason: String?

    /// Each closes the popover first; the caller then acts.
    let compact   : () -> Void
    let startFresh: () -> Void

    var body: some View {
        UsagePopover {
            contextSection

            if let lastTurn {
                Divider()

                UsageLastMessage(tokens: lastTurn)
            }

            Divider()

            actions
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

    private var actions: some View {
        HStack(spacing: 8) {
            action(
                "Compact context",
                systemImage: "arrow.down.right.and.arrow.up.left",
                detail     : "Summarizes the conversation so far and keeps going. Mecum does it on its own above 90%.",
                run        : compact
            )

            action(
                "Start fresh context",
                systemImage: "arrow.counterclockwise",
                detail     : "Forgets everything before now. The chat stays.",
                run        : startFresh
            )
        }
        .frame(
            maxWidth : .infinity,
            alignment: .trailing
        )
    }

    /// An icon alone; what it does, or why it waits, is its tooltip and its VoiceOver hint.
    private func action(
        _ title    : String,
        systemImage: String,
        detail     : String,
        run        : @escaping () -> Void
    ) -> some View {
        Button {
            guard waitReason == nil else { return }
            run()
        } label: {
            Label(
                title,
                systemImage: systemImage
            )
            .labelStyle(.iconOnly)
        }
        .help(waitReason ?? "\(title): \(detail)")
        .accessibilityHint(waitReason ?? detail)
    }
}
