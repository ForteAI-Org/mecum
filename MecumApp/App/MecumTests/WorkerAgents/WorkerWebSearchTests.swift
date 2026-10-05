//
//  WorkerWebSearchTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import Foundation
import Testing
@testable import Mecum

/// A worker searching the web, as the app shows it: the records the turn core writes for a command
/// line's searches and page reads (`WebToolRecordsTests`, in the package) read as the transcript's
/// steps, and the setting that lets a worker search is on by default.
@MainActor
@Suite("A worker searching the web")
struct WorkerWebSearchTests {

    /// The records of Claude Code's recorded turn, as the turn core writes them: a page read and a search
    /// at once, then their results.
    @Test func claudesRecordsReadAsAReadAndASearch() {
        let lines = [
            #"→ web_fetch {"url":"https://www.swift.org/install/"}"#,
            #"→ web_search {"query":"latest stable Swift version release swift.org 2026"}"#,
            "← web_fetch done",
            "← web_search done",
        ]
        #expect(TranscriptWording.toolSteps(
            ToolStep.steps(from: lines),
            ending: .completed
        ) == ["Read swift.org", "Searched the web for “latest stable Swift ver…”"])
    }

    /// A Codex query that is an address was a page read, and reads as one.
    @Test func aCodexQueryThatIsAnAddressReadsAsThePage() {
        let lines = [
            #"→ web_fetch {"url":"https://www.swift.org/blog/swift-6.4-released/"}"#,
            "← web_fetch done",
        ]
        let steps = ToolStep.steps(from: lines)
        #expect(TranscriptWording.toolSteps(steps, ending: .completed) == ["Read swift.org"])
        #expect(TranscriptWording.toolSummary(steps, ending: .completed) == "Read swift.org")
    }

    @Test func theSettingIsOnByDefault() throws {
        #expect(AppPreferences.workersSearchWebDefault)
        let suite    = "mecum-web-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppPreferences.bool(
            AppPreferences.workersSearchWeb,
            default: AppPreferences.workersSearchWebDefault,
            in     : defaults
        ))
    }
}
