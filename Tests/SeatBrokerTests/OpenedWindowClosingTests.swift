//
//  OpenedWindowClosingTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import Testing
@testable import SeatBroker

/// The browser window `AgentSession.open` made is closed when the session finishes with the
/// browser, before the seat releases it, and nothing else is. The press and the window server are
/// replaced by the session's two seams; whether a real browser closes is the live check's.
@MainActor
@Suite("Closing the window the session opened")
struct OpenedWindowClosingTests {

    private final class Log {
        var lines: [String] = []
    }

    private static let window = TargetWindow(pid: 7, windowNumber: 85197, title: "",
                                             frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    private static let identity = WindowIdentity(
        process          : ProcessIdentity(processID: 7, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber     : 85197,
        ownerConnectionID: 3
    )

    private static let record = AgentSession.OpenedWindowRecord(
        opened  : BrowserOpening.OpenedWindow(window: window, element: nil),
        identity: identity
    )

    /// Closes a session holding a browser with `record`, and answers what it called and said.
    private func finish(
        record  : AgentSession.OpenedWindowRecord?,
        isThere : Bool = true,
        closes  : Bool = true
    ) async -> (calls: [String], sentence: String?) {

        let log     = Log()
        let session = SeatBroker().openSession()
        session.isWindowPresent = { identity in
            log.lines.append("present \(identity.windowNumber)")
            return isThere
        }
        session.closeWindow = { opened in
            log.lines.append("close \(opened.window.windowNumber)")
            return closes
        }
        session.holdWithoutAdopting(getpid(), name: "Browser", openedWindow: record)
        let sentence = await session.close()
        return (log.lines, sentence)
    }

    @Test("the window the session opened is closed once, and nothing is said")
    func theOpenedWindowIsClosed() async {
        let run = await finish(record: Self.record)
        #expect(run.calls == ["present 85197", "close 85197"])
        #expect(run.sentence == nil)
    }

    @Test("with no window opened by the session, as for another application or a titled window, nothing is closed")
    func nothingIsClosedWithoutAnOpenedWindow() async {
        let run = await finish(record: nil)
        #expect(run.calls.isEmpty)
        #expect(run.sentence == nil)
    }

    @Test("a window that is no longer there with that identity is not closed")
    func aWindowThatIsGoneIsNotClosed() async {
        let run = await finish(record: Self.record, isThere: false)
        #expect(run.calls == ["present 85197"])
        #expect(run.sentence == nil)
    }

    @Test("a close that did not succeed is reported once and never retried")
    func aFailedCloseIsReportedAndNotRetried() async {
        let run = await finish(record: Self.record, closes: false)
        #expect(run.calls == ["present 85197", "close 85197"])
        #expect(run.sentence == "The new Browser window opened for this session could not be closed, "
            + "so it was returned to your desktop still open.")
    }

    @Test("the close happens before the release, and a failed one still releases")
    func theCloseComesBeforeTheRelease() async {
        func run(isThere: Bool, closes: Bool) async -> (order: [String], leftOpen: Bool) {
            let log = Log()
            let leftOpen = await AgentSession.closingThenReleasing(
                Self.record,
                isPresent: { _ in log.lines.append("present"); return isThere },
                close    : { _ in log.lines.append("close"); return closes },
                release  : { log.lines.append("release") }
            )
            return (log.lines, leftOpen)
        }
        let closed = await run(isThere: true, closes: true)
        #expect(closed.order == ["present", "close", "release"])
        #expect(!closed.leftOpen)
        let failed = await run(isThere: true, closes: false)
        #expect(failed.order == ["present", "close", "release"])
        #expect(failed.leftOpen)
        let gone = await run(isThere: false, closes: true)
        #expect(gone.order == ["present", "release"])
        #expect(!gone.leftOpen)
        let none = await AgentSession.closingThenReleasing(nil, isPresent: { _ in true },
                                                           close: { _ in true }, release: {})
        #expect(!none)
    }
}
