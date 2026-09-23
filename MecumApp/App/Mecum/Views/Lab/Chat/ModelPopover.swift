//
//  ModelPopover.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// Provider, model and a stepped effort slider.
struct ModelPopover: View {

    @Bindable
    var model: AppModel

    private var efforts: [ReasoningEffort] {
        ModelSelection.supportedEfforts(
            provider: model.selection.provider,
            model   : model.selection.model
        )
    }

    private var effortIndex: Binding<Double> {
        Binding(
            get: { Double(efforts.firstIndex(of: model.selection.effort) ?? 0) },
            set: {
                model.selection.effort = efforts[min(
                    efforts.count - 1,
                    max(
                        0,
                        Int($0.rounded())
                    )
                )]
            }
        )
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 14
        ) {
            Picker(
                "Provider",
                selection: $model.selection.provider
            ) {
                ForEach(model.settings.availableProviders) {
                    Text($0.title)
                        .tag($0)
                }
                if !model.settings.isAvailable(model.selection.provider) {
                    Text(model.selection.provider.title)
                        .tag(model.selection.provider)
                }
            }
            .onChange(of: model.selection.provider) { _, provider in
                let models = model.settings.models(for: provider)
                if !models.contains(model.selection.model) { model.selection.model = models.first ?? "" }
                clampEffort()
            }

            let models = model.settings.models(for: model.selection.provider)
            if models.isEmpty {
                SettingsLink {
                    Label(
                        "Add models in Settings",
                        systemImage: "gearshape"
                    )
                }
            } else {
                Picker(
                    "Model",
                    selection: $model.selection.model
                ) {
                    ForEach(
                        models,
                        id: \.self
                    ) {
                        Text($0)
                            .tag($0)
                    }
                    if !models.contains(model.selection.model) {
                        Text(model.selection.model)
                            .tag(model.selection.model)
                    }
                }
                .onChange(of: model.selection.model) { clampEffort() }
            }

            VStack(
                alignment: .leading,
                spacing  : 4
            ) {
                HStack {
                    Text("Effort")
                    Spacer()
                    Text(model.selection.effort.title(for: model.selection.provider))
                        .fontWeight(.semibold)
                        .foregroundStyle(EffortTint.color(
                            for     : model.selection.effort,
                            provider: model.selection.provider,
                            model   : model.selection.model
                        ))
                }
                Slider(
                    value: effortIndex,
                    in   : 0...Double(max(
                        1,
                        efforts.count - 1
                    )),
                    step : 1
                )
                .tint(EffortTint.color(
                    for     : model.selection.effort,
                    provider: model.selection.provider,
                    model   : model.selection.model
                ))
                .disabled(efforts.count < 2)
                HStack {
                    ForEach(efforts) { effort in
                        Text(effort.title(for: model.selection.provider))
                            .font(.caption2)
                            .foregroundStyle(effort == model.selection.effort ? .primary : .secondary)
                        if effort != efforts.last { Spacer() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func clampEffort() {
        let supported = efforts
        guard !supported.isEmpty, !supported.contains(model.selection.effort) else { return }
        // Medium when the provider has it; otherwise the highest level, which
        // for Ollama means thinking on.
        model.selection.effort = supported.contains(.medium) ? .medium : (supported.last ?? .low)
    }
}
