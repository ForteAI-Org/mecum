//
//  WorkerModelChoiceTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

@Suite("Choosing a worker's model and effort")
struct WorkerModelChoiceTests {

    /// Every provider with every model it starts from, and a local one for Ollama.
    private static let pairs: [(ModelProvider, String)] =
        ModelProvider.allCases.flatMap { provider in provider.defaultModels.map { (provider, $0) } }
            + [(.ollama, "qwen3:8b")]

    @Test("the rail's positions are the supported efforts, exactly", arguments: pairs)
    func positionsAreTheSupportedEfforts(provider: ModelProvider, model: String) {
        let scale = EffortScale(provider: provider, model: model)
        #expect(scale.positions == ModelSelection.supportedEfforts(provider: provider, model: model))
    }

    @Test func thePositionsAreNotAlwaysFourAndAreNoneWithoutAParameter() {
        #expect(EffortScale(provider: .gemini, model: "gemini-3-pro-preview").positions == [.low, .medium, .high])
        // Codex without its catalogue passes every level; the catalogue narrows it per model.
        #expect(EffortScale(provider: .codex, model: "gpt-5.6-luna").positions == ReasoningEffort.allCases)
        let listed = ModelInfo(id: "gpt-5.5", efforts: [.low, .medium, .high, .xhigh])
        #expect(EffortScale(provider: .codex, model: listed).positions.count == 4)

        let ollama = EffortScale(provider: .ollama, model: "qwen3:8b")
        #expect(ollama.positions == [.low, .high])
        #expect(ollama.isSwitch)

        let haiku = EffortScale(provider: .anthropic, model: "claude-haiku-4-5")
        #expect(haiku.isEmpty)
        #expect(haiku.effort(atFraction: 0.5) == nil)
        #expect(haiku.effort(from: .medium, steps: 1) == nil)
    }

    /// A click and a drag land through the fraction, an arrow key through a
    /// step, and all of them only on a detent.
    @Test func clickDragAndArrowsLandOnTheSameDetents() {
        let scale = EffortScale(provider: .gemini, model: "gemini-3-pro-preview")
        #expect(scale.effort(atFraction: 0.1) == .low)
        #expect(scale.effort(atFraction: 0.45) == .medium)
        #expect(scale.effort(atFraction: 1.7) == .high)
        #expect(scale.effort(atFraction: -3) == .low)
        #expect(scale.effort(from: .low, steps: 1) == .medium)
        #expect(scale.effort(from: .high, steps: 1) == .high)
        #expect(scale.effort(from: .low, steps: -1) == .low)
        for effort in scale.positions {
            #expect(scale.effort(atFraction: scale.fraction(of: effort)) == effort)
        }
    }

    @Test func noLevelIsDescribedAsAQualityScore() {
        for pair in Self.pairs {
            let scale = EffortScale(provider: pair.0, model: pair.1)
            for effort in scale.positions {
                let summary = scale.summary(of: effort)
                #expect(!summary.contains("%"))
                #expect(!summary.localizedCaseInsensitiveContains("intelligen"))
            }
        }
    }

    @Test("the command lines answer as agents and every model provider through Mecum's loop",
          arguments: ModelProvider.allCases)
    func whoAnswersIsOneAuthority(provider: ModelProvider) {
        let answer = WorkerAnswer(provider: provider)
        switch provider {
        case .codex, .claudeCode:           #expect(answer == .agent)
        case .anthropic, .gemini, .ollama:  #expect(answer == .modelLoop)
        }
    }

    @Test func movingBetweenLocalAndCloudOrSubscriptionAndKeyAsksFirst() {
        let ollama    = ProviderConnection(provider: .ollama)
        let anthropic = ProviderConnection(provider: .anthropic)
        let gemini    = ProviderConnection(provider: .gemini)
        let codex     = ProviderConnection(provider: .codex)
        let claude    = ProviderConnection(provider: .claudeCode)

        #expect(anthropic.consentNeeded(movingFrom: ollama)?.contains("api.anthropic.com") == true)
        #expect(ollama.consentNeeded(movingFrom: anthropic) != nil)
        #expect(anthropic.consentNeeded(movingFrom: codex) != nil)
        #expect(codex.consentNeeded(movingFrom: anthropic) != nil)
        #expect(codex.consentNeeded(movingFrom: ollama) != nil)

        #expect(gemini.consentNeeded(movingFrom: anthropic) == nil)
        #expect(claude.consentNeeded(movingFrom: codex) == nil)
        #expect(ollama.consentNeeded(movingFrom: ollama) == nil)
    }
}
