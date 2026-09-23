//
//  QtDriverLiveTests.swift
//  AgentSeatKit
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import SeatCapture
import SeatCore
import SeatInput
import SeatSession
import TargetReader
import Testing
import VirtualScreens
import WindowPlacement

/// Reads the real Qt target before moving or driving any of its windows.
/// A successful WindowServer row is not enough: the same Window ID must also
/// resolve through AX, or the seat cannot prove which window it will move.
@Suite("Qt target qualification", .serialized)
@MainActor
struct QtDriverLiveTests {

    /// The current Project Manager is resolved through AX and its exact
    /// WindowServer ID. Stage Manager may omit it from the on-screen list while
    /// the same window still exists and can be moved by the seat.
    private func projectManager(of processID: Int32) throws -> ObservedWindow {
        let observed = try WindowReader.windowSnapshot(
            processID: processID,
            allowUnvalidatedBuild: true
        )
        return try #require(observed.windowTitle == "Project Manager" ? observed : nil)
    }

    /// A failed assertion must not leave DaVinci waiting in its New Project
    /// dialog. This uses the same attested window and seat route as the row.
    private func cancelResidualDialog(in stage: LiveStage, processID: Int32) async {
        guard let dialog = try? WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        ), dialog.windowTitle == "Create New Project" else { return }

        if !stage.seat.adoptedWindows.contains(where: { $0.id == dialog.windowNumber }) {
            _ = try? await stage.seat.adopt(
                dialog.reference, platform: QtPlatform(), title: dialog.windowTitle
            )
        }
        _ = LivePump.run(until: { stage.seat.state.acceptsCommands }, timeout: 2)
        guard let current = try? WindowReader.windowSnapshot(
            processID: processID,
            windowNumber: dialog.windowNumber,
            allowUnvalidatedBuild: true
        ),
              let cancel = current.axTree.first(where: {
                  $0.role == "AXButton" && ($0.title == "Cancel" || $0.description == "Cancel")
              }),
              let frame = cancel.frame,
              let server = WindowServerProbe.geometry(of: dialog.windowNumber),
              let geometry = WindowGeometryProbe.observation(of: server),
              let point = InputLocation(
                  screenPoint: CGPoint(x: frame.midX, y: frame.midY), observedIn: geometry
              ),
              let turn = try? await stage.seat.acquire()
        else {
            print("QT_DIALOG cleanup could not address Cancel through the seat")
            return
        }

