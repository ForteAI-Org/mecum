//
//  OllamaGenerationSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// OllamaGenerationSection is how the local model generates: the sampling
/// knobs, the context and output budgets, and how long a request may take.
/// Thinking is not here: it follows the effort chosen in the composer.
struct OllamaGenerationSection: View {

    @Bindable
    var store: ModelSettingsStore

    var body: some View {
        Section {
            slider(
                "Temperature",
                value    : $store.ollamaTemperature,
                in       : 0...1.5,
                step     : 0.05,
                fractions: 2
            )
            slider(
                "Top P",
                value    : $store.ollamaTopP,
                in       : 0.1...1,
                step     : 0.05,
                fractions: 2
            )
            number(
                "Top K",
                value: $store.ollamaTopK
            )
            slider(
                "Presence penalty",
                value    : $store.ollamaPresencePenalty,
                in       : 0...2,
                step     : 0.1,
                fractions: 1
            )
            number(
                "Context tokens",
                value: $store.ollamaContextTokens
            )
            number(
                "Max output tokens",
                value: $store.ollamaMaxOutputTokens
            )
            LabeledContent("Request timeout") {
                TextField(
                    "",
                    value : $store.ollamaTimeoutSeconds,
                    format: .number
                )
                .frame(width: 70)
                Text("s")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Generation")
        } footer: {
            Text("Thinking tokens count against the output budget, so keep it at 8k or more with thinking on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(
        _ title  : String,
        value    : Binding<Double>,
        in range : ClosedRange<Double>,
        step     : Double,
        fractions: Int
    ) -> some View {
        LabeledContent(title) {
            Slider(
                value: value,
                in   : range,
                step : step
            )
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(fractions))))
                .monospacedDigit()
                .frame(width: 40)
        }
    }

    private func number(
        _ title: String,
        value  : Binding<Int>
    ) -> some View {
        LabeledContent(title) {
            TextField(
                "",
                value : value,
                format: .number
            )
            .frame(width: 90)
        }
    }
}
