//
//  BrowserOpeningTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import SeatBroker

/// `AgentSession.open` has no seam short of the window server, so the decision it takes is tested
/// here as the pure function it calls; the press and the wait are the live check's.
@MainActor
@Suite("A running browser's own window")
struct BrowserOpeningTests {

    @Test("only a running browser with no window named is given a window of its own")
    func onlyARunningBrowserWithNoTitleOpensANewWindow() {
        #expect(BrowserOpening.opensNewWindow(wasRunning: true, windowTitled: nil, isBrowser: true))
        #expect(!BrowserOpening.opensNewWindow(wasRunning: true, windowTitled: nil, isBrowser: false),
                "a running application that is no browser has its main window adopted")
        #expect(!BrowserOpening.opensNewWindow(wasRunning: false, windowTitled: nil, isBrowser: true),
                "a browser this open launches has no window of the person's")
        #expect(!BrowserOpening.opensNewWindow(wasRunning: true, windowTitled: "Inbox", isBrowser: true),
                "a window named explicitly is the one taken")
    }

    @Test("the new window is one the browser did not have before the press")
    func theNewWindowIsNoneOfTheOnesListedBefore() {
        func window(_ number: Int) -> TargetWindow {
            TargetWindow(pid: 7, windowNumber: number, title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let shown = [window(10), window(12), window(11)]
        #expect(BrowserOpening.newWindow(among: shown, before: [10, 11])?.windowNumber == 12)
        #expect(BrowserOpening.newWindow(among: shown, before: [10, 11, 12]) == nil)
        #expect(BrowserOpening.newWindow(among: [], before: []) == nil)
    }

    @Test("a browser that got no window of its own is refused, saying the person's windows were left alone")
    func theRefusalSaysNothingWasTaken() {
        let sentence = BrowserOpening.refusal("Browser", "No enabled item of its menu bar opens a new window.")
            .localizedDescription
        #expect(sentence.hasPrefix("Browser could not be given a window of its own: No enabled item"))
        #expect(sentence.contains("none of the person's Browser windows was taken"))
    }

    /// The order of what one `seat` run called, shared by its steps and the scripted comeback.
    final class Log {
        var lines: [String] = []
    }

    /// A comeback over scripted readings of the front: every `restore` is logged, and the person's
    /// application reads in front as `inFront` says, one reading each, its last reading repeated.
    @MainActor
    final class ScriptedComeback: FrontRestoring {
        let log    : Log
        var inFront: [Bool]

        init(log: Log, inFront: [Bool]) {
            self.log     = log
            self.inFront = inFront
        }

        func restore(ifTakenBy pid: pid_t) { log.lines.append("restore \(pid)") }

        var isPersonsApplicationInFront: Bool {
            let reading = inFront.first ?? false
            if inFront.count > 1 { inFront.removeFirst() }
            return reading
        }
    }

    static let window = TargetWindow(pid: 7, windowNumber: 85197, title: "",
                                     frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    /// One `seat` over scripted steps: what it called, in order, and the refusal it threw. `inFront`
    /// arms a comeback reading the front that way, nil arms none; the wait takes `waitReadings`.
    private func seat(
        prepareFails: (any Error)? = nil,
        inFront     : [Bool]?      = nil,
        waitReadings: Int          = 2,
        useFails    : Bool         = false,
        closes      : Bool         = true
    ) async -> (calls: [String], refusal: String?, error: (any Error)?) {

        let app = TargetApp(pid: 7, bundleID: "com.example.Browser", name: "Browser", bundleURL: nil, windows: [])
        let log = Log()
        do {
            _ = try await BrowserOpening.seat(
                app,
                prepare     : {
                    log.lines.append("prepare")
                    if let prepareFails { throw prepareFails }
                },
                arm         : {
                    log.lines.append("arm")
                    return inFront.map { ScriptedComeback(log: log, inFront: $0) }
                },
                open        : { tick in
                    log.lines.append("press")
                    for _ in 0..<waitReadings { tick() }
                    return BrowserOpening.OpenedWindow(window: Self.window, element: nil)
                },
                use         : { adopted in
                    log.lines.append("use \(adopted.window.windowNumber)")
                    if useFails { throw SeatBrokerError.driver("The host failed.") }
                    return app
                },
                close       : { opened in
                    log.lines.append("close \(opened.window.windowNumber)")
                    return closes
                },
                tailInterval: .zero
            )
            return (log.lines, nil, nil)
        } catch {
            return (log.lines, error.localizedDescription, error)
        }
    }

    @Test("a seat that cannot be made ready refuses before the new window is asked for")
    func aSeatThatIsNotReadyPressesNothing() async {
        let run = await seat(prepareFails: SeatBrokerError.driver("The background display is held."), inFront: [true])
        #expect(run.calls == ["prepare"])
        #expect(run.refusal?.contains("The seat could not be made ready, so nothing was pressed: "
            + "The background display is held.") == true)
        let cancelled = await seat(prepareFails: CancellationError())
        #expect(cancelled.calls == ["prepare"])
        #expect(cancelled.error is CancellationError, "a cancellation stays a cancellation")
    }

    @Test("the window is asked for only once the seat is ready, and a seated window is not closed")
    func theSeatComesFirstAndASeatedWindowStaysOpen() async {
        let run = await seat()
        #expect(run.calls == ["prepare", "arm", "press", "use 85197"],
                "with nothing armed, nothing gives the front back")
        #expect(run.refusal == nil)
    }

    @Test("the person's window is read before the press, and the front is given back in the wait and after it")
    func theFrontIsGivenBackDuringTheWaitAndAfterTheAdoption() async {
        let run = await seat(inFront: [false, true, true])
        #expect(run.calls == ["prepare", "arm", "press", "restore 7", "restore 7", "use 85197",
                              "restore 7", "restore 7", "restore 7"])
        #expect(run.refusal == nil)
    }

    @Test("after the adoption the front is watched until the person holds it twice in a row, a second at most")
    func theTailEndsOnTwoReadingsInARowAndIsBounded() async {
        func tail(_ inFront: [Bool]) async -> Int {
            await seat(inFront: inFront, waitReadings: 0).calls.drop { $0 != "use 85197" }.dropFirst().count
        }
        #expect(await tail([true, true]) == 2)
        #expect(await tail([true, false, true, true]) == 4, "two readings in a row, not two in all")
        #expect(await tail([false]) == BrowserOpening.frontTailReadings)
    }

    @Test("a new window the seat could not take is closed again, and a refusal says when it could not be")
    func aWindowThatWasNotSeatedIsClosed() async {
        let closed = await seat(inFront: [true, true], useFails: true)
        #expect(closed.calls == ["prepare", "arm", "press", "restore 7", "restore 7", "use 85197", "close 85197",
                                 "restore 7", "restore 7"])
        #expect(closed.refusal?.contains("The host failed.") == true)
        #expect(closed.refusal?.hasSuffix("The new window it opened for the seat was closed again.") == true)

        let left = await seat(useFails: true, closes: false)
        #expect(left.calls == ["prepare", "arm", "press", "use 85197", "close 85197"])
        #expect(left.refusal?.hasSuffix("A new empty window of Browser was left open on the person's screen: "
            + "close it by hand.") == true)
    }

    @Test("a window with no accessibility element is not closed, since nothing names it")
    func aWindowWithNoElementIsNotClosed() async {
        #expect(await BrowserOpening.close(BrowserOpening.OpenedWindow(window: Self.window, element: nil)) == false)
    }

    @Test("the wait runs its tick before every reading and keeps the window it found first")
    func theWaitTicksBeforeEveryReading() async throws {
        let element = AXUIElementCreateApplication(getpid())
        let other   = TargetWindow(pid: 7, windowNumber: 85198, title: "", frame: Self.window.frame)
        var ticks   = 0
        var finds   = [nil, Self.window, other]
        var answers = [nil, element]
        let opened = try await BrowserOpening.awaitWindow(
            within  : .seconds(5),
            interval: .zero,
            tick    : { ticks += 1 },
            find    : { finds.removeFirst() },
            element : { _ in answers.removeFirst() }
        )
        #expect(ticks == 3)
        #expect(opened?.window.windowNumber == 85197)
        #expect(opened?.element != nil)

        var lateTicks = 0
        let late = try await BrowserOpening.awaitWindow(within: .zero, tick: { lateTicks += 1 },
                                                        find: { Self.window }, element: { _ in nil })
        #expect(lateTicks == 1)
        #expect(late?.window.windowNumber == 85197 && late?.element == nil, "found without its element in time")
        #expect(try await BrowserOpening.awaitWindow(within: .zero, tick: {}, find: { nil }, element: { _ in nil })
            == nil)
    }
}