        do {
            let reference = try await liveObservation(stage.seat)
            let receipt = try await stage.seat.send(
                .click(point), observation: reference, turn: turn, platform: QtPlatform()
            )
            let closed = LivePump.run(until: {
                (try? WindowReader.windowSnapshot(
                    processID: processID, allowUnvalidatedBuild: true
                ).windowTitle) == "Project Manager"
            }, timeout: 3)
            try stage.seat.confirm(receipt, closed ? .observed : .unknown)
            print("QT_DIALOG cleanup-cancelled=\(closed)")
        } catch {
            print("QT_DIALOG cleanup refused=\(error)")
        }
        _ = await stage.seat.concludeObservation()
        try? stage.seat.release(turn)
    }

    /// Search is a temporary probe. Even a failed assertion must close it so
    /// the next run starts from the same Project Manager state.
    private func closeResidualSearch(in stage: LiveStage, processID: Int32) async {
        guard let manager = try? WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        ), manager.windowTitle == "Project Manager",
              let search = manager.axTree.first(where: {
                  $0.role == "AXCheckBox" && $0.description == "Search" && $0.value == "1"
              }),
              let frame = search.frame,
              let server = WindowServerProbe.geometry(of: manager.windowNumber),
              let geometry = WindowGeometryProbe.observation(of: server),
              let point = InputLocation(
                  screenPoint: CGPoint(x: frame.midX, y: frame.midY), observedIn: geometry
              ),
              let turn = try? await stage.seat.acquire()
        else { return }

        do {
            let reference = try await liveObservation(stage.seat)
            let receipt = try await stage.seat.send(
                .click(point), observation: reference, turn: turn, platform: QtPlatform()
            )
            let closed = LivePump.run(until: {
                (try? WindowReader.windowSnapshot(
                    processID: processID, allowUnvalidatedBuild: true
                ).axTree.first(where: {
                    $0.role == "AXCheckBox" && $0.description == "Search"
                })?.value) == "0"
            }, timeout: 3)
            try stage.seat.confirm(receipt, closed ? .observed : .unknown)
            print("QT_TEXT cleanup-search-closed=\(closed)")
        } catch {
            print("QT_TEXT cleanup-search-refused=\(error)")
        }
        _ = await stage.seat.concludeObservation()
        try? stage.seat.release(turn)
    }

    /// The row is incomplete if the target window stays on the virtual
    /// display, even when its input effect was observed before release.
    private func returnWindow(_ window: AdoptedWindow, in stage: LiveStage) async {
        let outcome = await stage.seat.release(window, .returnToUserSeat)
        let body = try? WindowRelocator.frame(of: window.reference)
        let surface = WindowServerProbe.geometry(of: window.id)?.frame
        print("QT_RELEASE window=\(window.id) outcome=\(outcome)"
            + " original=\(window.originalFrame) body=\(String(describing: body))"
            + " server=\(String(describing: surface))")
        #expect(outcome == .returned, "The Qt window was not returned to the User Seat")
    }

    @Test(
        "DaVinci's AX window has an attested WindowServer identity",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func discoverDaVinci() throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first,
            "DaVinci Resolve must already be running for this opt-in test"
        )
        let processID = application.processIdentifier
        let surfaces = try #require(
            WindowServerProbe.surfaces(
                ownedBy: Set([processID]),
                allowUnvalidatedBuild: true
            ),
            "The WindowServer inventory was unavailable"
        )
        print(
            "QT_DISCOVERY visible-surfaces=\(surfaces.count)"
                + " active-displays=\((try? DisplayList.online().count) ?? -1)"
                + " application-hidden=\(application.isHidden)")
        let direct = try projectManager(of: processID)
        print(
            "QT_DISCOVERY direct-ax window=\(direct.windowNumber)"
                + " title=\(direct.windowTitle) frame=\(direct.windowFrame)")
        #expect(direct.windowIdentity != nil)

        var readable = 0
        for surface in surfaces where surface.isVisible {
            let number = surface.reference.windowNumber
            do {
                let observed = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: number,
                    allowUnvalidatedBuild: true
                )
                readable += 1
                print(
                    "QT_DISCOVERY window=\(number) level=\(surface.level)"
                        + " server=\(surface.reference.frame) ax=\(observed.windowFrame)"
                        + " title=\(observed.windowTitle)")
                #expect(observed.windowIdentity == surface.reference.identity)
            } catch {
                print(
                    "QT_DISCOVERY window=\(number) level=\(surface.level)"
                        + " server=\(surface.reference.frame) ax-error=\(error)")
            }
        }
        if !surfaces.isEmpty {
            #expect(readable > 0, "Visible DaVinci windows did not match AX")
        }
    }

    @Test(
        "DaVinci's Project Manager is adopted, staged and returned without changing the User Seat",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func adoptAndReturnDaVinci() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let physicalEventsBefore = stage.fence.snapshot().observedEventCount
            let personAtSeatStart = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference,
                    platform: QtPlatform(),
                    title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let observed = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: window.id,
                    allowUnvalidatedBuild: true
                )
                print(
                    "QT_ADOPTION window=\(window.id) before=\(manager.windowFrame)"
                        + " staged=\(server.frame) ax=\(observed.windowFrame)"
                        + " original-server=\(String(describing: window.originalServerFrame))")
                for node in observed.axTree
                where
                    ["New Project", "Search", "List View", "Thumbnail View", "Open"]
                    .contains(node.description) || node.role == "AXSlider"
                {
                    print(
                        "QT_CONTROL role=\(node.role) description=\(node.description)"
                            + " frame=\(String(describing: node.frame))"
                            + " value=\(node.value)"
                            + " enabled=\(String(describing: node.isEnabled))")
                }
                #expect(stage.virtualBounds.contains(server.frame))
                #expect(stage.seat.isStaged(window))
                if stage.fence.snapshot().observedEventCount == physicalEventsBefore {
                    #expect(UserSeatState.capture() == personAtSeatStart)
                }

                let outcome = await stage.seat.release(window, .returnToUserSeat)
                adopted = nil
                let returnedServer = WindowServerProbe.geometry(of: window.id)
                let returnedBody = try? WindowRelocator.frame(of: window.reference)
                let onScreen = WindowServerProbe.surfaces(
                    ownedBy: Set([processID]), allowUnvalidatedBuild: true
                )?.map { "\($0.reference.windowNumber):\($0.reference.frame):\($0.isVisible)" }
                print("QT_RETURN window=\(window.id) outcome=\(outcome)"
                    + " server=\(String(describing: returnedServer?.frame))"
                    + " body=\(String(describing: returnedBody))"
                    + " on-screen=\(String(describing: onScreen))")
                if outcome == .refused {
                    LivePump.run(for: 0.7)
                    let settledServer = WindowServerProbe.geometry(of: window.id)
                    let settledBody = try? WindowRelocator.frame(of: window.reference)
                    let settledOnScreen = WindowServerProbe.surfaces(
                        ownedBy: Set([processID]), allowUnvalidatedBuild: true
                    )?.map { "\($0.reference.windowNumber):\($0.reference.frame):\($0.isVisible)" }
                    print("QT_RETURN settled-server=\(String(describing: settledServer?.frame))"
                        + " body=\(String(describing: settledBody))"
                        + " on-screen=\(String(describing: settledOnScreen))")
                }
                #expect(outcome == .returned)
                let physicalEvents = stage.fence.snapshot().observedEventCount - physicalEventsBefore
                print("QT_RETURN physical-events=\(physicalEvents)")
                if physicalEvents == 0 {
                    #expect(UserSeatState.capture() == personAtSeatStart)
                }
            } catch {
                if let adopted { _ = await stage.seat.release(adopted, .returnToUserSeat) }
                failure = error
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "DaVinci's staged Project Manager produces a qualified frame and input reference",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func observeDaVinci() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference,
                    platform: QtPlatform(),
                    title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                switch await stage.seat.observe() {
                case .success(let delivery):
                    print(
                        "QT_OBSERVATION recipient=\(delivery.reference.recipient)"
                            + " pixels=\(delivery.frame.pixelSize)")
                    #expect(delivery.reference.recipient.windowNumber == manager.windowNumber)
                case .failure(let reason):
                    print("QT_OBSERVATION refused=\(reason)")
                    failure = LiveObservationUnavailable(reason: reason)
                }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { await returnWindow(adopted, in: stage) }
        }
        if let failure { throw failure }
    }

    @Test(
        "a background click toggles DaVinci's Search control and a second click restores it",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func clickDaVinciSearch() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let physicalEventsBefore = stage.fence.snapshot().observedEventCount
            let personAtSeatStart = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference,
                    platform: QtPlatform(),
                    title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)

                func searchValue() throws -> String {
                    let snapshot = try WindowReader.windowSnapshot(
                        processID: processID,
                        windowNumber: window.id,
                        allowUnvalidatedBuild: true
                    )
                    let control = try #require(
                        snapshot.axTree.first {
                            $0.description == "Search" && $0.role == "AXCheckBox"
                        })
                    return control.value
                }

                let initial = try searchValue()
                print("QT_CLICK Search initial=\(initial)")
                let recipe = QtPlatform()
                for clickIndex in 1...2 {
                    let snapshot = try WindowReader.windowSnapshot(
                        processID: processID,
                        windowNumber: window.id,
                        allowUnvalidatedBuild: true
                    )
                    let control = try #require(
                        snapshot.axTree.first {
                            $0.description == "Search" && $0.role == "AXCheckBox"
                        })
                    let frame = try #require(control.frame)
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    let location = try #require(
                        InputLocation(
                            screenPoint: CGPoint(x: frame.midX, y: frame.midY),
                            observedIn: geometry
                        ))
                    let turn = try await stage.seat.acquire()
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(location),
                        observation: reference,
                        turn: turn,
                        platform: recipe
                    )
                    let changed = LivePump.run(
                        until: {
                            (try? searchValue()) != control.value
                        }, timeout: 2)
                    let after = try searchValue()
                    print(
                        "QT_CLICK Search recipe=Qt click=\(clickIndex)"
                            + " before=\(control.value)"
                            + " after=\(after) changed=\(changed)"
                            + " events=\(receipt.eventCount) preparation=\(receipt.preparation)")
                    try stage.seat.confirm(receipt, changed ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(turn)
                    #expect(changed, "DaVinci did not change Search after the routed click")
                    if stage.fence.snapshot().observedEventCount == physicalEventsBefore {
                        #expect(UserSeatState.capture() == personAtSeatStart)
                    }
                }
                #expect(try searchValue() == initial, "The test left Search in another state")
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { await returnWindow(adopted, in: stage) }
        }
        if let failure { throw failure }
    }

    @Test(
        "diagnostic Qt contextual menu probe",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil
                && ProcessInfo.processInfo.environment["AGENTSEAT_QT_MENU_PROBE"] == "1",
            Comment(rawValue: "Set AGENTSEAT_QT_MENU_PROBE=1 only for the diagnostic menu probe")))
    func openDaVinciSearchContextMenu() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let physicalEventsBefore = stage.fence.snapshot().observedEventCount
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference, platform: QtPlatform(), title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)

                func control(_ role: String) throws -> AXElementNode {
                    let snapshot = try WindowReader.windowSnapshot(
                        processID: processID,
                        windowNumber: window.id,
                        allowUnvalidatedBuild: true
                    )
                    return try #require(snapshot.axTree.first {
                        $0.description == "Search" && $0.role == role
                    })
                }

                func point(of node: AXElementNode) throws -> InputLocation {
                    let frame = try #require(node.frame)
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    return try #require(InputLocation(
                        screenPoint: CGPoint(x: frame.midX, y: frame.midY),
                        observedIn: geometry
                    ))
                }

                let search = try control("AXCheckBox")
                try #require(search.value == "0", "Search must start closed")
                let turn = try await stage.seat.acquire()
                let reference = try await liveObservation(stage.seat)
                let opening = try await stage.seat.send(
                    .click(try point(of: search)), observation: reference,
                    turn: turn, platform: QtPlatform()
                )
                let opened = LivePump.run(until: {
                    (try? control("AXCheckBox").value) == "1"
                }, timeout: 2)
                try stage.seat.confirm(opening, opened ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                try #require(opened, "Search did not open")

                let menuTurn = try await stage.seat.acquire()
                let menuReference = try await liveObservation(stage.seat)
                let menu = try await stage.seat.withContextMenu(
                    openedAt: point(of: control("AXTextField")),
                    observation: menuReference,
                    turn: menuTurn
                ) { interaction in
                    print("QT_MENU window=\(interaction.menu.window.windowNumber)"
                        + " frame=\(interaction.menu.frame)")
                }
                print("QT_MENU cleanup=\(menu.cleanup)"
                    + " appeared-after=\(menu.menu.appearedAfter)"
                    + " physical-events=\(stage.fence.snapshot().observedEventCount - physicalEventsBefore)")
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(menuTurn)
                #expect(stage.virtualBounds.contains(menu.menu.frame))
                let cleanupVerified: Bool
                switch menu.cleanup {
                    case .verifiedClosed: cleanupVerified = true
                    case .notVerified: cleanupVerified = false
                }
                #expect(cleanupVerified, "The Qt context menu was not verified closed")

                let closeTurn = try await stage.seat.acquire()
                let closeReference = try await liveObservation(stage.seat)
                let closing = try await stage.seat.send(
                    .click(try point(of: control("AXCheckBox"))),
                    observation: closeReference, turn: closeTurn, platform: QtPlatform()
                )
                let closed = LivePump.run(until: {
                    (try? control("AXCheckBox").value) == "0"
                }, timeout: 2)
                try stage.seat.confirm(closing, closed ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(closeTurn)
                #expect(closed, "Search remained open after the menu test")
            } catch {
                await closeResidualSearch(in: stage, processID: processID)
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { await returnWindow(adopted, in: stage) }
        }
        if let failure { throw failure }
    }

    @Test(
        "a Qt dialog opened in the background is followed and cancelled in the seat",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func openAndCancelDaVinciProjectDialog() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

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
            let physicalEventsBefore = stage.fence.snapshot().observedEventCount
            let personAtSeatStart = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference,
                    platform: QtPlatform(),
                    title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                print("QT_DIALOG after-stage=\(UserSeatState.capture())")
                let current = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: window.id,
                    allowUnvalidatedBuild: true
                )
                let newProject = try #require(current.axTree.first {
                    $0.role == "AXButton" && ($0.title == "New Project" || $0.description == "New Project")
                })
                let buttonFrame = try #require(newProject.frame)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let location = try #require(InputLocation(
                    screenPoint: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY),
                    observedIn: geometry
                ))

                let turn = try await stage.seat.acquire()
                let reference = try await liveObservation(stage.seat)
                let receipt = try await stage.seat.send(
                    .click(location), observation: reference, turn: turn, platform: QtPlatform()
                )
                let opened = LivePump.run(until: {
                    (try? WindowReader.windowSnapshot(
                        processID: processID, allowUnvalidatedBuild: true
                    ).windowTitle) == "Create New Project"
                }, timeout: 5)
                print("QT_DIALOG opened=\(opened) receipt=\(receipt.eventCount)"
                    + " adopted=\(stage.seat.adoptedWindows.map(\.id))"
                    + " user-seat=\(UserSeatState.capture())")
                try stage.seat.confirm(receipt, opened ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                try #require(opened, "The Qt dialog did not open in the background")

                let dialog = try WindowReader.windowSnapshot(
                    processID: processID, allowUnvalidatedBuild: true
                )
                print("QT_DIALOG window=\(dialog.windowNumber) title=\(dialog.windowTitle)"
                    + " frame=\(dialog.windowFrame)")
                let followed = await LivePump.settle(until: {
                    stage.seat.adoptedWindows.contains { $0.id == dialog.windowNumber }
                }, timeout: 10)
                print("QT_DIALOG followed=\(followed)"
                    + " adopted=\(stage.seat.adoptedWindows.map(\.id))"
                    + " user-seat=\(UserSeatState.capture())")
                try #require(followed, "The seat did not follow the Qt dialog")

                let stagedDialog = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: dialog.windowNumber,
                    allowUnvalidatedBuild: true
                )
                print("QT_DIALOG staged-frame=\(stagedDialog.windowFrame)")
                let cancel = try #require(stagedDialog.axTree.first {
                    $0.role == "AXButton" && ($0.title == "Cancel" || $0.description == "Cancel")
                })
                let cancelFrame = try #require(cancel.frame)
                let dialogServer = try #require(WindowServerProbe.geometry(of: dialog.windowNumber))
                let dialogGeometry = try #require(WindowGeometryProbe.observation(of: dialogServer))
                let cancelPoint = try #require(InputLocation(
                    screenPoint: CGPoint(x: cancelFrame.midX, y: cancelFrame.midY),
                    observedIn: dialogGeometry
                ))
                let cancelTurn = try await stage.seat.acquire()
                let cancelReference = try await liveObservation(stage.seat)
                let cancellation = try await stage.seat.send(
                    .click(cancelPoint), observation: cancelReference,
                    turn: cancelTurn, platform: QtPlatform()
                )
                let closed = LivePump.run(until: {
                    (try? WindowReader.windowSnapshot(
                        processID: processID, allowUnvalidatedBuild: true
                    ).windowTitle) == "Project Manager"
                }, timeout: 5)
                print("QT_DIALOG cancelled=\(closed) receipt=\(cancellation.eventCount)")
                try stage.seat.confirm(cancellation, closed ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(cancelTurn)
                #expect(closed, "The Qt dialog was not cancelled in the background")
                let focusRestored = LivePump.run(until: {
                    UserSeatState.capture().frontmostProcessID == personAtSeatStart.frontmostProcessID
                }, timeout: 3)
                let physicalEvents = stage.fence.snapshot().observedEventCount - physicalEventsBefore
                let personAfter = UserSeatState.capture()
                print("QT_DIALOG focus-restored=\(focusRestored)"
                    + " recovery=\(String(describing: stage.seat.lastFocusRecovery))"
                    + " physical-events=\(physicalEvents)"
                    + " before=\(personAtSeatStart) after=\(personAfter)")
                if physicalEvents == 0 {
                    #expect(focusRestored, "The Qt dialog activation did not restore the User Seat")
                    #expect(personAfter.cursor == personAtSeatStart.cursor)
                } else {
                    print("QT_DIALOG user-seat-isolation=inconclusive: physical input overlapped the run")
                }
            } catch {
                await cancelResidualDialog(in: stage, processID: processID)
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { await returnWindow(adopted, in: stage) }
        }
        if let failure { throw failure }
    }

    @Test(
        "bulk text reaches a Qt search field and the temporary query is cleared",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_QT_TESTS") ?? "")))
    func insertTextIntoDaVinciSearch() async throws {
        let application = try #require(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            ).first
        )
        let processID = application.processIdentifier
        let manager = try projectManager(of: processID)

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let physicalEventsBefore = stage.fence.snapshot().observedEventCount
            let personAtSeatStart = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    manager.reference,
                    platform: QtPlatform(),
                    title: manager.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)

                func snapshot() throws -> ObservedWindow {
                    try WindowReader.windowSnapshot(
                        processID: processID,
                        windowNumber: window.id,
                        allowUnvalidatedBuild: true
                    )
                }

                func control(_ description: String, role: String) throws -> AXElementNode {
                    let tree = try snapshot().axTree
                    if let named = tree.first(where: {
                        $0.description == description && $0.role == role
                    }) { return named }
                    // DaVinci sometimes omits the Search text field's AX
                    // description after showing it. Only the unique text
                    // field in Project Manager can stand in for that name.
                    if description == "Search" && role == "AXTextField" {
                        let fields = tree.filter { $0.role == role }
                        if fields.count == 1 { return fields[0] }
                    }
                    throw LiveFailure.unsupported("Project Manager has no unique \(role) for \(description)")
                }

                func point(of node: AXElementNode) throws -> InputLocation {
                    let frame = try #require(node.frame)
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    return try #require(
                        InputLocation(
                            screenPoint: CGPoint(x: frame.midX, y: frame.midY),
                            observedIn: geometry
                        ))
                }

                @MainActor
                func send(
                    _ command: InputCommand, platform: any InputPlatform,
                    until effect: @MainActor () -> Bool
                ) async throws -> Bool {
                    let turn = try await stage.seat.acquire()
                    var posted: InputReceipt?
                    do {
                        let reference = try await liveObservation(stage.seat)
                        let receipt = try await stage.seat.send(
                            command,
                            observation: reference,
                            turn: turn,
                            platform: platform
                        )
                        posted = receipt
                        let changed = LivePump.run(until: { effect() }, timeout: 2)
                        print(
                            "QT_TEXT kind=\(command.kind) changed=\(changed)"
                                + " events=\(receipt.eventCount) preparation=\(receipt.preparation)")
                        try stage.seat.confirm(receipt, changed ? .observed : .absent)
                        _ = await stage.seat.concludeObservation()
                        try stage.seat.release(turn)
                        return changed
                    } catch {
                        if let posted { try? stage.seat.confirm(posted, .unknown) }
                        _ = await stage.seat.concludeObservation()
                        try? stage.seat.release(turn)
                        throw error
                    }
                }

                @MainActor
                func sendShortcut(
                    _ shortcut: Shortcut,
                    until effect: @MainActor () -> Bool
                ) async throws -> Bool {
                    let turn = try await stage.seat.acquire()
                    var posted: InputReceipt?
                    do {
                        let reference = try await liveObservation(stage.seat)
                        let receipt = try await stage.seat.send(
                            shortcut,
                            observation: reference,
                            turn: turn,
                            platform: QtPlatform()
                        )
                        posted = receipt
                        let changed = LivePump.run(until: { effect() }, timeout: 2)
                        print("QT_TEXT shortcut=\(shortcut) changed=\(changed)"
                            + " events=\(receipt.eventCount) preparation=\(receipt.preparation)")
                        try stage.seat.confirm(receipt, changed ? .observed : .absent)
                        _ = await stage.seat.concludeObservation()
                        try stage.seat.release(turn)
                        return changed
                    } catch {
                        if let posted { try? stage.seat.confirm(posted, .unknown) }
                        _ = await stage.seat.concludeObservation()
                        try? stage.seat.release(turn)
                        throw error
                    }
                }

                let recipe = QtPlatform()
                let search = try control("Search", role: "AXCheckBox")
                #expect(search.value == "0", "The test requires Search to start closed")
                let opened = try await send(
                    .click(try point(of: search)),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXCheckBox").value) == "1" }
                )
                try #require(opened, "Search did not open")

                let field = try control("Search", role: "AXTextField")
                #expect(field.value.isEmpty, "The test requires an empty query")
                let focused = try await send(
                    .click(try point(of: field)),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXTextField").isFocused) == true }
                )
                print("QT_TEXT field-focused=\(focused)")

                let sample = "qtbgprobe"
                let inserted = try await send(
                    .insertText(sample),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXTextField").value) == sample }
                )
                print("QT_TEXT field-after-insert=\(try control("Search", role: "AXTextField").value)")
                let textField = try control("Search", role: "AXTextField")
                print(
                    "QT_TEXT text-start=\(String(describing: textField.textStartPoint))"
                        + " text-end=\(String(describing: textField.textEndPoint))"
                        + " selected=\(String(describing: textField.selectedRange))")
                #expect(inserted, "DaVinci did not insert bulk text into Search")

                let typed = try await send(
                    .text("x"),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXTextField").value) == sample + "x" }
                )
                #expect(typed, "DaVinci did not type one character into Search")
                let erased = try await send(
                    .key(virtualKey: 51, text: ""),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXTextField").value) == sample }
                )
                #expect(erased, "DaVinci did not process a background Backspace")

                let selectionField = try control("Search", role: "AXTextField")
                let textStart = try #require(selectionField.textStartPoint)
                let textEnd = try #require(selectionField.textEndPoint)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let wordPoint = try #require(InputLocation(
                    screenPoint: CGPoint(x: (textStart.x + textEnd.x) / 2, y: textStart.y),
                    observedIn: geometry
                ))
                let wordSelected = try await send(
                    .click(wordPoint, count: 2),
                    platform: recipe,
                    until: {
                        ((try? control("Search", role: "AXTextField").selectedRange?.length) ?? 0) > 0
                    }
                )
                let wordRange = try control("Search", role: "AXTextField").selectedRange
                print("QT_TEXT double-click-selection=\(String(describing: wordRange))")
                #expect(wordSelected, "A Qt text word did not respond to a background double click")

                let collapsed = try await send(
                    .key(virtualKey: 124, text: ""),
                    platform: recipe,
                    until: {
                        (try? control("Search", role: "AXTextField").selectedRange?.length) == 0
                    }
                )
                try #require(collapsed, "Right Arrow did not collapse the word selection")
                let selectAll = try await sendShortcut(
                    .character("a", holding: .command),
                    until: {
                        (try? control("Search", role: "AXTextField").selectedRange?.length) == sample.count
                    }
                )
                #expect(selectAll, "A Qt text field did not handle background Select All")

                let dragStart = try #require(
                    InputLocation(
                        screenPoint: CGPoint(x: textEnd.x - 2, y: textEnd.y),
                        observedIn: geometry
                    ))
                let dragEnd = try #require(
                    InputLocation(
                        screenPoint: CGPoint(x: textStart.x + 2, y: textStart.y),
                        observedIn: geometry
                    ))
                let selected = try await send(
                    .drag(from: dragStart, to: dragEnd),
                    platform: recipe,
                    until: {
                        ((try? control("Search", role: "AXTextField").selectedRange?.length) ?? 0) > 0
                    }
                )
                let selectedRange = try control("Search", role: "AXTextField").selectedRange
                print("QT_TEXT selected-range=\(String(describing: selectedRange))")
                #expect(selected, "A Qt text selection did not respond to the background drag")

                let closed = try await send(
                    .click(try point(of: control("Search", role: "AXCheckBox"))),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXCheckBox").value) == "0" }
                )
                #expect(closed, "Search did not close after the text probe")

                let reopened = try await send(
                    .click(try point(of: control("Search", role: "AXCheckBox"))),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXCheckBox").value) == "1" }
                )
                try #require(reopened, "Search did not reopen for cleanup")
                let residual = try control("Search", role: "AXTextField").value
                print("QT_TEXT reopened-value-length=\(residual.count)")
                if !residual.isEmpty {
                    let refocused = try await send(
                        .click(try point(of: control("Search", role: "AXTextField"))),
                        platform: recipe,
                        until: { (try? control("Search", role: "AXTextField").isFocused) == true }
                    )
                    try #require(refocused, "The retained query cannot be focused for cleanup")
                    for _ in 0..<residual.count {
                        let before = try control("Search", role: "AXTextField").value.count
                        let removed = try await send(
                            .key(virtualKey: 51, text: ""),
                            platform: recipe,
                            until: {
                                (try? control("Search", role: "AXTextField").value.count) == before - 1
                            }
                        )
                        try #require(removed, "A background Backspace did not remove one character")
                    }
                }
                #expect(try control("Search", role: "AXTextField").value.isEmpty)
                let restored = try await send(
                    .click(try point(of: control("Search", role: "AXCheckBox"))),
                    platform: recipe,
                    until: { (try? control("Search", role: "AXCheckBox").value) == "0" }
                )
                #expect(restored, "Search was left open after cleanup")
                let physicalEventsAfter = stage.fence.snapshot().observedEventCount
                let personAfter = UserSeatState.capture()
                print("QT_TEXT physical-events=\(physicalEventsAfter - physicalEventsBefore)"
                    + " user-seat-before=\(personAtSeatStart) after=\(personAfter)")
                if physicalEventsAfter == physicalEventsBefore {
                    #expect(personAfter == personAtSeatStart)
                } else {
                    print("QT_TEXT user-seat-isolation=inconclusive: physical input overlapped the run")
                }
            } catch {
                await closeResidualSearch(in: stage, processID: processID)
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { await returnWindow(adopted, in: stage) }
        }
        if let failure { throw failure }
    }
}
