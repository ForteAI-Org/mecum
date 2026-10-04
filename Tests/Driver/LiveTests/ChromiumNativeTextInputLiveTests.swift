//
//  ChromiumNativeTextInputLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/10/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import TargetReader

/// ChromiumNativeTextInputLiveTests requires browser composition events and the exact
/// committed value after physical key positions. The fixture never dispatches
/// composition events or inserts the expected character itself.
@MainActor
struct ChromiumNativeTextInputLiveTests {

    private enum Flow {
        case commit, deadline, cancellation
    }

    static let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>ASIME</title></head>
        <body style="margin:0;background:#123">
        <textarea id="field" style="position:fixed;inset:0;border:0;background:#123;color:#fff"></textarea>
        <script>
        const field=document.getElementById('field');
        let starts=0,updates=0,ends=0,preedit='';
        const report=()=>document.title=`ASIME s=${starts} u=${updates} e=${ends} p=${encodeURIComponent(preedit)} v=${encodeURIComponent(field.value)}`;
        field.addEventListener('compositionstart',()=>{starts++;report();});
        field.addEventListener('compositionupdate',event=>{updates++;preedit=event.data;report();});
        field.addEventListener('compositionend',()=>{ends++;preedit='';report();});
        field.addEventListener('input',report);
        field.focus();report();
        </script></body></html>
        """

    @Test(
        "Chromium reports native dead-key preedit and commits the exact composed character",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTSEAT_CHROMIUM_TESTS"] == "1"
                && liveSkipReason(needsChrome: true) == nil,
            "Opt in with AGENTSEAT_CHROMIUM_TESTS=1 on the approved exclusive desktop"
        )
    )
    func nativeComposition() async throws {
        try await measure(.commit)
    }

    @Test(
        "Chromium composition deadline revokes a fresh late key while its callback waits",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTSEAT_CHROMIUM_TESTS"] == "1"
                && liveSkipReason(needsChrome: true) == nil,
            "Opt in with AGENTSEAT_CHROMIUM_TESTS=1 on the approved exclusive desktop"
        )
    )
    func nativeDeadline() async throws {
        try await measure(.deadline)
    }

    @Test(
        "Chromium composition cancellation restores preparation with marked text present",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTSEAT_CHROMIUM_TESTS"] == "1"
                && liveSkipReason(needsChrome: true) == nil,
            "Opt in with AGENTSEAT_CHROMIUM_TESTS=1 on the approved exclusive desktop"
        )
    )
    func nativeCancellation() async throws {
        let experiment = Task { @MainActor in
            try await measure(.cancellation)
        }
        try await experiment.value
    }

    private func measure(_ flow: Flow) async throws {
        let keys = try #require(nativeDeadKeySequence())
        try await LiveStage.run(
            needsFixture: false,
            needsChrome : false
        ) { stage in
            let browser = try OwnBrowserTarget.launched(pageHTML: Self.page)
            defer { browser.terminate() }
            _ = try WindowReader.windowSnapshot(
                processID   : browser.processID,
                windowNumber: browser.windowNumber
            )
            try handBackLiveFocus(
                to      : stage.personBefore,
                avoiding: browser.processID
            )
            let target = ChromeTarget(
                window: ChromeWindow(
                    processID   : browser.processID,
                    windowNumber: browser.windowNumber,
                    frame       : browser.reference.frame,
                    title       : ""
                ),
                platform: ChromiumPlatform(nativeTextInputIsQualified: true)
            )
            let window = try await adopt(
                target,
                onto  : stage.seat,
                bounds: stage.virtualBounds
            )
            let person = UserSeatState.capture()
            let physicalBefore = stage.fence.snapshot().observedEventCount
            let turn = try await stage.seat.acquire()
            try #require(Self.state(browser)["v"] == "")
            var cleanup: InputCleanupResult?
            do {
                cleanup = try await stage.seat.withNativeTextInput(
                    observation: try await liveObservation(stage.seat),
                    turn       : turn,
                    within     : flow == .deadline ? .milliseconds(1500) : .seconds(4)
                ) {
                    let dead = try await stage.seat.send(
                        .key(
                            virtualKey: keys.dead,
                            text      : "",
                            modifiers : .option
                        ),
                        observation: try await liveObservation(stage.seat),
                        turn       : turn
                    )
                    let composing = await LivePump.settle(
                        until: {
                            let state = Self.state(browser)
                            return (Int(state["s"] ?? "") ?? 0) > 0
                                && (Int(state["u"] ?? "") ?? 0) > 0
                                && state["e"] == "0" && state["p"]?.isEmpty == false
                        },
                        timeout: 2
                    )
                    try stage.seat.confirm(
                        dead,
                        composing ? .observed : .absent
                    )
                    _ = await stage.seat.concludeObservation()
                    print("CHROMIUM_IME source=\(keys.sourceID) dead=\(keys.dead) commit=\(keys.commit)"
                        + " native-preedit=\(composing) state=\(Self.state(browser))")
                    try #require(composing)
                    switch flow {
                        case .commit:
                            let commit = try await stage.seat.send(
                                .key(
                                    virtualKey: keys.commit,
                                    text      : ""
                                ),
                                observation: try await liveObservation(stage.seat),
                                turn       : turn
                            )
                            let committed = await LivePump.settle(
                                until: {
                                    let state = Self.state(browser)
                                    return state["v"] == "é" && state["p"] == ""
                                        && (Int(state["e"] ?? "") ?? 0) > 0
                                },
                                timeout: 2
                            )
                            try stage.seat.confirm(
                                commit,
                                committed ? .observed : .absent
                            )
                            _ = await stage.seat.concludeObservation()
                            #expect(committed)
                        case .deadline:
                            try await Task.sleep(for: .milliseconds(1700))
                            let beforeLateKey = Self.state(browser)
                            await #expect(throws: InputFailure.nativeTextInputRefused(.contextClosed)) {
                                _ = try await stage.seat.send(
                                    .key(
                                        virtualKey: keys.commit,
                                        text      : ""
                                    ),
                                    observation: try await liveObservation(stage.seat),
                                    turn       : turn
                                )
                            }
                            #expect(Self.state(browser) == beforeLateKey)
                            print("CHROMIUM_IME late-key-refused=true state=\(beforeLateKey)")
                        case .cancellation:
                            withUnsafeCurrentTask { $0?.cancel() }
                            try Task.checkCancellation()
                    }
                }
            } catch {
                guard let failure = error as? NativeTextInputFailure else { throw error }
                switch flow {
                    case .commit: throw error
                    case .deadline:
                        guard case .nativeTextInputRefused(.contextClosed) = failure.cause as? InputFailure
                        else { throw error }
                    case .cancellation:
                        guard failure.cause is CancellationError else { throw error }
                }
                cleanup = failure.cleanup
                print("CHROMIUM_IME end=\(flow) state=\(Self.state(browser))")
            }
            #expect(cleanup == .succeeded)
            try stage.seat.release(turn)
            let physical = stage.fence.snapshot().observedEventCount - physicalBefore
            let preserved = UserSeatState.capture() == person
            print("CHROMIUM_IME flow=\(flow) cleanup=\(String(describing: cleanup)) state=\(Self.state(browser))"
                + " physical-events=\(physical) user-seat-preserved=\(preserved)")
            #expect(physical == 0)
            #expect(preserved)
            await stage.giveBack(
                window,
                of  : target,
                home: nil
            )
        }
    }

    private static func state(_ browser: OwnBrowserTarget) -> [String: String] {
        let title = ChromeWindow.accessibilityTitle(
            processID   : browser.processID,
            windowNumber: browser.windowNumber
        )
        guard let range = title.range(of: "ASIME ") else { return [:] }
        var result: [String: String] = [:]
        for field in title[range.upperBound...].split(separator: " ") {
            let parts = field.split(
                separator            : "=",
                maxSplits            : 1,
                omittingEmptySubsequences: false
            )
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1]).removingPercentEncoding
            }
        }
        return result
    }
}
