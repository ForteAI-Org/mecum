//
//  RichContentTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Synchronization
import Testing
@testable import Transcript
import Workspace

/// The Markdown content pipeline, measured by what it prepares: block kinds,
/// what it refuses to interpret or load, and how much work an update costs.
@Suite("Rich content: Markdown blocks, safety and incremental preparation", .serialized)
struct RichContentTests {

    private static func reply(_ text: String) -> TranscriptItem {
        TranscriptItem(id: .message(UUID()), kind: .workerReply(text: text, isInterrupted: false),
                       date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: false)
    }

    @Test("Every block kind renders: headings, nested lists, a quote, a rule, a code block and a table")
    func everyBlockKind() throws {
        let text   = MarkdownContent().prepare(TranscriptFixture.richReply, isOnAccent: false)
        let kinds  = text.blocks.map(\.kind)
        #expect(kinds.contains(.heading(level: 1)))
        #expect(kinds.contains(.heading(level: 2)))
        #expect(kinds.contains(.quote))
        #expect(kinds.contains(.rule))
        #expect(kinds.contains(.code(language: "swift", isComplete: true)))
        #expect(kinds.contains { if case .table = $0 { true } else { false } })

        let list = try #require(text.blocks.first { $0.string.hasPrefix("1.\t") })
        #expect(list.string.contains("\n◦\tfixed the width assertion"))
        #expect(list.runs.contains { $0.indent == 2 && $0.hangs })

        let paragraph = text.blocks.first { $0.string.hasPrefix("The build is green") }
        #expect(paragraph?.runs.contains { $0.role == .code } == true)
        #expect(paragraph?.runs.contains { $0.traits.contains(.bold) } == true)
        #expect(paragraph?.runs.contains { $0.traits.contains(.italic) } == true)

        guard case .table(let table)? = text.blocks.first(where: {
            if case .table = $0.kind { true } else { false }
        })?.kind else {
            Issue.record("no table")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.cells.count == 12)

        let code = text.blocks.first { $0.isCompleteCode }
        #expect(code?.string.hasPrefix("struct ReleaseCheck {") == true)
        #expect(code?.string.hasSuffix("}") == true)
    }

    @Test("Raw HTML, inline and as a block, stays the characters the model sent")
    func htmlStaysText() {
        let source = "Inline <b>bold</b> and <script>alert(1)</script>.\n\n<div onclick=\"x()\">\nblock\n</div>"
        let text   = MarkdownContent().prepare(source, isOnAccent: false)
        #expect(text.string.contains("<b>bold</b>"))
        #expect(text.string.contains("<script>alert(1)</script>"))
        #expect(text.string.contains("<div onclick=\"x()\">"))
        #expect(text.blocks.allSatisfy { block in block.runs.allSatisfy { !$0.traits.contains(.bold) } })
    }

    @Test("An image is its alt text and destination, a link shows where it goes, and nothing is fetched")
    func nothingIsFetched() async throws {
        RecordingProtocol.reset()
        #expect(URLProtocol.registerClass(RecordingProtocol.self))
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }

