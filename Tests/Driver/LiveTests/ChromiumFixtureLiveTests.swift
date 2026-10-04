//
//  ChromiumFixtureLiveTests.swift
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
import TargetReader
import Testing
import WindowPlacement

/// ChromiumFixtureLiveTests owns a synthetic page and its disposable browser profile.
/// Native panel effects are read from the page's cancel event and WindowServer,
/// independently from the receipt. No file is selected or uploaded.
@MainActor
struct ChromiumFixtureLiveTests {

    static let filePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>ASFILE</title></head>
        <body style="margin:0;background:#123">
        <button id="open" style="position:fixed;inset:0;border:0;background:#123;color:#fff">
        Open disposable file picker</button><input id="file" type="file" hidden>
        <script>
        let opened=0,cancelled=0;
        const file=document.getElementById('file');
        const report=()=>document.title=`ASFILE ready=1 open=${opened} cancel=${cancelled} files=${file.files.length}`;
        document.getElementById('open').onclick=()=>{opened++;report();file.click();};
        file.addEventListener('cancel',()=>{cancelled++;report();});
        file.addEventListener('change',report);
        report();
        </script></body></html>
        """

    @Test(
        "a Chromium native file picker is contained and cancelled without selecting a file",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTSEAT_CHROMIUM_TESTS"] == "1"
                && liveSkipReason(needsChrome: true) == nil,
            "Opt in with AGENTSEAT_CHROMIUM_TESTS=1 on the approved exclusive desktop"
        )
    )
    func nativeFileDialog() async throws {
        try await LiveStage.run(
            needsFixture: false,
            needsChrome : false,
            configuration: SeatHostConfiguration(
                followsNewWindows            : true,
                restoresUserFocus            : true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let browser = try OwnBrowserTarget.launched(pageHTML: Self.filePage)
            defer { browser.terminate() }
            NSRunningApplication(processIdentifier: stage.personBefore.frontmostProcessID)?.activate()
            try #require(
                LivePump.run(
                    until: {
                        NSWorkspace.shared.frontmostApplication?.processIdentifier
                            == stage.personBefore.frontmostProcessID
                    },
                    timeout: 3
                )
            )
            let target = ChromeTarget(
                window: ChromeWindow(
                    processID   : browser.processID,
                    windowNumber: browser.windowNumber,
                    frame       : browser.reference.frame,
                    title       : ""
                )
            )
            let parent = try await adopt(
                target,
                onto  : stage.seat,
                bounds: stage.virtualBounds
            )
            let person = UserSeatState.capture()
            let physicalBefore = stage.fence.snapshot().observedEventCount
            var failure: (any Error)?
            do {
                try #require(Self.title(browser).contains("ready=1 open=0 cancel=0 files=0"))
                let before = Set(
                    (WindowServerProbe.surfaces(ownedBy: [browser.processID]) ?? [])
                        .map { $0.reference.windowNumber }
                )
                let point = try #require(target.clickPoint())
                let turn = try await stage.seat.acquire()
                let opened = try await stage.seat.send(
                    .click(try target.location(of: point)),
                    observation: try await liveObservation(stage.seat),
                    turn       : turn
                )
                let pageOpened = LivePump.run(
                    until  : { Self.title(browser).contains("open=1") },
                    timeout: 3
                )
                try stage.seat.confirm(
                    opened,
                    pageOpened ? .observed : .absent
                )
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                try #require(pageOpened)

                var panel: WindowReference?
                let found = await LivePump.settle(
                    until: {
                        panel = WindowServerProbe.surfaces(ownedBy: [browser.processID])?
                            .first {
                                !before.contains($0.reference.windowNumber) && $0.isVisible
                                    && $0.reference.frame.width > 200
                                    && $0.reference.frame.height > 200
                                    && ($0.level == 0 || $0.level == 8)
                            }?.reference
                        return panel != nil
                    },
                    timeout: 4
                )
                try #require(found, "The owned browser published no native panel")
                let born = try #require(panel)
                print("CHROMIUM_NATIVE_FILE born-window=\(born.windowNumber) first-frame=\(born.frame)"
                    + " first-contained=\(stage.virtualBounds.contains(born.frame))")
                let firstReading = try WindowReader.windowSnapshot(
                    processID   : browser.processID,
                    windowNumber: parent.id
                )
                print("CHROMIUM_NATIVE_FILE panel-roles=\(Set(firstReading.axTree.map(\.role)).sorted())"
                    + " adopted=\(stage.seat.adoptedWindows.map(\.id))")
                var observedSheet: WindowIdentity?
                switch await stage.seat.observe() {
                    case .success(let delivery):
                        print("CHROMIUM_NATIVE_FILE observed-role=\(delivery.role)"
                            + " observed-surface=\(delivery.reference.surface.windowNumber)")
                        if case .hostedSheet(let sheet) = delivery.role { observedSheet = sheet }
                    case .failure(let reason):
                        print("CHROMIUM_NATIVE_FILE observation-refused=\(reason)")
                }
                let contained = await LivePump.settle(
                    until: {
                        guard observedSheet == born.identity,
                              let current = WindowServerProbe.geometry(of: born.windowNumber),
                              current.identity == born.identity
                        else { return false }
                        return stage.virtualBounds.contains(current.frame)
                    },
                    timeout: 5
                )
                try #require(contained, "The window follower did not contain the native panel")
                print("CHROMIUM_NATIVE_FILE state=\(stage.seat.state)"
                    + " adopted-after-observe=\(stage.seat.adoptedWindows.map(\.id))"
                    + " follow-scans=\(stage.seat.windowFollowScanCount)")
                let reading = try WindowReader.windowSnapshot(
                    processID   : browser.processID,
                    windowNumber: parent.id
                )
                let cancel = try #require(reading.axTree.first {
                    $0.role == "AXButton" && $0.title == "Cancel"
                })
                let frame = try #require(cancel.frame)
                let current = try #require(WindowServerProbe.geometry(of: born.windowNumber))
                let geometry = try #require(WindowGeometryProbe.observation(of: current))
                let location = try #require(
                    InputLocation(
                        screenPoint: CGPoint(
                            x: frame.midX,
                            y: frame.midY
                        ),
                        observedIn: geometry
                    )
                )
                let cancelTurn = try await stage.seat.acquire()
                let cancelled = try await stage.seat.send(
                    .click(location),
                    observation: try await liveObservation(stage.seat),
                    turn       : cancelTurn
                )
                let closed = await LivePump.settle(
                    until: {
                        Self.title(browser).contains("cancel=1 files=0")
                            && WindowServerProbe.surfaces(ownedBy: [browser.processID])?
                                .contains { $0.reference.windowNumber == born.windowNumber && $0.isVisible } == false
                    },
                    timeout: 4
                )
                try stage.seat.confirm(
                    cancelled,
                    closed ? .observed : .absent
                )
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(cancelTurn)
                try #require(closed)
                print("CHROMIUM_NATIVE_FILE contained=true closed=true files=0"
                    + " cancel-events=\(cancelled.eventCount)")
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            for child in stage.seat.adoptedWindows where child.id != parent.id {
                _ = await stage.seat.release(
                    child,
                    .leaveOnVirtualDisplay
                )
            }
            let returned = await stage.seat.release(
                parent,
                .returnToUserSeat
            )
            let physical = stage.fence.snapshot().observedEventCount - physicalBefore
            let preserved = UserSeatState.capture() == person
            print("CHROMIUM_NATIVE_FILE returned=\(returned) physical-events=\(physical)"
                + " user-seat-preserved=\(preserved)")
            #expect(returned == .returned)
            #expect(physical == 0)
            #expect(preserved)
            if let failure { throw failure }
        }
    }

    private static func title(_ browser: OwnBrowserTarget) -> String {
        ChromeWindow.accessibilityTitle(
            processID   : browser.processID,
            windowNumber: browser.windowNumber
        )
    }
}
