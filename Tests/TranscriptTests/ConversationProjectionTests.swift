//
//  ConversationProjectionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import Transcript
import Workspace

@Suite("Projection: merged order, aggregation, identity and targeted updates")
struct ConversationProjectionTests {

    /// A turn: the person asks, the worker starts, three tools, a reply, the end.
    private func turn(_ fixture: TranscriptFixture) async throws -> UUID {
        let execution = UUID()
        try await fixture.say("Open the report", at: 0, delivery: .completed)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "→ open {}")
        try await fixture.record(.toolActivity, subject: execution, at: 3, text: "← open {}")
        try await fixture.record(.toolActivity, subject: execution, at: 4, text: "← read error: denied")
        try await fixture.say("It is open.", at: 5, byWorker: true)
        try await fixture.record(.executionCompleted, subject: execution, at: 6)
        return execution
    }

    @Test("Messages and events merge in one deterministic order")
    func mergedOrder() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await turn(fixture)

        let first  = try await fixture.items()
        let second = try await fixture.items()
        #expect(first == second)

        let kinds = first.map { item -> String in
            switch item.kind {
            case .personMessage:        "person"
            case .workerReply:          "reply"
            case .toolRun:              "tools"
            case .executionStarted:     "started"
            case .executionCompleted:   "completed"
            case .executionFailed:      "failed"
            case .executionInterrupted: "interrupted"
            case .activityNotShown:     "notice"
            }
        }
        #expect(kinds == ["person", "started", "tools", "reply", "completed"])
    }

    @Test("A tie between a message and an event puts the message first")
    func tieGoesToMessage() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.record(.executionStarted, subject: execution, at: 10)
        try await fixture.say("Same second", at: 10)

        let items = try await fixture.items()
        #expect(items.first?.messageID != nil)
        #expect(items.last?.kind == .executionStarted)
    }

    @Test("Consecutive tool records fold into one run with counts")
    func aggregation() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await turn(fixture)

        let items = try await fixture.items()
        let runs  = items.filter { if case .toolRun = $0.kind { true } else { false } }
        #expect(runs.count == 1)
        guard case .toolRun(let lines, let isExpanded, let ending) = runs.first?.kind else {
            Issue.record("no tool run")
            return
        }
        #expect(lines.count == 3)
        #expect(!isExpanded)
        #expect(ending == .completed)
        #expect(TranscriptWording.toolSummary(lines, ending: ending) == "1 tool call completed, 1 needs attention")
    }

    @Test("Expanding a run changes that row only and reorders nothing")
    func expansionKeepsOrder() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await turn(fixture)

        let folded = try await fixture.items()
        let runID  = try #require(folded.first { if case .toolRun = $0.kind { true } else { false } }?.id)
        let open   = try await fixture.items(expanded: [runID])

        #expect(open.map(\.id) == folded.map(\.id))
        let update = TranscriptUpdate(from: folded, to: open)
        #expect(update.changed == [runID])
        #expect(update.inserted.isEmpty && update.removed.isEmpty)
    }

    @Test("Identifiers survive an update, and one change is one targeted update")
    func stableIdentityAndTargetedUpdate() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let question = try await fixture.say("Status?", at: 0, delivery: .sentToBackend)
        try await fixture.say("Working on it", at: 1, byWorker: true)

        let before = try await fixture.items()
        try await fixture.store.update(message: question.id, delivery: .completed)
        let after  = try await fixture.items()

        #expect(after.map(\.id) == before.map(\.id))
        let update = TranscriptUpdate(from: before, to: after)
        #expect(update.changed == [.message(question.id)])
        #expect(update.inserted.isEmpty && update.removed.isEmpty)
    }

    @Test("A run that grows keeps its id, and a new record is not a new row")
    func growingRunKeepsIdentity() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say("Go", at: 0)
        try await fixture.record(.toolActivity, subject: execution, at: 1, text: "→ a {}")
        let before = try await fixture.items()
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "← a {}")
        let after  = try await fixture.items()

        let update = TranscriptUpdate(from: before, to: after)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(update.changed.count == 1)
        #expect(update.inserted.isEmpty)
    }

    @Test("A stopped answer keeps its partial reply, marked interrupted")
    func interruptedReply() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say("Write it", at: 0, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.say("Half of the", at: 2, byWorker: true)
        try await fixture.record(.executionCancelled, subject: execution, at: 3, text: "Interrupted. Look first.")

        let items = try await fixture.items()
        #expect(items.contains { $0.kind == .workerReply(text: "Half of the", isInterrupted: true) })
        #expect(items.last?.kind == .executionInterrupted(note: "Interrupted. Look first."))
    }

    @Test("Consecutive messages of one author group, and every label keeps author and time")
    func grouping() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("One", at: 0, byWorker: true)
        try await fixture.say("Two", at: 20, byWorker: true)
        try await fixture.say("Much later", at: 2000, byWorker: true)

        let items = try await fixture.items()
        #expect(items.map(\.continuesGroup) == [false, true, false])
        let label = TranscriptWording.accessibilityLabel(for: items[1], workerName: "Atlas")
        #expect(label.hasPrefix("Atlas, \(TranscriptWording.time(items[1].date))"))
    }

    @Test("A capped event read keeps the latest events and says, in a row, that older ones are not shown")
    func cappedReadIsAnnounced() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say("Go", at: 0)
        for step in 0..<5 {
            try await fixture.record(.toolActivity, subject: execution, at: 1 + Double(step), text: "→ step \(step)")
        }

        let whole = try await fixture.items(eventLimit: 5)
        #expect(!whole.contains { $0.kind == .activityNotShown })

        let capped = try await fixture.items(eventLimit: 3)
        let notice = try #require(capped.firstIndex { $0.kind == .activityNotShown })
        guard case .toolRun(let lines, _, _) = capped[notice + 1].kind else {
            Issue.record("the notice is not followed by the run it cut")
            return
        }
        #expect(lines == ["→ step 2", "→ step 3", "→ step 4"])
    }

    @Test("A message that went fine shows no status, and its accessibility label still names the state")
    func healthyMessageIsQuiet() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Fine", at: 0, delivery: .completed)
        try await fixture.say("Stopped", at: 400, delivery: .interrupted)
        try await fixture.say("Never sent", at: 800, delivery: .savedLocally)

        let items    = try await fixture.items()
        let prepared = await RowPreparation.prepare(items, workerName: "Atlas", width: 600, style: TranscriptStyle(),
                                                    cache: LayoutMeasurementCache(), pipeline: PlainTextContent())
        let rows = prepared.rows

        #expect(DeliveryBadge(rows[0].item.kind) == nil)
        #expect(rows[0].geometry.badge == nil)
        #expect(rows[0].text.string == "Fine")
        #expect(TranscriptWording.header(for: rows[0].item, workerName: "Atlas").name == nil)
        #expect(TranscriptWording.accessibilityLabel(for: rows[0].item, workerName: "Atlas").hasSuffix("Completed"))
        #expect(TranscriptWording.accessibilityLabel(for: rows[0].item, workerName: "Atlas").hasPrefix("You, "))

        #expect(DeliveryBadge(rows[1].item.kind) == .interrupted)
        #expect(rows[1].geometry.badge != nil)
        #expect(TranscriptWording.accessibilityLabel(for: rows[1].item, workerName: "Atlas").hasSuffix("Interrupted"))

        #expect(DeliveryBadge(rows[2].item.kind) == .notSent)
        #expect(TranscriptWording.accessibilityLabel(for: rows[2].item, workerName: "Atlas").hasSuffix("Saved"))
        #expect(DeliveryBadge.interrupted.symbolName != DeliveryBadge.notSent.symbolName)
    }

    /// A turn with one call that never got a result, ended as `ending` or still running.
    private func unansweredCall(_ fixture: TranscriptFixture, ending: EventType?) async throws -> String {
        let execution = UUID()
        try await fixture.say("Go", at: 0)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "→ open {}")
        if let ending { try await fixture.record(ending, subject: execution, at: 3, text: "reason") }
        let items = try await fixture.items()
        guard let run = items.first(where: { if case .toolRun = $0.kind { true } else { false } }),
              case .toolRun(let lines, _, let turnEnding) = run.kind
        else { return "no run" }
        return TranscriptWording.toolSummary(lines, ending: turnEnding)
    }

    @Test("A call without a result is running only while its turn is")
    func runningWhileInProgress() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: nil) == "1 running")
    }

    @Test("A call without a result in a stopped turn is summarised as stopped")
    func stoppedTurnIsNotRunning() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: .executionCancelled) == "1 stopped")
    }

    @Test("A call without a result in a failed turn is summarised as not finished")
    func failedTurnIsNotRunning() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: .executionFailed) == "1 did not finish")
    }

    @Test("A normal send never shows the unsent badge; a message left unsent past the grace does")
    func unsentBadgeWaitsForTheGrace() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let message = try await fixture.say("Hello", at: 0, delivery: .savedLocally)
        let saved   = TranscriptFixture.at(0)

        // The instant between saved and sent, then sent: no badge at either point.
        let justSaved = try await fixture.items(now: saved.addingTimeInterval(0.2))
        #expect(DeliveryBadge(justSaved[0].kind) == nil)
        try await fixture.store.update(message: message.id, delivery: .sentToBackend)
        let sent = try await fixture.items(now: saved.addingTimeInterval(0.3))
        #expect(DeliveryBadge(sent[0].kind) == nil)

        // Nothing sent it: once the grace has passed, it is marked.
        try await fixture.store.update(message: message.id, delivery: .savedLocally)
        let waiting = try await fixture.items(now: saved.addingTimeInterval(DeliveryBadge.unsentGrace))
        #expect(DeliveryBadge(waiting[0].kind) == .notSent)
        #expect(TranscriptWording.accessibilityLabel(for: waiting[0], workerName: "Atlas").hasSuffix("Saved"))
    }

    @Test("No delivery state says read")
    func noReadState() {
        let labels = MessageDelivery.allCases.map(TranscriptWording.delivery)
        #expect(labels == ["Saved", "Waiting", "Sent", "Responding", "Completed", "Interrupted"])
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("read") || $0.localizedCaseInsensitiveContains("seen") })
    }
}
