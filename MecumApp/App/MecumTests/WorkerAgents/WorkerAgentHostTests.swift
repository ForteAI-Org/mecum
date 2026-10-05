//
//  WorkerAgentHostTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AgentTurn
import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import ModelTransports
import Testing
@testable import Mecum

/// A worker's turn core in the app: the desktop that refuses, and the real command line through the
/// recorder and a store reopened as a relaunch would. The core's own rows (instructions, the turn as
/// the provider receives it, a resumed Codex session's reminder, the close with a child running) are
/// the package's `AgentTurnTests`.
@MainActor
@Suite("A worker's agent host")
struct WorkerAgentHostTests {

    @Test func theDesktopRefusesInASentenceAndNothingElseIsOpen() async throws {
        let tools = AutomationTools(session: DesktopUnavailableSession())
        var records: [String] = []
        tools.record = { records.append($0) }
        do {
            _ = try await tools.call("open_session", .object(["app": .string("Finder")]))
            Issue.record("A worker opened a desktop session.")
        } catch {
            #expect(String(describing: error) == DesktopUnavailableSession.refusal)
        }
        #expect(records.last?.hasPrefix("← open_session error: Computer access is unavailable") == true)
        let status = try await tools.call("status", .object([:]))
        #expect(status["structuredContent"]["session"] == .null)
    }

    /// The real command line, signed in, with the built `mecum` as its bridge,
    /// through the recorder and a store that is reopened as a relaunch would.
    /// No TCC grant and no window is needed: `windows` only lists them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MECUM_LIVE_AGENT"] == "1"),
          arguments: [
              ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low),
              ModelSelection(provider: .codex, model: "gpt-5.6-luna", effort: .low),
          ])
    func theRealAgentAnswersThroughTheToolsAndResumesItsSessionAfterARelaunch(
        _ selection: ModelSelection
    ) async throws {
        let bridge = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MECUM_TEST_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/mecum").path)
        let root = URL.temporaryDirectory.appending(path: "mecum-live-agent-\(UUID().uuidString)")
        defer { remove(root) }
        let directory = root.appending(path: "store", directoryHint: .isDirectory)
        let work      = root.appending(path: "work", directoryHint: .isDirectory)
        let role      = "You answer in one short sentence."
        let label     = selection.provider.rawValue

        var tools   : [String] = []
        var replies : [String] = []
        var sessions: [String] = []
        let receive: @MainActor (AgentTurnEvent) -> Void = { event in
            switch event {
            case .tool(let text):                    tools.append(text)
            case .provider(.assistant(let text)):    replies.append(text)
            case .provider(.session(let id)):        sessions.append(id)
            case .provider, .processStarted, .usage: break
            }
        }
        func turn(_ store: WorkspaceStore, _ host: AgentTurnHost, _ worker: UUID, _ conversation: UUID,
                  _ prompt: String) async throws -> (ending: WorkerTurnRecorder.Ending, resumed: String?) {
            tools = []; replies = []; sessions = []
            let message = try await store.appendMessage(to: conversation, text: prompt)
            var resumed: String?
            let recorder = WorkerTurnRecorder(store: store, workspaceID: UUID(), workerID: worker,
                                              conversationID: conversation, messageID: message.id) {}
            let ending = try await recorder.run { frozen, session, emit in
                resumed = session
                try await host.run(prompt: prompt, selection: frozen, sessionID: session, role: role) {
                    receive($0); emit($0)
                }
            }
            return (ending, resumed)
        }

        let worker      : UUID
        let conversation: UUID
        let first       : String
        do {
            let store = try WorkspaceStore.opening(in: directory)
            worker = try await store.createWorker(
                name: "Live", appearance: WorkerAppearance(seed: 1, generatorVersion: 3, palette: "dusk",
                                                           roundness: 0.5, wobble: 0.5, glow: 0.5)).id
            try await store.configure(worker: worker, selection: selection)
            conversation = try await store.createConversation(participants: [worker]).id
            let host = AgentTurnHost(workingDirectory: work, bridgeExecutable: bridge,
                                     session: { DesktopUnavailableSession() })

            let one = try await turn(store, host, worker, conversation, "Which applications have windows open "
                                     + "right now? Use the windows tool, then answer in one sentence.")
            print("live \(label) turn 1:", one.ending, "resumed:", one.resumed ?? "none")
            print("live \(label) turn 1 tools:", tools.map { String($0.prefix(160)) })
            print("live \(label) turn 1 replies:", replies)
            print("live \(label) turn 1 sessions:", Set(sessions))
            #expect(one.ending == .completed)
            #expect(one.resumed == nil)
            #expect(tools.contains { $0.hasPrefix("→ windows") })
            #expect(!replies.isEmpty)
            first = try #require(try await store.conversation(conversation)?.resumableSession(for: selection.provider))

            let two = try await turn(store, host, worker, conversation,
                                     "Without calling any tool: which Mecum tool did you call in the previous "
                                     + "turn? One word.")
            print("live \(label) turn 2:", two.ending, "resumed:", two.resumed ?? "none")
            print("live \(label) turn 2 replies:", replies)
            print("live \(label) turn 2 sessions:", Set(sessions))
            #expect(two.ending == .completed)
            #expect(two.resumed == first)
            #expect(!sessions.isEmpty && sessions.allSatisfy { $0 == first })
            #expect(replies.joined().lowercased().contains("windows"))
            try await host.close()
        }

        // A relaunch: the store reopened on the same directory, and a new host.
        let store = try WorkspaceStore.opening(in: directory)
        let host  = AgentTurnHost(workingDirectory: work, bridgeExecutable: bridge,
                                  session: { DesktopUnavailableSession() })
        #expect(try await store.conversation(conversation)?.resumableSession(for: selection.provider) == first)
        let three = try await turn(store, host, worker, conversation,
                                   "Without calling any tool: which Mecum tool other than status did you "
                                   + "call earlier in this conversation? One word.")
        print("live \(label) turn 3 after reopen:", three.ending, "resumed:", three.resumed ?? "none")
        print("live \(label) turn 3 replies:", replies)
        print("live \(label) turn 3 sessions:", Set(sessions))
        #expect(three.ending == .completed)
        #expect(three.resumed == first)
        #expect(!sessions.isEmpty && sessions.allSatisfy { $0 == first })
        #expect(replies.joined().lowercased().contains("windows"))
        try await host.close()
    }

    /// A failure here must not fail the row it cleans up after; the path is
    /// under the system temporary directory.
    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch {}
    }
}
