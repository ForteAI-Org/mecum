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
/// then what acts on the context, below a hairline: compacting it, starting it
/// again, and a quiet line saying Mecum compacts it on its own.
///
/// The actions stay enabled while the worker is busy. Used then, they do
/// nothing and the quiet line says why (`waitReason`), until the worker is free.
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

    /// True once an action was used while `waitReason` held.
    @State private var isTellingWhy = false

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
        VStack(
            alignment: .leading,
            spacing  : 10
        ) {
            action(
                "Compact context",
                detail: "Summarizes the conversation so far and keeps going.",
                run   : compact
            )

            action(
                "Start fresh context",
                detail: "Forgets everything before now. The chat stays.",
                run   : startFresh
            )

            Text(isTellingWhy ? waitReason ?? Self.automatic : Self.automatic)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical  : true
                )
        }
    }

    private static let automatic = "Mecum compacts it on its own above 90%."

    private func action(
        _ title: String,
        detail : String,
        run    : @escaping () -> Void
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 4
        ) {
            Button(title) {
                guard waitReason == nil else {
                    isTellingWhy = true
                    return
                }
                run()
            }
            .accessibilityHint(detail)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical  : true
                )
                .accessibilityHidden(true)
        }
    }
}
