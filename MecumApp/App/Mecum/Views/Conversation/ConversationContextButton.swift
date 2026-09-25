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
/// the context is, or that it is being compacted, and it opens a popover of
/// the context, the last message and the context's actions
/// (`ConversationContextPopover`) above itself. Starting a fresh context asks
/// first, since it forgets.
struct ConversationContextButton: View {

    /// A context whose window is known (`UsageWording.ringContext`).
    let context     : WorkerUsage.Context
    let lastTurn    : ProviderUsage.Tokens?

    /// The worker's name, which the confirmation says.
    let worker      : String
    let isCompacting: Bool

    /// Why the actions wait, nil while the worker is free (`ConversationContextPopover.waitReason`).
    let waitReason  : String?
    let compact     : () -> Void
    let startFresh  : () -> Void

    @State private var isShowingDetail   = false
    @State private var isConfirmingFresh = false

    @Environment(\.accessibilityReduceTransparency)
    private var reducesTransparency

    var body: some View {
        let wording = UsageWording()
        let side    = ComposerBar.restingHeight

        Button { isShowingDetail.toggle() } label: {
            ConversationContextRing(
                fraction       : context.fraction ?? 0,
                side           : 20,
                lineWidth      : 2.2,
                isIndeterminate: isCompacting
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
        .help(isCompacting ? UsageWording.compacting : wording.contextTip(context))
        .accessibilityLabel("Context")
        .accessibilityValue(isCompacting ? UsageWording.compacting : wording.contextSpoken(context))
        .popover(
            isPresented: $isShowingDetail,
            arrowEdge  : .top
        ) {
            ConversationContextPopover(
                context   : context,
                lastTurn  : lastTurn,
                waitReason: waitReason,
                compact   : {
                    isShowingDetail = false
                    compact()
                },
                startFresh: {
                    isShowingDetail   = false
                    isConfirmingFresh = true
                }
            )
        }
        .confirmationDialog(
            "Start a Fresh Context?",
            isPresented    : $isConfirmingFresh,
            titleVisibility: .visible
        ) {
            Button(
                "Start Fresh Context",
                role: .destructive
            ) {
                startFresh()
            }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text("\(worker) forgets everything before now. The chat stays.")
        }
    }
}
