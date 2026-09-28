//
//  ConversationProjectionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import Mecum

@Suite("Projection: merged order, aggregation, identity and targeted updates")
struct ConversationProjectionTests {

    /// A turn: the person asks, the worker starts, three tool records, a reply, the end.
    private func turn(_ fixture: TranscriptFixture) async throws -> UUID {
        let execution = UUID()
        try await fixture.say("Open the report", at: 0, delivery: .completed)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "→ open_session {\"app\":\"Preview\"}")
        try await fixture.record(.toolActivity, subject: execution, at: 3, text: "← open_session {\"session\":\"s\"}")
        try await fixture.record(.toolActivity, subject: execution, at: 4, text: "← act error: denied")
        try await fixture.say("It is open.", at: 5, byWorker: true)
        try await fixture.record(.executionCompleted, subject: execution, at: 6)
        return execution
    }

    private static func kinds(_ items: [TranscriptItem]) -> [String] {
        items.map { item -> String in
            switch item.kind {
            case .personMessage:        "person"
            case .workerReply:          "reply"
            case .toolRun:              "tools"
            case .thinking:             "thinking"
            case .daySeparator:         "day"
            case .contextSeparator:     "context"
            case .executionFailed:      "failed"
            case .executionInterrupted: "interrupted"
            case .activityNotShown:     "notice"
            }
        }
    }

    @Test("Messages and events merge in one deterministic order, the tool line above the reply")
    func mergedOrder() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await turn(fixture)

        let first  = try await fixture.items()
        let second = try await fixture.items()
        #expect(first == second)
        #expect(Self.kinds(first) == ["day", "person", "tools", "reply"])
        #expect(first.map(\.continuesGroup) == [false, false, false, false])
    }

    @Test("The line opens the worker's part of the turn: above its bubble and first reply while it runs, and after")
    func lineAboveTheAnswer() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say("Open the report", at: 0)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "→ open_session {\"app\":\"Preview\"}")
        #expect(Self.kinds(try await fixture.items()) == ["day", "person", "tools", "thinking"])

        try await fixture.record(.toolActivity, subject: execution, at: 3, text: "← open_session {}")
        try await fixture.say("It is open.", at: 4, byWorker: true)
        let between = try await fixture.items()
        #expect(Self.kinds(between) == ["day", "person", "tools", "reply", "thinking"])

        let streaming = try await fixture.say("Page one says", at: 5, byWorker: true, delivery: .responding)
        let running   = try await fixture.items()
        #expect(Self.kinds(running) == ["day", "person", "tools", "reply", "reply"], "the streaming reply hides the bubble")

        try await fixture.store.update(message: streaming.id, delivery: .completed)
        try await fixture.record(.executionCompleted, subject: execution, at: 6)
        let ended = try await fixture.items()
        #expect(ended.map(\.id) == running.map(\.id), "no row moves when the turn ends")
        #expect(ended.map(\.id) == between.map(\.id).filter { if case .thinking = $0 { false } else { true } }
            + [.message(streaming.id)])
    }

    @Test("A turn that replied nothing keeps its line where the reply would have been, after the person's message")
    func lineWithoutReply() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (done, failed) = (UUID(), UUID())
        try await fixture.say("Check the apps", at: 0)
        try await fixture.record(.executionStarted, subject: done, at: 1)
        try await fixture.record(.toolActivity, subject: done, at: 2, text: "→ status {}")
        let running = try await fixture.items()
        try await fixture.record(.executionCompleted, subject: done, at: 3)
        let ended = try await fixture.items()
        #expect(Self.kinds(running) == ["day", "person", "tools", "thinking"])
        #expect(Self.kinds(ended) == ["day", "person", "tools"])
        #expect(ended.map(\.id) == Array(running.map(\.id).dropLast()))

        try await fixture.say("Now push", at: 10)
        try await fixture.record(.executionStarted, subject: failed, at: 11)
        try await fixture.record(.toolActivity, subject: failed, at: 12, text: "← push error: remote refused")
        try await fixture.record(.executionFailed, subject: failed, at: 13, text: "exit 1")
        #expect(Self.kinds(try await fixture.items()) == ["day", "person", "tools", "person", "tools", "failed"])
    }

    @Test("The person's message ends its group, and the reply under the line keeps its header, name and time")
    func replyUnderLineKeepsHeader() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await turn(fixture)
        let items = TranscriptFixture.withoutDays(try await fixture.items())
        let rows  = await RowPreparation.prepare(items, workerName: "Atlas", width: 600,
                                                 style: TranscriptStyle(showsAuthors: true),
                                                 cache: LayoutMeasurementCache(), pipeline: MarkdownContent()).rows
        #expect(Self.kinds(items) == ["person", "tools", "reply"])
        #expect(items[0].endsGroup && rows[0].geometry.tail != nil)
        #expect(!items[1].continuesGroup, "a tool line starts a group")
        #expect(!items[2].continuesGroup && items[2].endsGroup)
        #expect(rows[2].geometry.header != nil && rows[2].geometry.avatar != nil && rows[2].geometry.footer != nil)
        #expect(TranscriptWording.header(for: items[2], workerName: "Atlas").name == "Atlas")
    }

    @Test("A tie between a message and an event puts the message first")
    func tieGoesToMessage() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.record(.executionFailed, subject: execution, at: 10, text: "exit 1")
        try await fixture.say("Same second", at: 10)

        let items = TranscriptFixture.withoutDays(try await fixture.items())
        #expect(items.first?.messageID != nil)
        #expect(items.last?.kind == .executionFailed(reason: "exit 1"))
    }

    @Test("A turn's tool records fold into one line that says what was done")
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
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: lines), ending: ending) == "Opened Preview")
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

        let items = TranscriptFixture.withoutDays(try await fixture.items())
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

        let items    = TranscriptFixture.withoutDays(try await fixture.items())
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
        #expect(TranscriptWording.accessibilityLabel(for: rows[1].item, workerName: "Atlas").hasSuffix("Stopped"))

        #expect(DeliveryBadge(rows[2].item.kind) == .notSent)
        #expect(TranscriptWording.accessibilityLabel(for: rows[2].item, workerName: "Atlas").hasSuffix("Saved"))
        #expect(DeliveryBadge.interrupted.symbolName != DeliveryBadge.notSent.symbolName)
    }

    /// A turn with one call that never got a result, ended as `ending` or still running.
    private func unansweredCall(_ fixture: TranscriptFixture, ending: EventType?) async throws -> String {
        let execution = UUID()
        try await fixture.say("Go", at: 0)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2,
                                 text: "→ act {\"session\":\"s\",\"target\":\"8\"}")
        if let ending { try await fixture.record(ending, subject: execution, at: 3, text: "reason") }
        let items = try await fixture.items()
        guard let run = items.first(where: { if case .toolRun = $0.kind { true } else { false } }),
              case .toolRun(let lines, _, let turnEnding) = run.kind
        else { return "no run" }
        return TranscriptWording.toolSummary(ToolStep.steps(from: lines), ending: turnEnding)
    }

    @Test("A call without a result is running only while its turn is")
    func runningWhileInProgress() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: nil) == "Pressing 8…")
    }

    @Test("A call without a result in a stopped turn is summarised as stopped")
    func stoppedTurnIsNotRunning() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: .executionCancelled) == "Pressing 8, stopped")
    }

    @Test("A call without a result in a failed turn is summarised as not finished")
    func failedTurnIsNotRunning() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        #expect(try await unansweredCall(fixture, ending: .executionFailed) == "Pressing 8, did not finish")
    }

    @Test("A normal send never shows the unsent badge; a message left unsent past the grace does")
    func unsentBadgeWaitsForTheGrace() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let message = try await fixture.say("Hello", at: 0, delivery: .savedLocally)
        let saved   = TranscriptFixture.at(0)

        // The instant between saved and sent, then sent: no badge at either point.
        let justSaved = TranscriptFixture.withoutDays(try await fixture.items(now: saved.addingTimeInterval(0.2)))
        #expect(DeliveryBadge(justSaved[0].kind) == nil)
        try await fixture.store.update(message: message.id, delivery: .sentToBackend)
        let sent = TranscriptFixture.withoutDays(try await fixture.items(now: saved.addingTimeInterval(0.3)))
        #expect(DeliveryBadge(sent[0].kind) == nil)

        // Nothing sent it: once the grace has passed, it is marked.
        try await fixture.store.update(message: message.id, delivery: .savedLocally)
        let waiting = TranscriptFixture.withoutDays(
            try await fixture.items(now: saved.addingTimeInterval(DeliveryBadge.unsentGrace))
        )
        #expect(DeliveryBadge(waiting[0].kind) == .notSent)
        #expect(TranscriptWording.accessibilityLabel(for: waiting[0], workerName: "Atlas").hasSuffix("Saved"))
    }

    @Test("No delivery state says read")
    func noReadState() {
        let labels = MessageDelivery.allCases.map(TranscriptWording.delivery)
        #expect(labels == ["Saved", "Waiting", "Sent", "Responding", "Completed", "Stopped"])
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("read") || $0.localizedCaseInsensitiveContains("seen") })
    }

    @Test("An event of a type this build does not know draws nothing and splits no tool run")
    func unknownTypeIsSkipped() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let execution = UUID()
        try await fixture.say("Open the report", at: 0, delivery: .completed)
        try await fixture.record(.executionStarted, subject: execution, at: 1)
        try await fixture.record(.toolActivity, subject: execution, at: 2, text: "→ open {}")
        let unknown = try await fixture.record(.unknown("taskHandedOff"), subject: execution, at: 3, text: "Nova")
        try await fixture.record(.toolActivity, subject: execution, at: 4, text: "← open {}")
        try await fixture.record(.executionCompleted, subject: execution, at: 5)

        #expect(unknown.type == .unknown("taskHandedOff"))
        let items = try await fixture.items()
        let hidden: Set<TranscriptItem.ID> = [.event(unknown.id), .toolRun(unknown.id), .notice(unknown.id)]
        #expect(!items.contains { hidden.contains($0.id) })
        let runs = items.compactMap { if case .toolRun(let lines, _, _) = $0.kind { lines } else { nil } }
        #expect(runs == [["→ open {}", "← open {}"]])
        #expect(TranscriptFixture.withoutDays(items).count == 2)
    }
}
