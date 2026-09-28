//
//  TokenCounterButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports
import SwiftUI

/// TokenCounterButton is the toolbar's count of the new tokens the selected
/// worker's turns used over its life, compact, beside the screen and inspector
/// toggles. It opens a popover of where they went (`TokenCounterPopover`).
/// The toolbar shows it only once the worker has recorded a turn.
struct TokenCounterButton: View {

    let worker: WorkerSnapshot
    let usage : WorkerUsage

    /// Whether the popover is open: `TeamModel.showsUsage`, which `/usage` sets too.
    @Binding var isShowingDetail: Bool

    var body: some View {
        let wording = UsageWording()
        let count   = UsageWording.newTokens(usage.lifetime)

        Button { isShowingDetail.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid")

                Text(wording.compact(count))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
            // The digits roll only inside an animation, and nothing that changes the count runs one.
            .animation(
                .default,
                value: count
            )
        }
        .help("Tokens used")
        .accessibilityLabel("Tokens used, \(wording.spoken(count))")
        .popover(
            isPresented: $isShowingDetail,
            arrowEdge  : .bottom
        ) {
            TokenCounterPopover(
                workerName: worker.name,
                provider  : worker.configuration?.provider,
                usage     : usage
            )
        }
    }
}
