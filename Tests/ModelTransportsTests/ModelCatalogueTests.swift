//
//  ModelCatalogueTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

@Suite("A provider's model catalogue")
struct ModelCatalogueTests {

    /// The shape `codex debug models` prints, cut to the fields the catalogue reads.
    static let codexOutput = Data("""
    {"models": [
      {"slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list", "priority": 7,
       "default_reasoning_level": "xhigh",
       "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}]},
      {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide", "priority": 3,
       "supported_reasoning_levels": [{"effort": "low"}]},
      {"slug": "gpt-6-sol", "display_name": "GPT-6-Sol", "visibility": "list", "priority": 0,
       "default_reasoning_level": "medium",
       "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"},
                                      {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}, {"effort": "turbo"}]}
    ]}
    """.utf8)

    @Test("Codex's listed models come in priority order with their own levels, hidden ones and unknown levels left out")
    func codexCatalogueReadsTheCLI() throws {
        let models = try ProviderCatalog.codexCatalogue(from: Self.codexOutput)

        #expect(models.map(\.id) == ["gpt-6-sol", "gpt-5.5"])
        #expect(models[0].title == "GPT-6-Sol")
        #expect(models[0].efforts == [.low, .medium, .high, .xhigh, .max, .ultra])
        #expect(models[0].defaultEffort == .medium)
        #expect(models[1].efforts == [.low, .medium, .high, .xhigh])
        #expect(models[1].defaultEffort == .xhigh)
    }

    @Test("Output that is not a catalogue is an error, not an empty list")
    func codexCatalogueRefusesNoise() {
        #expect(throws: (any Error).self) { try ProviderCatalog.codexCatalogue(from: Data("login required".utf8)) }
    }

    @Test("Ultra is Codex's alone")
    func ultraIsOfferedOnlyByCodex() {
        #expect(ModelSelection.supportedEfforts(provider: .codex, model: "gpt-6-sol").contains(.ultra))
        for provider in [ModelProvider.claudeCode, .anthropic, .gemini, .ollama] {
            #expect(!ModelSelection.supportedEfforts(provider: provider, model: "any").contains(.ultra))
        }
    }
}
