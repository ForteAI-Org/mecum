//
//  ToolLineTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// The tool line: records as `AutomationTools` writes them, read back as
/// short human phrases, repeats collapsed, a failure told neutrally and never marked.
@Suite("Tool line: phrases per tool, repeats, failures, expand and collapse")
struct ToolLineTests {

    @Test func unverifiedNativeMenuIsNotShownAsCompleted() {
        let steps = ToolStep.steps(from: [
            #"→ menu {"path":["Setup","I/O..."]}"#,
            #"← menu {"status":"acted_unverified","message":"The window was not verified"}"#
        ])
        #expect(steps.first?.action == .menu(path: ["Setup", "I/O..."]))
        #expect(steps.first?.state == .failed(reason: "The window was not verified"))
    }

    @Test func recentDocumentWithIntermediateDialogIsNotShownAsOpened() {
        let steps = ToolStep.steps(from: [
            #"→ open_recent {"app":"Synthetic Editor","path":["File","Open Recent","/Projects/Example.prproj"]}"#,
            #"← open_recent {"status":"acted_unverified","message":"Link Media needs attention","session":"fresh"}"#
        ])
        #expect(steps.first?.isEffectful == true)
        #expect(steps.first?.state == .failed(reason: "Link Media needs attention"))
        #expect(TranscriptWording.toolSteps(steps, ending: .completed) == ["Tried to open Synthetic Editor"])
    }

    private static func done(_ lines: [String]) -> [String] {
        TranscriptWording.toolSteps(ToolStep.steps(from: lines), ending: .completed)
    }

