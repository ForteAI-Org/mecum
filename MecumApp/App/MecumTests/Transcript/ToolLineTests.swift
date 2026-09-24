//
//  ToolLineTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import Mecum

/// The tool line: records as `AutomationTools` writes them, read back as
/// short human phrases, repeats collapsed, a failure marked and explained.
@Suite("Tool line: phrases per tool, repeats, failures, expand and collapse")
struct ToolLineTests {

    private static func done(_ lines: [String]) -> [String] {
        TranscriptWording.toolSteps(ToolStep.steps(from: lines), ending: .completed).map(\.text)
    }

    @Test("Every tool of the host reads as a short phrase, and an unknown tool keeps its name")
    func phrasePerTool() {
        let lines = [
            "→ status {}", "← status {\"session\":null}",
            "→ windows {}", "← windows {\"applications\":[]}",
            "→ windows {\"app\":\"Notes\"}", "← windows {\"applications\":[]}",
            "→ open_session {\"app\":\"Calculator\"}", "← open_session {\"session\":\"s\"}",
            "→ observe {\"session\":\"s\"}", "← observe {\"scene\":\"…\"}",
            "→ act {\"session\":\"s\",\"target\":\"8\"}", "← act {\"status\":\"found_acted\",\"message\":\"ok\"}",
            "→ act {\"session\":\"s\",\"target\":\"Row\",\"verb\":\"double_click\",\"section\":\"Files\"}",
            "← act {\"status\":\"found_acted\"}",
            "→ act {\"session\":\"s\",\"target\":\"Item\",\"verb\":\"right_click\"}",
            "← act {\"status\":\"found_acted\"}",
            "→ act {\"session\":\"s\",\"target\":\"Wi-Fi\",\"verb\":\"set_toggle\",\"value\":\"on\"}",
            "← act {\"status\":\"acted_noop\"}",
            "→ act {\"session\":\"s\",\"target\":\"Sound\",\"verb\":\"set_toggle\",\"value\":\"off\"}",
            "← act {\"status\":\"found_acted\"}",
            "→ select {\"session\":\"s\",\"control\":\"Size\",\"item\":\"Large\"}",
            "← select {\"status\":\"found_acted\"}",
            "→ close_session {\"session\":\"s\"}", "← close_session {\"status\":\"closed\"}",
            "→ list_branches {}", "← list_branches {}",
        ]
        #expect(Self.done(lines) == [
            "Checked what is open", "Listed the open windows", "Listed the windows of Notes", "Opened Calculator",
            "Looked at the window", "Pressed 8", "Double-clicked Row in Files", "Right-clicked Item",
            "Turned on Wi-Fi", "Turned off Sound", "Chose Large in Size", "Closed Calculator", "list_branches",
        ])
    }

    @Test("A batch is its steps, answered one by one; steps a stopped batch never reached are not shown")
    func batchSteps() {
        let lines = [
            "→ batch {\"session\":\"s\",\"steps\":[{\"operation\":\"act\",\"target\":\"8\"},"
                + "{\"operation\":\"select\",\"control\":\"Size\",\"item\":\"Large\"},"
                + "{\"operation\":\"act\",\"target\":\"=\"}]}",
            "← batch step 1 {\"status\":\"found_acted\"}",
            "← batch step 2 {\"status\":\"honest_miss\",\"message\":\"No control named Size.\"}",
            "← batch {\"status\":\"stopped\"}",
        ]
        #expect(Self.done(lines) == ["Pressed 8", "Could not choose Large in Size: No control named Size."])
    }

    @Test("Repeats collapse, the summary names what changed, and read-only steps only when nothing else was done")
    func repeatsCollapse() {
        let observe = ["→ observe {\"session\":\"s\"}", "← observe {}"]
        let press   = ["→ act {\"session\":\"s\",\"target\":\"8\"}", "← act {\"status\":\"found_acted\"}"]
        let open    = ["→ open_session {\"app\":\"Calculator\"}", "← open_session {}"]
        let status  = ["→ status {}", "← status {}"]
        let steps   = ToolStep.steps(from: status + open + observe + observe + observe + press + press)

        #expect(TranscriptWording.toolSteps(steps, ending: .completed).map(\.text)
            == ["Checked what is open", "Opened Calculator", "Looked 3 times", "Pressed 8 twice"])
        #expect(TranscriptWording.toolSummary(steps, ending: .completed) == "Opened Calculator · pressed 8 twice")
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: observe + observe + observe), ending: .completed)
            == "Looked 3 times")

        let many = (0..<6).flatMap { ["→ act {\"session\":\"s\",\"target\":\"\($0)\"}", "← act {}"] }
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: many), ending: .completed)
            == "Pressed 0 · pressed 1 · pressed 2 · 3 more")
    }

    @Test("A failed step marks the line and, expanded, says what failed")
    func failureIsMarked() async throws {
        let lines = [
            "→ open_session {\"app\":\"Calculator\"}", "← open_session {}",
            "→ act {\"session\":\"s\",\"target\":\"8\"}",
            "← act error: The window closed. Observe before any retry.",
            "← push error: remote refused",
        ]
        let steps = ToolStep.steps(from: lines)
        #expect(TranscriptWording.toolSummary(steps, ending: .completed)
            == "Opened Calculator · could not press 8 · push failed")
        let expanded = TranscriptWording.toolSteps(steps, ending: .completed)
        #expect(expanded.map(\.isFailed) == [false, true, true])
        #expect(expanded[1].text == "Could not press 8: The window closed.")
        #expect(expanded[2].text == "push failed: remote refused")

        let item = TranscriptItem(id: .toolRun(UUID()),
                                  kind: .toolRun(lines: lines, isExpanded: false, ending: .completed),
                                  date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: true)
        let text = RowPreparation.preparedText(for: item, workerName: "Atlas", pipeline: MarkdownContent())
        #expect(text.blocks[0].runs.first?.role == .captionAlert)

        let quiet = TranscriptItem(id: .toolRun(UUID()),
                                   kind: .toolRun(lines: Array(lines.prefix(2)), isExpanded: false, ending: .completed),
                                   date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: true)
        let healthy = RowPreparation.preparedText(for: quiet, workerName: "Atlas", pipeline: MarkdownContent())
        #expect(!healthy.blocks.flatMap(\.runs).contains { $0.role == .captionAlert }, "marks only for problems")
        #expect(healthy.string == "⚙\u{FE0E} Opened Calculator ›")
    }

    @Test("Expanding the line keeps it and puts one line per step on a card under it; collapsing takes the card away")
    func expandAndCollapse() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn = UUID()
        try await fixture.say("Compute 8", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        try await fixture.record(.toolActivity, subject: turn, at: 2, text: "→ open_session {\"app\":\"Calculator\"}")
        try await fixture.record(.toolActivity, subject: turn, at: 3, text: "← open_session {}")
        try await fixture.record(.toolActivity, subject: turn, at: 4,
                                 text: "→ act {\"session\":\"s\",\"target\":\"8\"}")
        try await fixture.record(.toolActivity, subject: turn, at: 5, text: "← act {\"status\":\"found_acted\"}")
        try await fixture.say("8 is on the display.", at: 6, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 7)

        let folded = try await fixture.items()
        let line   = try #require(folded.last)
        let open   = try await fixture.items(expanded: [line.id])
        #expect(TranscriptUpdate(from: folded, to: open).changed == [line.id])

        let collapsedText = RowPreparation.preparedText(for: line, workerName: "Atlas", pipeline: MarkdownContent())
        let expandedText  = RowPreparation.preparedText(for: try #require(open.last), workerName: "Atlas",
                                                        pipeline: MarkdownContent())
        #expect(collapsedText.string == "⚙\u{FE0E} Opened Calculator · pressed 8 ›")
        #expect(expandedText.string == "⚙\u{FE0E} Opened Calculator · pressed 8 ›\nOpened Calculator\nPressed 8")
        #expect(expandedText.blocks.map(\.kind) == [.text, .toolSteps])
        #expect(expandedText.blocks[0].string == collapsedText.string)

        let closed = try await fixture.items(expanded: [])
        #expect(closed == folded)
        #expect(TranscriptWording.accessibilityLabel(for: try #require(open.last), workerName: "Atlas")
            .hasSuffix("Opened Calculator · pressed 8: Opened Calculator; Pressed 8"))
    }
}
