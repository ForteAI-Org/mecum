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

    @State private var isShowingDetail = false

    var body: some View {
        let wording = UsageWording()
        let count   = UsageWording.newTokens(usage.lifetime)

        Button { isShowingDetail.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar")

                Text(wording.compact(count))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
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
