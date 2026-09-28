//
//  WorkerSessionResumeTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A worker's provider session, through the real host, recorder and store, with
/// a stand-in command line that logs the session it was asked to resume.
@MainActor
@Suite("A worker's provider session")
struct WorkerSessionResumeTests {

    private static let claude = ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low)
    private static let codex  = ModelSelection(provider: .codex, model: "gpt-5.6-luna", effort: .low)

    @Test func itIsStoredResumedAfterAReopenAndIgnoredForAnotherProvider() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-session-\(UUID().uuidString)")
        defer { remove(root) }
        let directory = root.appending(path: "store", directoryHint: .isDirectory)
        let work      = root.appending(path: "work", directoryHint: .isDirectory)
        let log       = root.appending(path: "resumed.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standIn = try Self.standIn(logging: log, in: root)
        let agents: (ModelProvider) throws -> (ChatProvider, URL) = { ($0 == .codex ? .codex : .claude, standIn) }

        let worker      : UUID
        let conversation: UUID
        do {
            let store = try WorkspaceStore.opening(in: directory)
            let appearance = WorkerAppearance(seed: 7, generatorVersion: 3, palette: "dusk",
                                              roundness: 0.5, wobble: 0.5, glow: 0.5)
            worker = try await store.createWorker(name: "Nova", appearance: appearance).id
            try await store.configure(worker: worker, selection: Self.claude)
            conversation = try await store.createConversation(participants: [worker]).id
            let host = WorkerAgentHost(workingDirectory: work, bridgeExecutable: standIn,
                                        session: { DesktopUnavailableSession() }, agents: agents)

            // The first turn starts a session, and the provider's id is stored with its provider.
            #expect(try await Self.turn(store, host, worker, conversation) == .completed)
            #expect(try await store.conversation(conversation)?.resumableSession(for: .claudeCode)
                    == "claude-session-1")

            // The next turn resumes it.
            #expect(try await Self.turn(store, host, worker, conversation) == .completed)
            try await host.close()
        }
        #expect(try Self.resumed(log) == ["none", "claude-session-1"])

        // A relaunch: a new store on the same directory and a new host.
        let store = try WorkspaceStore.opening(in: directory)
        let host  = WorkerAgentHost(workingDirectory: work, bridgeExecutable: standIn,
                                        session: { DesktopUnavailableSession() }, agents: agents)
        #expect(try await Self.turn(store, host, worker, conversation) == .completed)
        #expect(try Self.resumed(log).last == "claude-session-1")

        // Another provider is not offered Claude's session, and its own replaces it.
        try await store.configure(worker: worker, selection: Self.codex)
        #expect(try await Self.turn(store, host, worker, conversation) == .completed)
        #expect(try Self.resumed(log).last == "none")
        let afterCodex = try #require(try await store.conversation(conversation))
        #expect(afterCodex.resumableSession(for: .codex) == "codex-thread-1")
        #expect(afterCodex.resumableSession(for: .claudeCode) == nil)

        // Back on Claude, the replaced session is gone rather than resumed.
        try await store.configure(worker: worker, selection: Self.claude)
        #expect(try await Self.turn(store, host, worker, conversation) == .completed)
        #expect(try Self.resumed(log) == ["none", "claude-session-1", "claude-session-1", "none", "none"])
        try await host.close()
    }

    /// One recorded turn, the way `TeamModel` runs it.
    private static func turn(
        _ store       : WorkspaceStore,
        _ host        : WorkerAgentHost,
        _ worker      : UUID,
        _ conversation: UUID
    ) async throws -> WorkerTurnRecorder.Ending {
        let message = try await store.appendMessage(to: conversation, text: "Hello")
        let recorder = WorkerTurnRecorder(store: store, workspaceID: UUID(), workerID: worker,
                                          conversationID: conversation, messageID: message.id) {}
        return try await recorder.run { selection, session, emit in
            try await host.run(prompt: message.text, selection: selection, sessionID: session, role: nil,
                               onEvent: emit)
        }
    }

    /// A stand-in for both command lines. It appends the session it was asked
    /// to resume, or `none`, and answers in that provider's JSONL.
    private static func standIn(logging log: URL, in directory: URL) throws -> URL {
        let path = directory.appending(path: "agent")
        let body = """
        #!/bin/sh
        cat >/dev/null
        resumed=none; previous=
        for argument in "$@"; do
            case "$previous" in --resume|resume) resumed="$argument";; esac
            previous="$argument"
        done
        echo "$resumed" >> '\(log.path)'
        if [ "$1" = exec ]; then
            echo '{"type":"thread.started","thread_id":"codex-thread-1"}'
            echo '{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}'
            echo '{"type":"turn.completed"}'
        else
            session=claude-session-1
            [ "$resumed" != none ] && session="$resumed"
            echo "{\\"type\\":\\"system\\",\\"session_id\\":\\"$session\\"}"
            echo "{\\"type\\":\\"result\\",\\"is_error\\":false,\\"result\\":\\"hi\\",\\"session_id\\":\\"$session\\"}"
        fi
        """
        try Data((body + "\n").utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    private static func resumed(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A failure here must not fail the row it cleans up after; the path is
    /// under the system temporary directory.
    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch {}
    }
}
