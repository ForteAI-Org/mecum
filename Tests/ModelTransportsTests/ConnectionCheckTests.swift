//
//  ConnectionCheckTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

/// Recognisable, and never a real key.
private let fakeKey = "sk-ant-FAKE-7f3a9c-must-never-leave-the-keychain"

private func body(_ json: String) -> Data { Data(json.utf8) }

/// Provider, HTTP status, body, the model asked about, and the state's title.
private typealias Answer = (ModelProvider, Int, String, String?, String)

@Suite("What a connection check found")
struct ConnectionCheckTests {

    /// Each case is a body the provider really sends for that refusal, sent
    /// to `classify` directly: no request is made.
    @Test("each state is read from the provider's own answer", arguments: answers)
    func classifiesTheProvidersAnswer(
        provider: ModelProvider,
        status  : Int,
        answer  : String,
        model   : String?,
        title   : String
    ) {
        let state = ProviderCatalog.classify(
            provider  : provider,
            status    : status,
            body      : body(answer),
            model     : model,
            credential: fakeKey
        )
        #expect(state.title == title)
        if let model, title == "Model removed" { #expect(state == .modelRemoved(model: model)) }
    }

    private static let answers: [Answer] = [
        (.anthropic, 401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
         nil, "Credential refused"),
        (.anthropic, 429, #"{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}"#,
         nil, "Usage limit"),
        (.anthropic, 402, #"{"type":"error","error":{"type":"billing_error","message":"Your credit balance is too low"}}"#,
         nil, "Usage limit"),
        (.anthropic, 404, #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-opus-3"}}"#,
         "claude-opus-3", "Model removed"),
        (.anthropic, 403, #"{"type":"error","error":{"type":"permission_error","message":"Your API key does not have permission to use the specified resource."}}"#,
         nil, "Refused"),
        (.gemini, 400, #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}"#,
         nil, "Credential refused"),
        (.gemini, 400, #"{"error":{"code":400,"message":"Invalid JSON payload received.","status":"INVALID_ARGUMENT"}}"#,
         nil, "Refused"),
        (.gemini, 429, #"{"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED"}}"#,
         nil, "Usage limit"),
        (.gemini, 404, #"{"error":{"code":404,"message":"models/gemini-1.0-pro is not found","status":"NOT_FOUND"}}"#,
         "gemini-1.0-pro", "Model removed"),
        (.ollama, 200, #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b"},{"name":"llama3.2:latest"}]}"#,
         "mistral:7b", "Model removed"),
        (.ollama, 200, #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b"},{"name":"llama3.2:latest"}]}"#,
         "llama3.2", "Ready"),
        (.ollama, 500, #"{"error":"model runner has unexpectedly stopped"}"#,
         nil, "Refused"),
    ]

    @Test func nothingAnsweringIsUnreachableAndNamesWhere() {
        let state = ProviderCatalog.classify(URLError(.cannotConnectToHost), destination: "http://127.0.0.1:11434")
        guard case .unreachable(let destination, _) = state else {
            Issue.record("a refused connection read as \(state.title)")
            return
        }
        #expect(destination == "http://127.0.0.1:11434")
        #expect(state.message.contains("http://127.0.0.1:11434"))
    }

    @Test func theCommandLinesAreReadFromTheirExitAndTheirStatus() {
        let signedIn = body("Logged in using ChatGPT\n")
        #expect(ProviderCatalog.classifyCodexLogin(exitStatus: 0, output: signedIn) == .ready)
        #expect(ProviderCatalog.classifyCodexLogin(exitStatus: 1, output: body("Not logged in\n")) == .credentialMissing)

        // An API key sign-in prints part of the key; it is refused and never quoted.
        let keyed = ProviderCatalog.classifyCodexLogin(exitStatus: 0, output: body("Logged in using an API key - \(fakeKey)\n"))
        #expect(keyed.title == "Refused")
        #expect(!keyed.message.contains(fakeKey))

        #expect(ProviderCatalog.classifyClaudeAuth(exitStatus: 0, output: body(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)) == .ready)
        #expect(ProviderCatalog.classifyClaudeAuth(exitStatus: 1, output: body(#"{"loggedIn":false}"#)) == .credentialMissing)
        #expect(ProviderCatalog.classifyClaudeAuth(exitStatus: 2, output: body("segmentation fault")).title == "Refused")
    }

    /// `status` is the typed check read as a sentence. These paths make no
    /// request: an absent key is answered before one, and port 1 on the
    /// loopback refuses at once.
    @Test("status says what the typed check says", arguments: [ModelProvider.anthropic, .gemini, .ollama])
    func statusAgreesWithTheCheck(provider: ModelProvider) async {
        let settings = ProviderSettings(ollamaHost: "http://127.0.0.1:1")
        let state    = await ProviderCatalog.check(provider, settings: settings)
        let sentence = await ProviderCatalog.status(provider, settings: settings)
        #expect(!state.isReady)
        #expect(sentence == state.message)
        if provider != .ollama { #expect(state == .credentialMissing) }
    }

    @Test func everyStateReadsDifferently() {
        let states: [ConnectionState] = [
            .ready, .credentialMissing, .credentialRejected(detail: "d"), .unreachable(destination: "h", detail: "d"),
            .usageLimited(detail: "d"), .modelRemoved(model: "m"), .refused(detail: "d"),
        ]
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(Set(states.map(\.message)).count == states.count)
    }

    @Test func aKeyTheProviderQuotesBackNeverReachesAMessage() {
        let echoing = body(#"{"error":{"message":"Incorrect API key provided: \#(fakeKey). Check it."}}"#)
        for provider in [ModelProvider.anthropic, .gemini, .ollama] {
            for status in [400, 401, 402, 403, 404, 429, 500] {
                let state = ProviderCatalog.classify(
                    provider: provider, status: status, body: echoing, model: "m", credential: fakeKey
                )
                #expect(!state.message.contains(fakeKey))
                #expect(!state.title.contains(fakeKey))
                #expect(!String(describing: state).contains(fakeKey))
            }
        }

        // Nothing else this ticket writes carries the key either.
        let settings = ProviderSettings(anthropicAPIKey: fakeKey, geminiAPIKey: fakeKey)
        for provider in ModelProvider.allCases {
            let connection = ProviderConnection(provider: provider, settings: settings)
            #expect(!String(describing: connection).contains(fakeKey))
            for other in ModelProvider.allCases {
                let consent = connection.consentNeeded(movingFrom: ProviderConnection(provider: other, settings: settings))
                #expect(!(consent ?? "").contains(fakeKey))
            }
        }
    }

    @Test func aRemovedModelHasAReplacementProposedAndNeverItself() {
        #expect(ProviderCatalog.replacement(for: "claude-opus-4-1", provider: .anthropic,
                                            catalogue: ["claude-haiku-4-5", "claude-opus-4-1", "claude-sonnet-5"])
                == "claude-sonnet-5")
        #expect(ProviderCatalog.replacement(for: "mistral:7b", provider: .ollama, catalogue: ["qwen3:8b"]) == "qwen3:8b")
        #expect(ProviderCatalog.replacement(for: "qwen3:8b", provider: .ollama, catalogue: ["qwen3:8b"]) == nil)
    }
}
