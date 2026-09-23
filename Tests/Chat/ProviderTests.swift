import ChatCore
import CLIProviders
import Foundation
import Testing

@Suite("Chat provider boundaries")
struct ProviderTests {
    private func turn(_ provider: ChatProvider, session: String? = nil, prompt: String? = nil) -> ProviderTurn {
        ProviderTurn(provider: provider, model: "selected-model", sessionID: session,
                     prompt: prompt ?? "literal \"quotes\"; $(touch /tmp/never-run)\nsecond line",
                     instructions: "Only Mecum.\nNo shell.",
                     bridgeExecutable: "/a path/mecum", connectionFile: "/private/connection.json",
                     workingDirectory: "/tmp")
    }

    @Test
    func claudeUsesExactResumeAndOnlyMecumTools() throws {
        let value = try ProviderInvocation(turn(.claude, session: "session-123"))
        #expect(value.arguments.contains("--strict-mcp-config"))
        #expect(value.arguments.contains("mcp__mecum__*"))
        let resume = try #require(value.arguments.firstIndex(of: "--resume"))
        #expect(value.arguments[resume + 1] == "session-123")
        let config = try #require(value.arguments.firstIndex(of: "--mcp-config"))
        let object = try JSONSerialization.jsonObject(with: Data(value.arguments[config + 1].utf8)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        #expect(servers?.keys.map { $0 } == ["mecum"])
        #expect(!value.arguments.contains(value.standardInput))
        #expect(!value.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test
    func codexResumeKeepsConfigurationAndPromptOnStdin() throws {
        let value = try ProviderInvocation(turn(.codex, session: "thread-123"))
        #expect(value.arguments.suffix(3) == ["resume", "thread-123", "-"])
        #expect(value.arguments.contains("--ignore-user-config"))
        #expect(value.arguments.contains("read-only"))
        #expect(value.arguments.contains("features.shell_tool=false"))
        #expect(value.arguments.contains("selected-model"))
        #expect(value.arguments.contains(where: { $0.contains("command=\"/a path/mecum\"") }))
        #expect(value.standardInput.contains("$(touch"))
        #expect(!value.arguments.contains(value.standardInput))
    }

    @Test
    func effortReachesEachProviderInItsOwnFlag() throws {
        func turn(_ provider: ChatProvider, model: String?, effort: String?) -> ProviderTurn {
            ProviderTurn(provider: provider, model: model, sessionID: nil, prompt: "p", instructions: "i",
                         bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/tmp", effort: effort)
        }
        let claude = try ProviderInvocation(turn(.claude, model: "claude-opus-5", effort: "high")).arguments
        let flag = try #require(claude.firstIndex(of: "--effort"))
        #expect(claude[flag + 1] == "high")
        #expect(!(try ProviderInvocation(turn(.claude, model: "claude-opus-5", effort: nil)).arguments
                  .contains("--effort")))
        #expect(!(try ProviderInvocation(turn(.claude, model: "claude-haiku-4-5", effort: "high")).arguments
                  .contains("--effort")))
        let codex = try ProviderInvocation(turn(.codex, model: "gpt-5.6-luna", effort: "xhigh")).arguments
        #expect(codex.contains("model_reasoning_effort=\"xhigh\""))
        #expect(codex.last == "-")
        #expect(!(try ProviderInvocation(turn(.codex, model: "gpt-5.6-luna", effort: nil)).arguments
                  .contains(where: { $0.hasPrefix("model_reasoning_effort") })))
    }

    @Test
    func resumeIsPassedOnlyWithASession() throws {
        #expect(!(try ProviderInvocation(turn(.claude)).arguments.contains("--resume")))
        #expect(!(try ProviderInvocation(turn(.codex)).arguments.contains("resume")))
        let codex = try ProviderInvocation(ProviderTurn(
            provider: .codex, model: nil, sessionID: "thread-9", prompt: "p", instructions: "i",
            bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/tmp", effort: "low"
        )).arguments
        #expect(codex.suffix(3) == ["resume", "thread-9", "-"])
        #expect(codex.contains("model_reasoning_effort=\"low\""))
    }

    @Test
    func claudeDecoderDoesNotDuplicateResult() throws {
        var decoder = ProviderEventDecoder(provider: .claude)
        let assistant = try decoder.decode(Data(#"{"type":"assistant","session_id":"abc","message":{"content":[{"type":"text","text":"Hello"}]}}"#.utf8))
        #expect(assistant == [.session("abc"), .assistant("Hello")])
        let result = try decoder.decode(Data(#"{"type":"result","session_id":"abc","is_error":false,"result":"Hello"}"#.utf8))
        #expect(result == [.session("abc"), .completed])
    }

    @Test
    func failuresAreNotSuccessfulCompletion() throws {
        var claude = ProviderEventDecoder(provider: .claude)
        #expect(try claude.decode(Data(#"{"type":"result","is_error":true,"errors":["not signed in"]}"#.utf8))
                == [.failure("not signed in")])
        var codex = ProviderEventDecoder(provider: .codex)
        #expect(try codex.decode(Data(#"{"type":"turn.failed","error":{"message":"limit reached"}}"#.utf8))
                == [.failure("limit reached")])
        #expect(try codex.decode(Data(#"{"type":"thread.started","thread_id":"xyz"}"#.utf8)) == [.session("xyz")])
        #expect(try codex.decode(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}"#.utf8))
                == [.assistant("Done")])
    }

    @Test
    func processDrainsBothPipesAndRequiresCompletion() async throws {
        let fixture = try script("""
        /usr/bin/python3 - <<'PY'
        import json,sys
        sys.stderr.write('diagnostic ' * 20000)
        print(json.dumps({"type":"thread.started","thread_id":"fixture"}))
        print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}))
        print(json.dumps({"type":"turn.completed"}))
        PY
        """)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let provider = CLIProvider()
        var events: [ProviderEvent] = []
        try await provider.run(turn(.codex), executable: fixture) { events.append($0) }
        #expect(events == [.session("fixture"), .assistant("Hello"), .completed])
    }

    @Test
    func emptySuccessfulExitIsNotACompletedTurn() async throws {
        let fixture = try script("cat >/dev/null\nexit 0")
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            try await CLIProvider().run(turn(.codex), executable: fixture) { _ in }
            Issue.record("Empty output must fail even with exit code zero.")
        } catch { #expect(error.localizedDescription.contains("without a successful turn")) }
    }

    @Test
    func providerClosingStdinCannotTerminateTheHost() async throws {
        let fixture = try script("exec </dev/null\nexit 7")
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            try await CLIProvider().run(turn(.codex, prompt: String(repeating: "x", count: 1_000_000)),
                                        executable: fixture) { _ in }
            Issue.record("Provider failure was hidden.")
        } catch { #expect(!(error is CancellationError)) }
    }

    @Test
    func cancelledProcessIsReaped() async throws {
        let fixture = try script("cat >/dev/null\nexec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let provider = CLIProvider()
        let task = Task { try await provider.run(turn(.codex), executable: fixture) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        provider.cancel()
        do {
            try await task.value
            Issue.record("Cancellation must not return success.")
        } catch { #expect(error is CancellationError) }
        await provider.waitUntilStopped()
    }

    private func script(_ body: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-provider-test-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
}
