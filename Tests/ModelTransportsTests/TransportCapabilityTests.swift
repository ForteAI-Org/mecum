//
//  TransportCapabilityTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

private let key = "sk-test-0123456789-never-in-an-error"

@Suite("What a transport says it cannot do")
struct TransportCapabilityTests {

    @Test("a CLI provider declares no conversational turn and refuses to fake one",
          arguments: [ModelProvider.codex, .claudeCode])
    func aCLIProviderRefusesTheTurnItCannotCarry(provider: ModelProvider) throws {
        let transport = ModelSelection(provider: provider, model: "any-model").transport()
        guard case .unsupported(let reason) = transport.streaming else {
            Issue.record("\(provider.title) claims a conversational turn it has no path for")
            return
        }
        #expect(!reason.isEmpty)
        #expect(throws: ModelTransportError.streamingUnsupported(reason)) {
            _ = try transport.converse([TurnMessage(role: .user, text: "ciao")], timeout: 5)
        }
    }

    @Test("an HTTP provider declares the stream it really has",
          arguments: [ModelProvider.anthropic, .gemini, .ollama])
    func anHTTPProviderDeclaresIncrementalStreaming(provider: ModelProvider) {
        let transport = ModelSelection(provider: provider, model: "any-model").transport()
        #expect(transport.streaming == .incremental)
    }

    @Test("a transport without a tool turn refuses tools and claims nothing",
          arguments: [ModelProvider.codex, .claudeCode])
    func aTransportWithoutAToolTurnRefusesTools(provider: ModelProvider) async throws {
        let transport = ModelSelection(provider: provider, model: "any-model").transport()
        let tool = ToolDefinition(name: "status", description: "Reads the status.", parameters: Data("{}".utf8))
        #expect(throws: ModelTransportError.toolsUnsupported) {
            _ = try transport.converse([TurnMessage(role: .user, text: "ciao")], tools: [tool], timeout: 5)
        }
        #expect(try await transport.capabilities() == ModelCapabilities())
    }

    @Test func withoutToolsTheToolTurnIsTheTextTurn() {
        let codex = ModelSelection(provider: .codex, model: "gpt-5.6-luna").transport()
        guard case .unsupported(let reason) = codex.streaming else {
            Issue.record("Codex claims a conversational turn it has no path for")
            return
        }
        #expect(throws: ModelTransportError.streamingUnsupported(reason)) {
            _ = try codex.converse([TurnMessage(role: .user, text: "ciao")], tools: [], timeout: 5)
        }
    }

    @Test func aTransportWithoutItsKeyRefusesBeforeAnyRequest() async throws {
        let anthropic = ModelSelection(provider: .anthropic, model: "claude-opus-5").transport()
        #expect(throws: ProviderError.self) {
            _ = try anthropic.converse([TurnMessage(role: .user, text: "ciao")], timeout: 5)
        }
        await #expect(throws: ProviderError.self) {
            _ = try await anthropic.complete(prompt: "ciao", schema: Data("{}".utf8), timeout: 5)
        }
        #expect(ProviderError.missingAPIKey(.anthropic).localizedDescription.contains("No API key"))
    }

    @Test func aRefusedRequestSaysWhatTheProviderSaid() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        let sentence = HTTPTransport.failure(status: 401, body: body).localizedDescription
        #expect(sentence.contains("401"))
        #expect(sentence.contains("invalid x-api-key"))
        #expect(!sentence.contains(key))
    }

    @Test func aRefusalThatIsNotJSONIsQuotedAsTheTextItWas() {
        let sentence = HTTPTransport.failure(status: 502, body: Data("upstream connect error".utf8))
            .localizedDescription
        #expect(sentence.contains("502"))
        #expect(sentence.contains("upstream connect error"))
    }

    @Test func theKeyTravelsInAHeaderAndNeverInTheURL() throws {
        let url = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let request = try HTTPTransport.request(url, headers: ["x-api-key": key],
                                                body: ["model": "claude-opus-5"], timeout: 30)
        #expect(request.url?.absoluteString == url.absoluteString)
        #expect(request.allHTTPHeaderFields?["x-api-key"] == key)
        #expect(request.httpMethod == "POST")
    }
}
