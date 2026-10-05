//
//  UnfinishedTurnRecoveryTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AgentTurn
import ChatCore
import CLIProviders
import Darwin
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A turn a crash cut short, with real processes standing in for the agent
/// child: one orphaned as a crashed app's child would be, one still held by
/// its parent, and a recorded identity whose pid now names someone else.
@MainActor
@Suite("A turn a crash left unfinished, at the next launch")
struct UnfinishedTurnRecoveryTests {

    @Test func theHostReportsItsChildAndTheRecorderKeepsIt() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-child-\(UUID().uuidString)")
        defer { removeScratch(root) }
        let standIn = try standInAgent(in: root, body: """
        cat >/dev/null
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"Done."}}'
        echo '{"type":"turn.completed"}'
        """)
        let turn = try await TurnInStore(directory: root.appending(path: "store"))
        let host = AgentTurnHost(workingDirectory: root.appending(path: "work"), bridgeExecutable: standIn,
                                   session: { DesktopUnavailableSession() }, agents: { _ in (.codex, standIn) })
        let ending = try await turn.recorder.run { frozen, session, emit in
            try await host.run(prompt: "p", selection: frozen, sessionID: session, role: nil, onEvent: emit)
        }
        try await host.close()
        #expect(ending == .completed)

        let events = try await turn.store.events(matching: EventQuery(scope: .conversation(turn.conversation)))
        #expect(events.map(\.type) == [.executionStarted, .agentProcessStarted, .executionCompleted])
        let payload  = try #require(events[1].payload)
        let identity = try JSONDecoder().decode(ChildProcessIdentity.self, from: payload)
        #expect(identity.pid > 0)
        #expect(identity.executablePath == "/bin/sh")
        #expect(WorkerTurnRecorder.text(of: events[1]) == nil)
    }

    @Test func onlyTheOrphanedChildTheTurnSpawnedIsStopped() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-orphan-\(UUID().uuidString)")
        defer { removeScratch(root) }
        let directory = root.appending(path: "store")

        // The shell exits at once, so its sleep is reparented to launchd, as a crashed app's child is.
        let orphanPID = try Self.spawnOrphan()
        defer { kill(orphanPID, SIGKILL) }
        let orphan = try #require(ChildProcessIdentity(running: orphanPID))

        let held = Process()
        held.executableURL = URL(fileURLWithPath: "/bin/sleep")
        held.arguments     = ["30"]
        try held.run()
        defer { held.terminate() }
        let heldIdentity = try #require(ChildProcessIdentity(running: held.processIdentifier))
        let reused = try ChildProcessIdentity.forged(heldIdentity, startSeconds: heldIdentity.startSeconds - 60)

        let crashed = try await TurnInStore(directory: directory)
        let execution = try await crashed.startTurn()
        for identity in [orphan, heldIdentity, reused] {
            try await crashed.store.append(NewEvent(
                workspaceID: crashed.workspace, subjectID: execution, conversationID: crashed.conversation,
                workerID: crashed.worker, type: .agentProcessStarted, payload: try JSONEncoder().encode(identity)
            ))
        }

        let relaunched = try WorkspaceStore.opening(in: directory)
        let recovery = try await WorkerTurnRecorder.endTurnsLeftUnfinished(in: relaunched,
                                                                           workspaceID: crashed.workspace)
        #expect(recovery.endedExecutions == [execution])
        #expect(recovery.stoppedProcesses == [orphanPID])
        #expect(try await Self.exits(orphanPID))
        #expect(held.isRunning)

        let events = try await relaunched.events(matching: EventQuery(scope: .subject(execution)))
        #expect(events.last?.type == .executionFailed)
        #expect(events.last.flatMap(WorkerTurnRecorder.text(of:)) == WorkerTurnRecorder.closedDuringTurnReason)
        #expect(try await relaunched.message(crashed.message)?.delivery == .interrupted)

        let again = try WorkspaceStore.opening(in: directory)
        let second = try await WorkerTurnRecorder.endTurnsLeftUnfinished(in: again, workspaceID: crashed.workspace)
        #expect(second == WorkerTurnRecorder.Recovery(endedExecutions: [], stoppedProcesses: []))
        #expect(try await again.events(matching: EventQuery(scope: .subject(execution))) == events)
    }

    /// Starts `/bin/sleep 30` under a shell that exits at once and returns the sleep's pid once
    /// launchd holds it.
    private static func spawnOrphan() throws -> pid_t {
        let shell  = Process()
        let output = Pipe()
        shell.executableURL  = URL(fileURLWithPath: "/bin/sh")
        shell.arguments      = ["-c", "/bin/sleep 30 >/dev/null 2>&1 </dev/null & echo $!"]
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func exits(_ pid: pid_t) async throws -> Bool {
        for _ in 0..<80 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

extension ChildProcessIdentity {

    /// The same identity with another start time: a later process given the same pid.
    static func forged(_ identity: ChildProcessIdentity, startSeconds: Int) throws -> ChildProcessIdentity {
        let encoded = try JSONEncoder().encode(identity)
        var object  = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["startSeconds"] = startSeconds
        return try JSONDecoder().decode(ChildProcessIdentity.self,
                                        from: try JSONSerialization.data(withJSONObject: object))
    }
}

/// One worker on Codex, its conversation and the person's message, in a
/// store of its own, with the recorder a turn would use.
@MainActor
struct TurnInStore {

    let workspace = UUID()
    let store       : WorkspaceStore
    let worker      : UUID
    let conversation: UUID
    let message     : UUID
    let recorder    : WorkerTurnRecorder

    init(directory: URL) async throws {
        store = try WorkspaceStore.opening(in: directory)
        let appearance = WorkerAppearance(seed: 7, generatorVersion: 3, palette: "dusk",
                                          roundness: 0.5, wobble: 0.5, glow: 0.5)
        worker = try await store.createWorker(name: "Nova", appearance: appearance).id
        try await store.configure(worker: worker,
                                  selection: ModelSelection(provider: .codex, model: "gpt-5.6-luna", effort: .low))
        conversation = try await store.createConversation(kind: .direct, participants: [worker]).id
        message = try await store.appendMessage(to: conversation, text: "Open Notes").id
        recorder = WorkerTurnRecorder(store: store, workspaceID: workspace, workerID: worker,
                                      conversationID: conversation, messageID: message) {}
    }

    /// What the recorder has written once its turn is running.
    func startTurn() async throws -> UUID {
        let execution = try await store.startExecution(worker: worker, conversation: conversation).id
        try await store.append(NewEvent(workspaceID: workspace, subjectID: execution, conversationID: conversation,
                                        workerID: worker, type: .executionStarted, correlationID: message))
        try await store.update(message: message, delivery: .sentToBackend)
        return execution
    }
}

/// A shell stand-in for the agent command line, executable, in `root`.
func standInAgent(in root: URL, body: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "agent")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}

/// A failure here must not fail the row it cleans up after; the path is
/// under the system temporary directory.
func removeScratch(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch {}
}
