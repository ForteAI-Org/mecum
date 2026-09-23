//
//  ProviderTab.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

struct ProviderTab: View {

    @Bindable
    var store: ModelSettingsStore

    let provider: ModelProvider

    var body: some View {
        Form {
            Section {
                StatusRow(
                    store   : store,
                    provider: provider
                )
                Text(provider.accessHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                switch provider {
                    case .anthropic:
                        KeyField(
                            title     : "Anthropic API key",
                            text      : $store.anthropicAPIKey,
                            consoleURL: provider.consoleURL
                        )
                    case .gemini:
                        KeyField(
                            title     : "Gemini API key",
                            text      : $store.geminiAPIKey,
                            consoleURL: provider.consoleURL
                        )
                    case .ollama:
                        TextField(
                            "Server",
                            text  : $store.ollamaHost,
                            prompt: Text("http://127.0.0.1:11434")
                        )
                    case .codex, .claudeCode:
                        Button("Re-check sign-in") { store.refresh([provider]) }
                }
            } header: {
                Text("Access")
            }

            ModelListSection(
                store   : store,
                provider: provider
            )

            if provider == .ollama {
                Section {
                    LabeledContent("Temperature") {
                        Slider(
                            value: $store.ollamaTemperature,
                            in   : 0...1.5,
                            step : 0.05
                        )
                        Text(store.ollamaTemperature.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    LabeledContent("Top P") {
                        Slider(
                            value: $store.ollamaTopP,
                            in   : 0.1...1,
                            step : 0.05
                        )
                        Text(store.ollamaTopP.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    LabeledContent("Top K") {
                        TextField(
                            "",
                            value : $store.ollamaTopK,
                            format: .number
                        )
                        .frame(width: 90)
                    }
                    LabeledContent("Presence penalty") {
                        Slider(
                            value: $store.ollamaPresencePenalty,
                            in   : 0...2,
                            step : 0.1
                        )
                        Text(store.ollamaPresencePenalty.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    LabeledContent("Context tokens") {
                        TextField(
                            "",
                            value : $store.ollamaContextTokens,
                            format: .number
                        )
                        .frame(width: 90)
                    }
                    LabeledContent("Max output tokens") {
                        TextField(
                            "",
                            value : $store.ollamaMaxOutputTokens,
                            format: .number
                        )
                        .frame(width: 90)
                    }
                    LabeledContent("Request timeout (s)") {
                        TextField(
                            "",
                            value : $store.ollamaTimeoutSeconds,
                            format: .number
                        )
                        .frame(width: 90)
                    }
                    Text("Thinking tokens count against the output budget: keep it at 8k or more with thinking on. Thinking follows the effort in the chat: “No thinking” runs with it off, “Thinking” with it on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text("Generation")
                        Spacer()
                        Menu("Qwen recommended") {
                            Button("For thinking (0.6 · 0.95 · 20 · 0 · 8k out)") { store.applyQwenRecommendation(thinking: true) }
                            Button("For no thinking (0.7 · 0.8 · 20 · 1.5 · 2k out)") { store.applyQwenRecommendation(thinking: false) }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