    /// The Slack turn: a look around, Slack opened, a message typed that did not land,
    /// Annulla missed then pressed, and the message typed again.
    static let slack = [
        "→ status {}", "← status {\"session\":null}",
        "→ windows {}", "← windows {\"applications\":[]}",
        "→ open_session {\"app\":\"Slack\"}", "← open_session {\"session\":\"s\"}",
        "» Typing the message now.",
        "→ type_text {\"session\":\"s\",\"target\":\"Messaggio a India • (Lista delle chat)\","
            + "\"text\":\"Ci vediamo alle 15?\"}",
        "← type_text {\"status\":\"acted_unverified\",\"message\":\"the field did NOT change\"}",
        "→ act {\"session\":\"s\",\"target\":\"Annulla\"}",
        "← act {\"status\":\"honest_miss\",\"message\":\"No control named Annulla on this screen.\"}",
        "→ act {\"session\":\"s\",\"target\":\"Annulla\"}", "← act {\"status\":\"found_acted\"}",
        "→ type_text {\"session\":\"s\",\"target\":\"Messaggio a India • (Lista delle chat)\","
            + "\"text\":\"Ci vediamo alle 15?\"}",
        "← type_text {\"status\":\"found_acted\"}",
    ]

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
            "Checked open apps", "Checked open windows", "Checked Notes’s open windows", "Opened Calculator",
            "Viewed the window", "Pressed 8", "Double-clicked Row in Files", "Right-clicked Item",
            "Turned on Wi-Fi", "Turned off Sound", "Selected Large in Size", "Closed Calculator", "list_branches",
        ])
    }

    @Test("Looking up apps reads as a lookup, of the query when there is one, and only looks")
    func appsPhrase() {
        let lines = [
            "→ apps {}", "← apps {\"applications\":[]}",
            "→ apps {\"query\":\"pro tools\"}", "← apps {\"applications\":[]}",
        ]
        #expect(Self.done(lines) == ["Looked up apps", "Looked up “pro tools”"])
        #expect(ToolStep.steps(from: lines).allSatisfy { !$0.isEffectful })
        #expect(TranscriptWording.toolSteps(
            ToolStep.steps(from: ["→ apps {\"query\":\"PT\"}"]),
            ending: nil
        ) == ["Looking up “PT”…"])
    }

    @Test("Typing, keys, scrolling, drags and contextual menus read as what a person would say")
    func inputToolPhrases() {
        let lines = [
            "→ type_text {\"session\":\"s\",\"target\":\"Project Name\",\"text\":\"Demo\"}",
            "← type_text {\"status\":\"found_acted\"}",
            "→ type_text {\"session\":\"s\",\"target\":\"Notes\",\"text\":\" more\",\"replace\":false}",
            "← type_text {\"status\":\"found_acted\"}",
            "→ press_key {\"session\":\"s\",\"key\":\"return\"}",
            "← press_key {\"status\":\"found_acted\"}",
            "→ press_key {\"session\":\"s\",\"key\":\"n\",\"modifiers\":[\"cmd\",\"shift\"]}",
            "← press_key {\"status\":\"found_acted\"}",
            "→ press_key {\"session\":\"s\",\"key\":\"down\",\"count\":3}",
            "← press_key {\"status\":\"found_acted\"}",
            "→ scroll {\"session\":\"s\",\"direction\":\"down\",\"target\":\"Media Pool\"}",
            "← scroll {\"status\":\"found_acted\"}",
            "→ scroll {\"session\":\"s\",\"direction\":\"up\"}",
            "← scroll {\"status\":\"found_acted\"}",
            "→ drag {\"session\":\"s\",\"from\":\"Clip\",\"to\":\"Timeline\"}",
            "← drag {\"status\":\"found_acted\"}",
            "→ context_menu {\"session\":\"s\",\"target\":\"Search\",\"item\":\"Select All\"}",
            "← context_menu {\"status\":\"found_acted\"}",
            "→ act {\"session\":\"s\",\"target\":\"Name\",\"verb\":\"triple_click\"}",
            "← act {\"status\":\"found_acted\"}",
        ]
        #expect(Self.done(lines) == [
            "Typed “Demo” into Project Name", "Added “ more” to Notes", "Pressed Return", "Pressed ⇧⌘N",
            "Pressed ↓ 3 times", "Scrolled down in Media Pool", "Scrolled up in the window", "Dragged Clip to Timeline",
            "Selected Select All from Search’s menu", "Triple-clicked Name",
        ])
    }

    @Test("Every input tool changes the app, and its unverified outcome reads as what was tried, without the reason")
    func inputToolOutcomes() {
        let lines = [
            "→ press_key {\"session\":\"s\",\"key\":\"tab\"}",
            "← press_key {\"status\":\"acted_unverified\",\"message\":\"the window did NOT change\"}",
            "→ type_text {\"session\":\"s\",\"target\":\"Name\",\"text\":\"Demo\"}",
            "← type_text {\"status\":\"refused\",\"message\":\"no field\"}",
            "→ context_menu {\"session\":\"s\",\"target\":\"Row\",\"item\":\"Copy\"}",
        ]
        let steps = ToolStep.steps(from: lines)
        #expect(steps.allSatisfy { $0.isEffectful })
        #expect(TranscriptWording.toolSteps(steps, ending: .completed) == [
            "Tried to press Tab",
            "Tried to type “Demo” into Name",
            "Selecting Copy from Row’s menu, did not finish",
        ])
        let drag = ToolStep.steps(from: ["→ drag {\"session\":\"s\",\"from\":\"Clip\",\"dx\":40}"])
        #expect(TranscriptWording.toolSummary(drag, ending: nil) == "Dragging Clip…")
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
        #expect(Self.done(lines) == ["Pressed 8", "Tried to select Large in Size"])
    }

    @Test("Repeats collapse, the summary names what changed, and read-only steps only when nothing else was done")
    func repeatsCollapse() {
        let observe = ["→ observe {\"session\":\"s\"}", "← observe {}"]
        let press   = ["→ act {\"session\":\"s\",\"target\":\"8\"}", "← act {\"status\":\"found_acted\"}"]
        let open    = ["→ open_session {\"app\":\"Calculator\"}", "← open_session {}"]
        let status  = ["→ status {}", "← status {}"]
        let steps   = ToolStep.steps(from: status + open + observe + observe + observe + press + press)

        #expect(TranscriptWording.toolSteps(steps, ending: .completed)
            == ["Checked open apps", "Opened Calculator", "Looked 3 times", "Pressed 8 twice"])
        #expect(TranscriptWording.toolSummary(steps, ending: .completed) == "Opened Calculator · pressed 8 twice")
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: observe + observe + observe), ending: .completed)
            == "Looked 3 times")

        let many = (0..<6).flatMap { ["→ act {\"session\":\"s\",\"target\":\"\($0)\"}", "← act {}"] }
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: many), ending: .completed)
            == "Pressed 0 · pressed 1 · 4 more")
    }

    @Test("The summary never names a failure or puts one first, and says Issue nowhere")
    func summaryLeavesFailuresOut() {
        let lines = [
            "→ act {\"session\":\"s\",\"target\":\"8\"}",
            "← act error: The window closed. Observe before any retry.",
            "→ open_session {\"app\":\"Calculator\"}", "← open_session {}",
            "← push error: remote refused",
            "→ act {\"session\":\"s\",\"target\":\"8\"}", "← act {\"status\":\"found_acted\"}",
        ]
        let summary = TranscriptWording.toolSummary(ToolStep.steps(from: lines), ending: .completed)
        #expect(summary == "Opened Calculator · pressed 8")
        #expect(!summary.contains("Issue") && !summary.contains("Tried") && !summary.contains("push"))

        let slack = TranscriptWording.toolSummary(ToolStep.steps(from: Self.slack), ending: .completed)
        #expect(slack == "Opened Slack · pressed Annulla · 1 more")
        #expect(!slack.contains("Issue") && !slack.contains("Tried"))
    }

    @Test("A turn that only failed is summarised by what it tried, neutrally")
    func onlyFailuresReadAsTried() {
        let tried = [
            "→ status {}", "← status {}",
            "→ act {\"session\":\"s\",\"target\":\"8\"}", "← act {\"status\":\"honest_miss\",\"message\":\"none\"}",
            "← push error: remote refused",
        ]
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: tried), ending: .failed)
            == "Tried to press 8 · tried to push")
        let looked = [
            "→ observe {\"session\":\"s\"}", "← observe error: the window closed",
            "→ status {}", "← status {}",
        ]
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: looked), ending: .completed)
            == "Checked open apps · tried to view the window")
    }

    @Test("A label a model chose is cut to 24 characters, in the summary and on the card")
    func labelsAreCut() {
        let lines = [
            "→ act {\"session\":\"s\",\"target\":\"India • (Lista delle chat)\",\"section\":\"content (Chat)\"}",
            "← act {\"status\":\"found_acted\"}",
            "→ type_text {\"session\":\"s\",\"target\":\"Messaggio a India • (Lista delle chat)\","
                + "\"text\":\"Ci vediamo domani alle quindici?\"}",
            "← type_text {\"status\":\"found_acted\"}",
        ]
        let steps = ToolStep.steps(from: lines)
        #expect(TranscriptWording.toolSteps(steps, ending: .completed) == [
            "Pressed India • (Lista delle ch…",
            "Typed “Ci vediamo domani alle…” into Messaggio a India • (Li…",
        ])
        #expect(TranscriptWording.toolSummary(steps, ending: .completed)
            == "Pressed India • (Lista delle ch… · typed “Ci vediamo domani alle…” into Messaggio a India • (Li…")
        #expect("India • (Lista delle ch…".count == TranscriptWording.labelLimit)
    }

    @Test("The card has one line per step: no reason, no note, a failed step reads as tried")
    func cardIsSteps() {
        let card = TranscriptWording.toolSteps(ToolStep.steps(from: Self.slack), ending: .completed)
        #expect(card == [
            "Checked open apps",
            "Checked open windows",
            "Opened Slack",
            "Tried to type “Ci vediamo alle 15?” into Messaggio a India • (Li…",
            "Tried to press Annulla",
            "Pressed Annulla",
            "Typed “Ci vediamo alle 15?” into Messaggio a India • (Li…",
        ])
        let hidden = ["NOT change", "No control", "Typing the message"]
        #expect(!card.contains { line in hidden.contains { line.contains($0) } }, "no reason and no note")

        let item = TranscriptItem(id: .toolRun(UUID()),
                                  kind: .toolRun(lines: Self.slack, isExpanded: true, ending: .completed),
                                  date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: false)
        let spoken = TranscriptWording.accessibilityLabel(for: item, workerName: "Atlas")
        #expect(spoken.hasSuffix("Opened Slack · pressed Annulla · 1 more: " + card.joined(separator: "; ")))
    }

    @Test("No tool line text uses an alert role or colour, and the summary stays on one line with room for its chevron")
    func quietStyles() async {
        let style = TranscriptStyle()
        let items = [false, true].map { isExpanded in
            TranscriptItem(id: .toolRun(UUID()),
                           kind: .toolRun(lines: Self.slack, isExpanded: isExpanded, ending: .failed),
                           date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: false)
        }
        let rows = await RowPreparation.prepare(items, workerName: "Atlas", width: 200, style: style,
                                                cache: LayoutMeasurementCache(), pipeline: MarkdownContent()).rows
        for row in rows {
            #expect(!row.text.string.contains("Issue") && !row.text.string.contains("Action"))
            for block in row.text.blocks {
                #expect(block.runs.allSatisfy { $0.role == .toolCaption })
                for run in block.runs {
                    let attributes = PreparedText.attributes(run, style)
                    #expect(attributes[.foregroundColor] as? NSColor == NSColor.secondaryLabelColor)
                    #expect((attributes[.font] as? NSFont)?.pointSize == style.toolPointSize)
                }
            }
            // One line however narrow the row, cut short rather than wrapped, the chevron's room after it.
            let summary = row.text.blocks[0].attributed(style)
            let cut     = RowPreparation.measure(summary, width: row.geometry.blockTexts[0].width)
            let whole   = RowPreparation.measure(summary, width: 10_000)
            #expect(cut.height == whole.height && cut.width < whole.width)
            #expect(row.geometry.blockTexts[0].height == whole.height)
            #expect(row.geometry.blocks[0].width == cut.width + RowGeometry.disclosureSide(style) + 4)
        }
        #expect(style.toolPointSize == style.captionPointSize - 1)
        #expect(TranscriptStyle(bodyPointSize: 20).toolPointSize > style.toolPointSize)
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
        let line   = try #require(folded.first { if case .toolRun = $0.kind { true } else { false } })
        let open   = try await fixture.items(expanded: [line.id])
        #expect(TranscriptUpdate(from: folded, to: open).changed == [line.id])

        let collapsedText = RowPreparation.preparedText(for: line, workerName: "Atlas", pipeline: MarkdownContent())
        let expandedText  = RowPreparation.preparedText(for: try #require(open.first { $0.id == line.id }),
                                                        workerName: "Atlas", pipeline: MarkdownContent())
        #expect(collapsedText.string == "Opened Calculator · pressed 8")
        #expect(expandedText.string == "Opened Calculator · pressed 8\nOpened Calculator\nPressed 8")
        #expect(expandedText.blocks.map(\.kind) == [.toolSummary, .toolSteps])
        #expect(expandedText.blocks[0].string == collapsedText.string)

        let closed = try await fixture.items(expanded: [])
        #expect(closed == folded)
        #expect(TranscriptWording.accessibilityLabel(for: try #require(open.first { $0.id == line.id }), workerName: "Atlas")
            .hasSuffix("Opened Calculator · pressed 8: Opened Calculator; Pressed 8"))
    }

    @Test("On screen the line sits apart from the person's message and close above the reply it opens")
    @MainActor
    func lineSitsWithItsReply() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn = UUID()
        try await fixture.say("Compute 8", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        try await fixture.record(.toolActivity, subject: turn, at: 2, text: "→ act {\"session\":\"s\",\"target\":\"8\"}")
        try await fixture.record(.toolActivity, subject: turn, at: 3, text: "← act {\"status\":\"found_acted\"}")
        try await fixture.say("8 is on the display.", at: 4, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 5)
        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()

        let items  = controller.rows.map(\.item)
        let index  = try #require(items.firstIndex { if case .toolRun = $0.kind { true } else { false } })
        let frames = controller.frameMap()
        let person = try #require(frames[items[index - 1].id])
        let line   = try #require(frames[items[index].id])
        let reply  = try #require(frames[items[index + 1].id])
        #expect(line.minY - person.maxY == TranscriptLayout.ordinarySpacing)
        #expect(reply.minY - line.maxY == TranscriptLayout.groupSpacing)
    }

    @Test("Opening uncovers the card as it fades in; closing folds a picture of it up and out")
    @MainActor
    func openAndFoldAnimate() throws {
        let cell      = TranscriptCell()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        container.addSubview(cell.view)
        let window = TranscriptFixture.offscreenWindow(for: container, size: container.frame.size)
        defer { window.close() }

        cell.view.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        cell.slide(from: 0, openingFrom: 20)
        let mask   = try #require(cell.view.layer?.mask)
        let opened = try #require(mask.sublayers?.last)
        #expect(mask.sublayers?.count == 2)
        #expect(opened.frame.height == 60)
        #expect(opened.animation(forKey: "open") != nil)

        cell.view.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let card = NSImage(size: CGSize(width: 300, height: 60))
        cell.fold(card)
        let overlay = try #require(cell.view.subviews.compactMap { $0 as? NSImageView }.first { $0.image === card })
        #expect(overlay.frame == CGRect(x: 0, y: 20, width: 300, height: 60), "just under the row's new bottom edge")
        #expect(overlay.layer?.mask?.animation(forKey: "fold") != nil)
        cell.prepareForReuse()
        #expect(overlay.superview == nil, "a reused cell keeps nothing of the fold")
    }

    /// Claude Code's recorded turn: a note, then a page read and a search at once, as `WebToolRecords` writes them.
    static let web = [
        "» I'll check the official Swift site.",
        #"→ web_fetch {"url":"https://www.swift.org/install/"}"#,
        #"→ web_search {"query":"latest stable Swift version release swift.org 2026"}"#,
        "← web_fetch done",
        "← web_search done",
    ]

    @Test("A web search and a page read only look: named by query and by site, the search's query said once done")
    func webPhrases() {
        let steps = ToolStep.steps(from: Self.web)
        #expect(steps.allSatisfy { !$0.isEffectful })
        #expect(Self.done(Self.web) == ["Read swift.org", "Searched the web for “latest stable Swift ver…”"])
        #expect(TranscriptWording.toolSummary(steps, ending: .completed)
                == "Read swift.org · searched the web for “latest stable Swift ver…”")

        let running = ToolStep.steps(from: Array(Self.web.prefix(3)))
        #expect(TranscriptWording.toolSteps(running, ending: nil) == ["Reading swift.org…", "Searching the web…"])
        #expect(TranscriptWording.toolSummary(running, ending: nil) == "Reading swift.org… · searching the web…")
        #expect(TranscriptWording.toolSteps(running, ending: .stopped)
                == ["Reading swift.org, stopped", "Searching the web, stopped"])

        // Codex's recorded turn only searched, so its line names the search.
        let codex = [
            #"→ web_search {"query":"site:swift.org/download latest stable Swift release September 2026"}"#,
            "← web_search done",
        ]
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: codex), ending: .completed)
                == "Searched the web for “site:swift.org/download…”")
        #expect(Self.done(["→ web_fetch {\"url\":\"http://example.com/a\"}", "← web_fetch done"])
                == ["Read example.com"])
        #expect(Self.done(["→ web_search {}", "← web_search done"]) == ["Searched the web"])
    }

    @Test("A failed search or read says what was tried, and a turn that also acted names only the action")
    func webFailuresAndActions() {
        let failed = [
            #"→ web_search {"query":"swift 7 release date"}"#,
            "← web_search error: The web tool reported a failure.",
            #"→ web_fetch {"url":"https://www.swift.org/install/"}"#,
            "← web_fetch error: The web tool reported a failure.",
        ]
        #expect(Self.done(failed) == [
            "Tried to search the web for “swift 7 release date”",
            "Tried to read swift.org",
        ])
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: failed), ending: .completed)
                == "Tried to search the web for “swift 7 release date” · tried to read swift.org")

        let acted = Self.web + [
            "→ act {\"session\":\"s\",\"target\":\"Send\"}",
            "← act {\"status\":\"found_acted\"}",
        ]
        #expect(TranscriptWording.toolSummary(ToolStep.steps(from: acted), ending: .completed) == "Pressed Send")
    }
}
