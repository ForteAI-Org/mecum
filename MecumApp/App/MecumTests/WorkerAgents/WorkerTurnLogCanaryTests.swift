//
//  WorkerTurnLogCanaryTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ChatCore
import CLIProviders
import Darwin
import Foundation
import OSLog
import Testing
@testable import Mecum

/// Ordinary logs carry ids, durations and outcomes, never a prompt, a scene
/// or a key (§15.5). Two turns run through the host and the recorder with
/// recognizable values: one that completes and one whose child fails and
/// prints the prompt on its standard error. What this process wrote to its
/// standard output and error, and what it logged, is then searched for them.
///
/// Both captures carry a control line, so a capture that saw nothing fails
/// instead of passing. The desktop's own log lines need a seat and are not
/// reached here.
@MainActor
@Suite("A turn's logs")
struct WorkerTurnLogCanaryTests {

    private static let prompt = "CANARY-PROMPT-7f3a Please open Notes"
    private static let key    = "sk-ant-CANARY-KEY-91c2"
    private static let scene  = "CANARY-SCENE-4d8e Inbox (3)"

    @Test func noPromptSceneOrKeyReachesTheLogs() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-canary-\(UUID().uuidString)")
        defer { removeScratch(root) }
        let answering = try standInAgent(in: root.appending(path: "answering"), body: """
        prompt=$(cat)
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"You said: %s"}}\\n' "$prompt"
        echo '{"type":"turn.completed"}'
        """)
        let failing = try standInAgent(in: root.appending(path: "failing"), body: """
        prompt=$(cat)
        echo "no model for: $prompt $ANTHROPIC_API_KEY" >&2
        exit 3
        """)
        var inherited = ProcessInfo.processInfo.environment
        inherited["ANTHROPIC_API_KEY"] = Self.key

        let turn    = try await TurnInStore(directory: root.appending(path: "store"))
        let started = Date()
        let control = "CONTROL-\(UUID().uuidString)"
        var endings: [WorkerTurnRecorder.Ending] = []

        let written = try await Self.capturingStandardStreams(in: root) {
            FileHandle.standardError.write(Data("\(control)\n".utf8))
            Logger(subsystem: "dev.forte.MecumTests", category: "Canary").error("\(control, privacy: .public)")
            for executable in [answering, failing] {
                let message  = try await turn.store.appendMessage(to: turn.conversation, text: Self.prompt).id
                let recorder = WorkerTurnRecorder(store: turn.store, workspaceID: turn.workspace,
                                                  workerID: turn.worker, conversationID: turn.conversation,
                                                  messageID: message) {}
                let host = WorkerAgentHost(workingDirectory: root.appending(path: "work"),
                                           bridgeExecutable: executable, session: { DesktopUnavailableSession() },
                                           agents: { _ in (.codex, executable) })
                endings.append(try await recorder.run { frozen, session, emit in
                    emit(.tool("← observe {\"scene\":\"\(Self.scene)\"}"))
                    try await host.run(prompt: Self.prompt, selection: frozen, sessionID: session, role: nil,
                                       inheritedEnvironment: inherited, onEvent: emit)
                })
                try await host.close()
            }
        }
        let logged = try Self.loggedMessages(since: started)

        // The canaries went through the code under test: the reply and the failure carry the prompt.
        #expect(endings.first == .completed)
        guard case .failed(let reason) = endings.last else { Issue.record("The failing turn did not fail."); return }
        #expect(reason.contains("CANARY-PROMPT"))
        #expect(!reason.contains("CANARY-KEY"))
        let replies = try await turn.store.messages(in: turn.conversation).map(\.text)
        #expect(replies.contains { $0.hasPrefix("You said: CANARY-PROMPT") })

        #expect(written.contains(control))
        #expect(logged.contains { $0.contains(control) })
        for canary in ["CANARY-PROMPT", "CANARY-KEY", "CANARY-SCENE"] {
            #expect(!written.contains(canary), "\(canary) was written to standard output or error")
            #expect(!logged.contains { $0.contains(canary) }, "\(canary) was logged")
        }
    }

    /// Runs `work` with this process's standard output and error sent to a
    /// file, puts them back whatever `work` does, and returns what was written.
    private static func capturingStandardStreams(
        in root: URL,
        _ work : () async throws -> Void
    ) async throws -> String {
        let file = root.appending(path: "streams.log")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let capture = open(file.path, O_WRONLY | O_APPEND)
        guard capture >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fflush(nil)
        let savedOutput = dup(1)
        let savedError  = dup(2)
        dup2(capture, 1)
        dup2(capture, 2)
        var failure: (any Error)?
        do { try await work() } catch { failure = error }
        fflush(nil)
        dup2(savedOutput, 1)
        dup2(savedError, 2)
        close(savedOutput)
        close(savedError)
        close(capture)
        if let failure { throw failure }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    /// Every message this process logged since `start`, as the log composes it.
    private static func loggedMessages(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .map(\.composedMessage)
    }
}
