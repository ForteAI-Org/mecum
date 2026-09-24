//
//  QtEditorLiveTests.swift
//  AgentSeatKit
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
import VirtualScreens
import WindowPlacement

/// The user's disposable recent project qualifies DaVinci's main editor.
/// The row changes only the visible page and restores the initial Cut page.
@Suite("DaVinci Qt editor qualification", .serialized)
@MainActor
struct QtEditorLiveTests {

    @Test(
        "DaVinci's editor switches Cut to Edit and back on the background seat",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_EDITOR_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_EDITOR_TESTS") ?? "")))
    func switchEditorPages() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "New Project 1")

        var failure: (any Error)?
        try await LiveStage.run(
            needsFixture: false,
            needsChrome: false,
            configuration: SeatHostConfiguration(
                restoresUserFocus: true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let handBefore = stage.fence.snapshot().observedEventCount
            let personBefore = UserSeatState.capture()
            var adopted: AdoptedWindow?

            @MainActor
            func pageValue(_ name: String, in window: AdoptedWindow) throws -> String {
                let snapshot = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: window.id,
                    allowUnvalidatedBuild: true
                )
                return try #require(snapshot.axTree.first {
                    $0.role == "AXCheckBox" && $0.description == name
                }).value
            }

            @MainActor
            func clickPage(_ name: String, in window: AdoptedWindow) async throws -> Bool {
                let snapshot = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: window.id,
                    allowUnvalidatedBuild: true
                )
                let control = try #require(snapshot.axTree.first {
                    $0.role == "AXCheckBox" && $0.description == name
                })
                let frame = try #require(control.frame)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let point = try #require(InputLocation(
                    screenPoint: CGPoint(x: frame.midX, y: frame.midY),
                    observedIn: geometry
                ))
                let turn = try await stage.seat.acquire()
                do {
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(point), observation: reference,
                        turn: turn, platform: QtPlatform()
                    )
                    let changed = LivePump.run(until: {
                        (try? pageValue(name, in: window)) == "1"
                    }, timeout: 4)
                    try stage.seat.confirm(receipt, changed ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(turn)
                    print("QT_EDITOR page=\(name) changed=\(changed)"
                        + " events=\(receipt.eventCount)"
                        + " preparation=\(receipt.preparation)")
                    return changed
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(turn)
                    throw error
                }
            }

            do {
                try #require(personBefore.frontmostProcessID != processID)
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                try #require(stage.virtualBounds.contains(server.frame))
                try #require(pageValue("Cut", in: window) == "1")
                try #require(await clickPage("Edit", in: window))
                try #require(pageValue("Cut", in: window) == "0")
                try #require(await clickPage("Cut", in: window))
                try #require(pageValue("Edit", in: window) == "0")
            } catch {
                failure = error
                if let adopted, (try? pageValue("Cut", in: adopted)) == "0" {
                    _ = try? await clickPage("Cut", in: adopted)
                }
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT_EDITOR release=\(outcome)")
                #expect(outcome == .returned)
                if stage.fence.snapshot().observedEventCount == handBefore {
                    #expect(UserSeatState.capture() == personBefore)
                }
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "DaVinci's Import Media panel is contained and cancelled without importing a file",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_EDITOR_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_EDITOR_TESTS") ?? "")))
    func cancelImportMedia() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "New Project 1")

        var failure: (any Error)?
        try await LiveStage.run(
            needsFixture: false,
            needsChrome: false,
            configuration: SeatHostConfiguration(
                followsNewWindows: true,
                restoresUserFocus: true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let handBefore = stage.fence.snapshot().observedEventCount
            let personBefore = UserSeatState.capture()
            var parent: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                parent = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = parent, !stage.seat.isStaged(window) {
                    parent = try await stage.seat.stage(window)
                }
                let window = try #require(parent)
                let baseline = Set(WindowServerProbe.surfaces(
                    ownedBy: Set([processID]), allowUnvalidatedBuild: true
                )?.map { $0.reference.windowNumber } ?? [])
                let editor = try WindowReader.windowSnapshot(
                    processID: processID, windowNumber: window.id,
                    allowUnvalidatedBuild: true
                )
                let opener = try #require(editor.axTree.first {
                    $0.role == "AXButton" && $0.description == "Import Media"
                })
                let openerFrame = try #require(opener.frame)
                let parentServer = try #require(WindowServerProbe.geometry(of: window.id))
                let parentGeometry = try #require(
                    WindowGeometryProbe.observation(of: parentServer)
                )
                let openerPoint = try #require(InputLocation(
                    screenPoint: CGPoint(x: openerFrame.midX, y: openerFrame.midY),
                    observedIn: parentGeometry
                ))
                let turn = try await stage.seat.acquire()
                let reference = try await liveObservation(stage.seat)
                let opening = try await stage.seat.send(
                    .click(openerPoint), observation: reference,
                    turn: turn, platform: QtPlatform()
                )
                let searchStarted = DispatchTime.now().uptimeNanoseconds
                var panelNumber: Int?
                var firstPanelFrame: CGRect?
                var firstPanelAt: UInt64?
                let appeared = await LivePump.settle(until: {
                    let surfaces = WindowServerProbe.surfaces(
                        ownedBy: Set([processID]), allowUnvalidatedBuild: true
                    ) ?? []
                    let candidate = surfaces.first {
                        !baseline.contains($0.reference.windowNumber)
                            && $0.level != WindowServerProbe.popUpMenuLevel
                            && $0.isVisible
                    }
                    panelNumber = candidate?.reference.windowNumber
                    if firstPanelAt == nil, let candidate {
                        firstPanelAt = DispatchTime.now().uptimeNanoseconds
                        firstPanelFrame = candidate.reference.frame
                    }
                    return panelNumber != nil
                }, timeout: 5)
                try stage.seat.confirm(opening, appeared ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                try #require(appeared, "Import Media did not expose a new DaVinci surface")
                let panelID = try #require(panelNumber)
                let autoContained = await LivePump.settle(until: {
                    guard stage.seat.adoptedWindows.contains(where: { $0.id == panelID }),
                          let server = WindowServerProbe.geometry(of: panelID)
                    else { return false }
                    return stage.virtualBounds.contains(server.frame)
                }, timeout: 2)
                let autoCheckedAt = DispatchTime.now().uptimeNanoseconds
                let firstPanelMS = firstPanelAt.map {
                    Int(($0 - searchStarted) / 1_000_000)
                } ?? -1
                let visibleToContainedMS = firstPanelAt.map {
                    Int((autoCheckedAt - $0) / 1_000_000)
                } ?? -1
                let panel = try WindowReader.windowSnapshot(
                    processID: processID, windowNumber: panelID,
                    allowUnvalidatedBuild: true
                )
                print("QT_EDITOR_IMPORT panel=\(panelID) title=\(panel.windowTitle)"
                    + " auto-contained=\(autoContained)"
                    + " first-frame=\(String(describing: firstPanelFrame))"
                    + " first-panel-ms=\(firstPanelMS)"
                    + " visible-to-contained-ms=\(visibleToContainedMS)"
                    + " frame=\(panel.windowFrame)"
                    + " follow-scans=\(stage.seat.windowFollowScanCount)")
                #expect(autoContained, "Qt window follower did not automatically contain Import Media")
                try #require(panel.windowTitle == "Import Media")
                if !autoContained {
                    let ownedPanel: AdoptedWindow
                    if let existing = stage.seat.adoptedWindows.first(where: { $0.id == panelID }) {
                        ownedPanel = existing
                    } else {
                        ownedPanel = try await stage.seat.adopt(
                            panel.reference, platform: QtPlatform(), title: panel.windowTitle
                        )
                    }
                    if !stage.seat.isStaged(ownedPanel) {
                        _ = try await stage.seat.stage(ownedPanel)
                    }
                }
                let contained = try #require(WindowServerProbe.geometry(of: panelID))
                try #require(stage.virtualBounds.contains(contained.frame))
                let stagedPanel = try WindowReader.windowSnapshot(
                    processID: processID, windowNumber: panelID,
                    allowUnvalidatedBuild: true
                )
                let cancel = try #require(stagedPanel.axTree.first {
                    $0.role == "AXButton" && $0.title == "Cancel"
                })
                let cancelFrame = try #require(cancel.frame)
                let panelGeometry = try #require(
                    WindowGeometryProbe.observation(of: contained)
                )
                let cancelPoint = try #require(InputLocation(
                    screenPoint: CGPoint(x: cancelFrame.midX, y: cancelFrame.midY),
                    observedIn: panelGeometry
                ))
                let cancelTurn = try await stage.seat.acquire()
                let cancelReference = try await liveObservation(stage.seat)
                let cancellation = try await stage.seat.send(
                    .click(cancelPoint), observation: cancelReference,
                    turn: cancelTurn
                )
                let closed = LivePump.run(until: {
                    (try? WindowReader.windowSnapshot(
                        processID: processID, allowUnvalidatedBuild: true
                    ).windowTitle) == "New Project 1"
                }, timeout: 5)
                try stage.seat.confirm(cancellation, closed ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(cancelTurn)
                try #require(closed, "Import Media did not close after Cancel")
                print("QT_EDITOR_IMPORT closed=\(closed)"
                    + " events=\(cancellation.eventCount)")
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let parent {
                for child in stage.seat.adoptedWindows where child.id != parent.id {
                    _ = await stage.seat.release(child, .leaveOnVirtualDisplay)
                }
                let outcome = await stage.seat.release(parent, .returnToUserSeat)
                print("QT_EDITOR_IMPORT release=\(outcome)")
                #expect(outcome == .returned)
                if stage.fence.snapshot().observedEventCount == handBefore {
                    #expect(UserSeatState.capture() == personBefore)
                }
            }
        }
        if let failure { throw failure }
    }
}
