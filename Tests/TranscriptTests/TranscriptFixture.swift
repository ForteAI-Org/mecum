//
//  TranscriptFixture.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
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

    /// A worker reply with every block kind the content pipeline renders.
    static let richReply = """
        # Release notes

        The build is **green** again, and the `capture` suite passes on the *second* try. \
        Read [the checklist](https://example.com/release/checklist) before tagging.

        ## What changed

        1. The sidebar layout
           - fixed the width assertion from yesterday
           - kept the old *minimum* width
        2. The capture suite
           - retries once on the virtual display

        > A flaky test is a bug in the test until it is shown otherwise.

        ---

        ```swift
        struct ReleaseCheck {
            let suites: [String]
            let retries: Int

            func run(_ suite: String) async throws -> Bool {
                for attempt in 0...retries {
                    let passed = try await launch(suite, attempt: attempt)
                    if passed { return true }
                    print("retrying \\(suite), attempt \\(attempt + 1) of \\(retries + 1), after a failure that looked flaky")
                }
                return false
            }

            func launch(_ suite: String, attempt: Int) async throws -> Bool {
                try await Task.sleep(for: .milliseconds(10))
                return attempt > 0 || suite != "capture"
            }
        }
        ```

        | Suite | Result | Time |
        |:--|:-:|--:|
        | Layout | passed | 12.4 s |
        | Capture | passed after one retry on the virtual display | 48.0 s |
        | Transcript | passed | 3.1 s |

        Raw HTML stays text: <b>not bold</b> <script>alert(1)</script>
        """

    /// A borderless window that is never ordered in, holding `view` at `size`.
    /// The collection view tiles and recycles its cells on scroll only inside
    /// a window; bare, it keeps the cells it made first.
    @MainActor
    static func offscreenWindow(for view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Every row but the day separators, for a test about something else.
    static func withoutDays(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { if case .daySeparator = $0.kind { false } else { true } }
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

    /// A Gregorian calendar in `zone`, so day boundaries do not depend on the machine running the tests.
    static func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.locale   = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// The whole conversation as the transcript would project it.
    /// Projected at `now`, by default long after every fixture time, in UTC.
    func items(
        expanded  : Set<TranscriptItem.ID> = [],
        eventLimit: Int = TranscriptWindow.defaultEventLimit,
        now       : Date = TranscriptFixture.at(100_000),
        calendar  : Calendar = TranscriptFixture.calendar()
    ) async throws -> [TranscriptItem] {
        let window = try await TranscriptWindow.opening(conversation, around: nil, from: store,
                                                        eventLimit: eventLimit)
        return ConversationProjection.items(messages: window.messages, events: window.events,
                                            expanded: expanded, elidedBefore: window.elidedBefore, now: now,
                                            calendar: calendar)
    }
}
