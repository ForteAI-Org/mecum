//
//  TurnSummaryTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// The inspector's turn, read through a real store in its own directory.
@Suite("The turn the inspector shows")
struct TurnSummaryTests {

    private static let workspaceID = UUID()
    private static let first  = ModelSelection(provider: .claudeCode, model: "claude-opus-5", effort: .high)
    private static let second = ModelSelection(provider: .codex, model: "gpt-5.4-mini", effort: .low)

    private static func directory() -> URL {
        URL.temporaryDirectory.appending(path: "TeamShellTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func discard(_ directory: URL) {
        // A leftover temporary directory must not fail the test it cleans up after.
        do { try FileManager.default.removeItem(at: directory) } catch {}
    }

    private static func end(_ execution: ExecutionSnapshot, _ type: EventType, text: String? = nil,
                            in store: WorkspaceStore) async throws {
        try await store.append(NewEvent(workspaceID: workspaceID, subjectID: execution.id,
                                        workerID: execution.workerID, type: type,
                                        payload: text.map { Data($0.utf8) }))
    }

    @Test("A past turn keeps the model and effort it ran with after the profile changes")
    func aProfileChangeDoesNotRewriteAPastTurn() async throws {
        let directory = Self.directory()
        defer { Self.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas", appearance: WorkerAppearance(seed: 1, palette: "tide"))

        #expect(try await TurnSummary.latest(of: worker.id, in: store, isRunning: false) == nil)

        try await store.configure(worker: worker.id, selection: Self.first)
        let execution = try await store.startExecution(worker: worker.id)
        try await Self.end(execution, .executionCompleted, in: store)
        try await store.configure(worker: worker.id, selection: Self.second)

        let turn = try #require(try await TurnSummary.latest(of: worker.id, in: store, isRunning: false))
        #expect(turn.executionID == execution.id)
        #expect(turn.selection == Self.first)
        #expect(turn.modelLine == "claude-opus-5, High Effort")
        #expect(turn.state == .completed)
        #expect(try await store.worker(worker.id)?.configuration == Self.second)
    }

    @Test("The latest turn is the one started last, and a running one counts only before its end")
    func theLatestTurnAndItsState() async throws {
        let directory = Self.directory()
        defer { Self.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Iris", appearance: WorkerAppearance(seed: 2, palette: "dusk"))
        try await store.configure(worker: worker.id, selection: Self.first)
        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let older  = try await store.startExecution(worker: worker.id, at: origin)
        try await Self.end(older, .executionFailed, text: "The provider stopped with exit status 1.", in: store)
        try await store.configure(worker: worker.id, selection: Self.second)
        let newer = try await store.startExecution(worker: worker.id, at: origin.addingTimeInterval(60))

        let running = try #require(try await TurnSummary.latest(of: worker.id, in: store, isRunning: true))
        #expect(running.executionID == newer.id)
        #expect(running.state == .running)
        #expect(running.modelLine == "gpt-5.4-mini, Low Effort")

        let orphan = try #require(try await TurnSummary.latest(of: worker.id, in: store, isRunning: false))
        #expect(orphan.state == .unfinished)
        #expect(orphan.isTrouble)

        try await Self.end(newer, .executionCancelled, text: "Interrupted.", in: store)
        let stopped = try #require(try await TurnSummary.latest(of: worker.id, in: store, isRunning: true))
        #expect(stopped.state == .stopped)
        #expect(!stopped.isTrouble)

        let failed = TurnSummary(execution: older, events: try await store.events(matching: EventQuery(
            scope: .subject(older.id))), isRunning: false)
        #expect(failed.state == .failed(reason: "The provider stopped with exit status 1."))
        #expect(failed.isTrouble)
    }

    @Test("A model with no effort parameter shows the model alone, and Ollama says thinking rather than effort")
    func theModelLineFollowsTheProvidersKnob() async throws {
        let directory = Self.directory()
        defer { Self.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Nova", appearance: WorkerAppearance(seed: 3, palette: "moss"))

        try await store.configure(worker: worker.id, selection: ModelSelection(
            provider: .anthropic, model: "claude-haiku-4-5", effort: .medium))
        let haiku = try await store.startExecution(worker: worker.id)
        #expect(TurnSummary(execution: haiku, events: [], isRunning: true).modelLine == "claude-haiku-4-5")

        try await store.configure(worker: worker.id, selection: ModelSelection(
            provider: .ollama, model: "qwen3:8b", effort: .high))
        let local = try await store.startExecution(worker: worker.id)
        #expect(TurnSummary(execution: local, events: [], isRunning: true).modelLine == "qwen3:8b, Thinking")
    }
}
