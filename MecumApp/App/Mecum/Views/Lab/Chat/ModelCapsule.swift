//
//  ModelCapsule.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

struct ModelCapsule: View {

    let selection: ModelSelection
    let action   : () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(selection.model.isEmpty ? "Choose a model" : selection.model)
                    .lineLimit(1)
                // Sized by the widest level this model has, so changing the
                // effort never resizes the capsule or moves the popover.
                ZStack {
                    ForEach(ModelSelection.supportedEfforts(
                        provider: selection.provider,
                        model   : selection.model
                    )) {
                        Text($0.title(for: selection.provider))
                            .fontWeight(.semibold)
                            .hidden()
                    }
                    // A model with no effort parameter shows no level at all.
                    if !ModelSelection.supportedEfforts(
                        provider: selection.provider,
                        model   : selection.model
                    ).isEmpty {
                        Text(selection.effort.title(for: selection.provider))
                            .fontWeight(.semibold)
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.callout)
            .padding(
                .horizontal,
                10
            )
            .padding(
                .vertical,
                5
            )
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(EffortTint.color(
            for     : selection.effort,
            provider: selection.provider,
            model   : selection.model
        ))
        .help("Model and effort")
    }
}
