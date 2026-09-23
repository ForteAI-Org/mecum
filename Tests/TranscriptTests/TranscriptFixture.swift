//
//  TranscriptFixture.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Transcript
import Workspace

/// TranscriptFixture is a real store in its own temporary directory, with one
/// worker and one conversation, and writers that take explicit times so the
/// merged order under test does not depend on the clock.
struct TranscriptFixture {

    static let workspaceID = UUID()

    static let appearance = WorkerAppearance(seed: 7, palette: "tide")

    let directory   : URL
    let store       : WorkspaceStore
    let workerID    : UUID
    let conversation: UUID

    /// Every test's times count from here, one second per step.
    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() async throws {
        directory = URL.temporaryDirectory.appending(path: "TranscriptTests-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        store = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas", appearance: Self.appearance)
        workerID     = worker.id
        conversation = try await store.createConversation(participants: [worker.id]).id
    }

    /// Removes the directory. A failure must not fail the test it cleans up after.
    func discard() {
        do { try FileManager.default.removeItem(at: directory) } catch { }
    }

    static func at(_ second: Double) -> Date { origin.addingTimeInterval(second) }

    @discardableResult
    func say(_ text: String, at second: Double, byWorker: Bool = false,
             delivery: MessageDelivery = .completed) async throws -> MessageSnapshot {
        try await store.appendMessage(to: conversation, author: byWorker ? workerID : nil, text: text,
                                      at: Self.at(second), delivery: delivery)
    }

    @discardableResult
    func record(_ type: EventType, subject: UUID, at second: Double, text: String? = nil) async throws
        -> RecordedEvent {
        try await store.append(NewEvent(
            workspaceID   : Self.workspaceID,
            subjectID     : subject,
            conversationID: conversation,
            workerID      : workerID,
            timestamp     : Self.at(second),
            type          : type,
            payload       : text.map { Data($0.utf8) }
        ))
    }

    /// The whole conversation as the transcript would project it.
    /// Projected at `now`, by default long after every fixture time.
    func items(
        expanded  : Set<TranscriptItem.ID> = [],
        eventLimit: Int = TranscriptWindow.defaultEventLimit,
        now       : Date = TranscriptFixture.at(100_000)
    ) async throws -> [TranscriptItem] {
        let window = try await TranscriptWindow.opening(conversation, around: nil, from: store,
                                                        eventLimit: eventLimit)
        return ConversationProjection.items(messages: window.messages, events: window.events,
                                            expanded: expanded, elidedBefore: window.elidedBefore, now: now)
    }
}