        let source = """
            Look: ![the diagram](https://example.invalid/diagram.png) and [the docs](https://example.invalid/docs), \
            or <https://example.invalid/raw>.
            """
        let pipeline = MarkdownContent()
        let prepared = await RowPreparation.prepare([Self.reply(source)], workerName: "Atlas", width: 600,
                                                    style: TranscriptStyle(), cache: LayoutMeasurementCache(),
                                                    pipeline: pipeline)
        let text = prepared.rows[0].text
        #expect(text.string == "Look: the diagram (example.invalid/diagram.png) and the docs "
            + "(example.invalid/docs), or https://example.invalid/raw.")

        let attributed = text.blocks[0].attributed(TranscriptStyle())
        var carriesLoadable = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
            if attributes[.attachment] != nil || attributes[.link] != nil { carriesLoadable = true }
        }
        #expect(!carriesLoadable)
        #expect(RecordingProtocol.requests == 0)

        // A model's link is an ordinary link: the link role and its destination, no other mark.
        let roles = Set(text.blocks[0].runs.filter { $0.link != nil }.map(\.role))
        #expect(roles == [.link, .destination])
    }

    @Test("A link opens only as a web or mail link, and only as a row action")
    func linkPolicy() {
        #expect(RowAction.openableURL("https://swift.org") != nil)
        #expect(RowAction.openableURL("mailto:team@example.com") != nil)
        #expect(RowAction.openableURL("javascript:alert(1)") == nil)
        #expect(RowAction.openableURL("file:///etc/passwd") == nil)
        #expect(RowAction.openableURL("mecum://settings") == nil)

        let text    = MarkdownContent().prepare(TranscriptFixture.richReply, isOnAccent: false)
        let actions = RowAction.actions(in: text)
        #expect(actions.count == 2)
        guard case .openLink(let destination, _, _) = actions[0], case .copyBlock = actions[1] else {
            Issue.record("unexpected actions \(actions)")
            return
        }
        #expect(destination == "https://example.com/release/checklist")
    }

    @Test("Appending to a message prepares only its last block, and stable blocks keep their identity")
    func appendReusesBlocks() {
        let pipeline = MarkdownContent()
        let first    = "# Plan\n\nThe first paragraph stays.\n\nThe second one is still"
        let before   = pipeline.prepare(first, isOnAccent: false)
        #expect(pipeline.preparedBlockCount == 3)

        let grown = pipeline.prepare(first + " being written", isOnAccent: false)
        #expect(pipeline.preparedBlockCount == 4)
        #expect(Array(grown.blocks.prefix(2)) == Array(before.blocks.prefix(2)))
        #expect(grown.blocks[2].id == before.blocks[2].id)

        let longer = pipeline.prepare(first + " being written.\n\nA third.", isOnAccent: false)
        #expect(pipeline.preparedBlockCount == 6)
        #expect(Array(longer.blocks.prefix(2)) == Array(before.blocks.prefix(2)))
    }

    @Test("An unclosed fence costs work for its new lines only, and closing it parses it once")
    func unclosedFenceIsCheap() {
        let pipeline = MarkdownContent()
        let lines    = (0..<3000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        var source   = "Here is the file:\n\n```swift\n" + lines
        let open     = pipeline.prepare(source, isOnAccent: false)
        let groups   = 3000 / MarkdownContent.provisionalLines
        #expect(pipeline.preparedBlockCount == 1 + groups)
        #expect(open.blocks.dropFirst().allSatisfy { $0.kind == .code(language: "swift", isComplete: false) })

        for token in [" // one", " more", "\nlet next = 1", " + 2"] {
            let spent = pipeline.preparedBlockCount
            source += token
            _ = pipeline.prepare(source, isOnAccent: false)
            #expect(pipeline.preparedBlockCount - spent == 1)
        }

        let spent  = pipeline.preparedBlockCount
        let closed = pipeline.prepare(source + "\n```", isOnAccent: false)
        #expect(pipeline.preparedBlockCount - spent == 1)
        #expect(closed.blocks.count == 2)
        #expect(closed.blocks[1].kind == .code(language: "swift", isComplete: true))
        #expect(closed.blocks[0] == open.blocks[0])
    }

    @Test("The measurement cache hits and misses by block, width and text size")
    func cachePerBlock() async {
        let pipeline = MarkdownContent()
        let style    = TranscriptStyle(bodyPointSize: 14)
        let source   = "# Heading\n\nA paragraph of prose.\n\n```sh\nmake test\n```"
        let item     = Self.reply(source)
        func prepare(_ item: TranscriptItem, width: CGFloat, style: TranscriptStyle,
                     cache: LayoutMeasurementCache) async -> RowPreparation.Result {
            await RowPreparation.prepare([item], workerName: "Atlas", width: width, style: style, cache: cache,
                                         pipeline: pipeline)
        }

        let first = await prepare(item, width: 600, style: style, cache: LayoutMeasurementCache())
        #expect(first.rows[0].text.blocks.count == 3)
        #expect(first.measured.count == 3)
        var cache = LayoutMeasurementCache()
        cache.merge(first.measured)

        #expect(await prepare(item, width: 600, style: style, cache: cache).measured.isEmpty)

        let grown = Self.reply(source + "\n\nOne more line.")
        #expect(await prepare(grown, width: 600, style: style, cache: cache).measured.count == 1)

        #expect(await prepare(item, width: 900, style: style, cache: cache).measured.count == 3)
        let larger = await prepare(item, width: 600, style: TranscriptStyle(bodyPointSize: 20), cache: cache)
        #expect(larger.measured.count == 3)
        #expect(larger.rows[0].geometry.height > first.rows[0].geometry.height)
    }

    @Test("Code gets a wider surface than prose, and prose keeps its readable measure")
    func codeIsWiderThanProse() async {
        let long   = String(repeating: "wide_identifier_", count: 12)
        let source = "A short line of prose.\n\n```\n\(long)\n```"
        let rows   = await RowPreparation.prepare([Self.reply(source)], workerName: "Atlas", width: 1400,
                                                  style: TranscriptStyle(), cache: LayoutMeasurementCache(),
                                                  pipeline: MarkdownContent()).rows
        let geometry = rows[0].geometry
        let prose = RowGeometry.textWidthLimit(for: rows[0].item.kind, rowWidth: 1400, style: TranscriptStyle())
        #expect(geometry.blockTexts[0].width == prose.rounded(.down))
        #expect(geometry.blocks[1].width > prose)
        #expect(geometry.surface.width <= TranscriptStyle().wideMeasure)
    }

    @Test("Headings are headings, code is named as code, and Copy block is a VoiceOver action")
    @MainActor
    func accessibility() async {
        let prepared = await RowPreparation.prepare([Self.reply(TranscriptFixture.richReply)], workerName: "Atlas",
                                                    width: 700, style: TranscriptStyle(),
                                                    cache: LayoutMeasurementCache(), pipeline: MarkdownContent())
        let view = TranscriptRowView()
        view.configure(prepared.rows[0], style: TranscriptStyle(), workerName: "Atlas", avatar: nil, selection: nil)

        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        #expect(children.filter { $0.accessibilityRole() == .headingRole }.map { $0.accessibilityLabel() }
            == ["Release notes", "What changed"])
        #expect(children.contains { $0.accessibilityLabel() == "Code block, swift" })
        let actions = (view.accessibilityCustomActions() ?? []).map(\.name)
        #expect(actions.contains("Copy swift code block"))
        #expect(actions.contains("Open link to example.com/release/checklist"))
        #expect(view.accessibilityLabel()?.contains("**") == false)
    }

    @Test("A row view shown again as its reply grows lays out only the changed block")
    @MainActor
    func rowViewReusesStacks() async {
        let pipeline = MarkdownContent()
        let id       = TranscriptItem.ID.message(UUID())
        func row(_ text: String) async -> PreparedRow {
            let item = TranscriptItem(id: id, kind: .workerReply(text: text, isInterrupted: false),
                                      date: TranscriptFixture.origin, authorWorkerID: UUID(), continuesGroup: false)
            return await RowPreparation.prepare([item], workerName: "Atlas", width: 700, style: TranscriptStyle(),
                                                cache: LayoutMeasurementCache(), pipeline: pipeline).rows[0]
        }
        let view   = TranscriptRowView()
        let source = "# Heading\n\nA stable paragraph.\n\nStill"
        view.configure(await row(source), style: TranscriptStyle(), workerName: "Atlas", avatar: nil, selection: nil)
        let before = view.stacks.map { $0?.1 }
        view.configure(await row(source + " growing"), style: TranscriptStyle(), workerName: "Atlas", avatar: nil,
                       selection: nil)
        let after = view.stacks.map { $0?.1 }
        #expect(after[0] === before[0])
        #expect(after[1] === before[1])
        #expect(after[2] !== before[2])
    }

    @Test("The flush waits 40 ms, stretches under a slow apply, and comes back")
    func flushCadence() {
        var cadence = FlushCadence()
        #expect(cadence.interval == .milliseconds(40))
        cadence.record(applyDuration: .milliseconds(30))
        #expect(cadence.interval == .milliseconds(120))
        cadence.record(applyDuration: .seconds(2))
        #expect(cadence.interval == FlushCadence.ceiling)
        cadence.record(applyDuration: .milliseconds(1))
        #expect(cadence.interval == .milliseconds(40))
    }
}

/// RecordingProtocol answers every URL request made through the loading
/// system in this process, counting it and failing it, so a test sees a
/// fetch without any network.
final class RecordingProtocol: URLProtocol {

    private static let count = Mutex(0)

    static var requests: Int { count.withLock { $0 } }

    static func reset() { count.withLock { $0 = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        count.withLock { $0 += 1 }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
