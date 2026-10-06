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

    /// What `claude -p --input-format stream-json` prints for `initialize`, cut to the fields
    /// the catalogue reads, after a line of another kind.
    static let claudeOutput = Data("""
    {"type":"system","subtype":"hook_started"}
    {"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[ \
      {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}, \
      {"value":"claude-opus-5","resolvedModel":"claude-opus-5","displayName":"Opus 5","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"claude-opus-5-20260601","resolvedModel":"claude-opus-5-20260601","displayName":"Opus 5 again"}, \
      {"value":"claude-opus-4-6","resolvedModel":"claude-opus-4-6","displayName":"Opus 4.6","supportedEffortLevels":["low","medium","high","max","turbo"]} \
    ]}}}
    """.utf8)

    @Test("Claude Code's models come in its order by resolved id, once each, with their own levels")
    func claudeCatalogueReadsTheCLI() throws {
        let models = try ProviderCatalog.claudeCatalogue(from: Self.claudeOutput)

        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5", "claude-opus-5", "claude-opus-4-6"])
        #expect(models.map(\.title) == ["Opus 5.5", "Haiku 4.5", "Opus 5", "Opus 4.6"])
        #expect(models[0].efforts == [.low, .medium, .high, .xhigh, .max])
        #expect(models[1].efforts.isEmpty, "Haiku takes no effort")
        #expect(models[3].efforts == [.low, .medium, .high, .max], "an unknown level is left out")
    }

    @Test("A Claude id loses only a trailing snapshot date")
    func claudeIDDropsTheSnapshotDate() {
        #expect(ProviderCatalog.claudeID("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ProviderCatalog.claudeID("claude-opus-5-5") == "claude-opus-5-5")
        #expect(ProviderCatalog.claudeID("claude-sonnet-4-20250514") == "claude-sonnet-4")
        #expect(ProviderCatalog.claudeID("claude-20251001-x") == "claude-20251001-x")
    }

    @Test("A model known only by id reads by its family and version, an id of another shape as itself")
    func displayNameReadsTheID() {
        #expect(ModelInfo.displayName(for: "claude-haiku-4-5") == "Haiku 4.5")
        #expect(ModelInfo.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelInfo.displayName(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(ModelInfo.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(ModelInfo.displayName(for: "claude-fable-5-1") == "Fable 5.1")
        #expect(ModelInfo.displayName(for: "gpt-5.4-mini") == "GPT-5.4-Mini")
        #expect(ModelInfo.displayName(for: "gpt-6-sol") == "GPT-6-Sol")
        #expect(ModelInfo.displayName(for: "gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(ModelInfo.displayName(for: "qwen3:8b") == "qwen3:8b")
        #expect(ModelInfo.displayName(for: "claude-3-5-sonnet") == "claude-3-5-sonnet")
        #expect(ModelInfo(id: "claude-opus-5-5", efforts: []).title == "Opus 5.5", "a catalogue without names uses it")
    }

    @Test("Claude Code's output without an answer to initialize is an error, not an empty list")
    func claudeCatalogueRefusesNoise() {
        #expect(throws: (any Error).self) {
            try ProviderCatalog.claudeCatalogue(from: Data(#"{"type":"result","is_error":true}"#.utf8))
        }
    }

    @Test("Ultra is Codex's alone")
    func ultraIsOfferedOnlyByCodex() {
        #expect(ModelSelection.supportedEfforts(provider: .codex, model: "gpt-6-sol").contains(.ultra))
        for provider in [ModelProvider.claudeCode, .anthropic, .gemini, .ollama] {
            #expect(!ModelSelection.supportedEfforts(provider: provider, model: "any").contains(.ultra))
        }
    }
}
