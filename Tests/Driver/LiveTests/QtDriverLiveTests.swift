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
                        + " staged=\(server.frame) ax=\(observed.windowFrame)")
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
                #expect(UserSeatState.capture() == stage.personBefore)

                let outcome = await stage.seat.release(window, .returnToUserSeat)
                adopted = nil
                print("QT_RETURN window=\(window.id) outcome=\(outcome)")
                #expect(outcome == .returned)
                #expect(UserSeatState.capture() == stage.personBefore)
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
            if let adopted { _ = await stage.seat.release(adopted, .returnToUserSeat) }
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
                    #expect(UserSeatState.capture() == stage.personBefore)
                }
                #expect(try searchValue() == initial, "The test left Search in another state")
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { _ = await stage.seat.release(adopted, .returnToUserSeat) }
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
                    try #require(
                        snapshot().axTree.first {
                            $0.description == description && $0.role == role
                        })
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
                    + " user-seat-before=\(stage.personBefore) after=\(personAfter)")
                #expect(personAfter == stage.personBefore)
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted { _ = await stage.seat.release(adopted, .returnToUserSeat) }
        }
        if let failure { throw failure }
    }
}
