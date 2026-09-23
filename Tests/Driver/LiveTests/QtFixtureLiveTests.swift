//
//  QtFixtureLiveTests.swift
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
import WindowPlacement

nonisolated private func qtFixtureSkipReason() -> String? {
    if let reason = liveSkipReason() { return reason }
    let environment = ProcessInfo.processInfo.environment
    if Int32(environment["AGENTSEAT_QT_FIXTURE_PID"] ?? "") != nil,
       environment["AGENTSEAT_QT_FIXTURE_STATE"] != nil { return nil }
    if let python = environment["AGENTSEAT_QT_PYTHON"],
       FileManager.default.isExecutableFile(atPath: python) { return nil }
    return "Set AGENTSEAT_QT_PYTHON to a PySide6-Essentials Python interpreter"
}

/// Starts an owned fixture when a PySide interpreter is supplied, or attaches
/// to the exact PID of a manually launched probe. Owned fixtures are stopped
/// by the row even if the seat rejects a command.
@MainActor
private final class QtProbeTarget {
    let processID: Int32
    let statePath: String
    private let commandPath: String
    private let process: Process?
    private let ownsStateFile: Bool
    private var nextCommandSequence = 0

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        if let processID = Int32(environment["AGENTSEAT_QT_FIXTURE_PID"] ?? ""),
           let statePath = environment["AGENTSEAT_QT_FIXTURE_STATE"] {
            self.processID = processID
            self.statePath = statePath
            commandPath = statePath + ".command"
            process = nil
            ownsStateFile = false
            return
        }

        let python = try #require(environment["AGENTSEAT_QT_PYTHON"])
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/Driver/QtProbe.py")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-qt-probe-\(UUID().uuidString).json")
        let person = NSWorkspace.shared.frontmostApplication
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: python)
        launched.arguments = [script.path, output.path, output.path + ".command"]
        try launched.run()
        processID = launched.processIdentifier
        statePath = output.path
        commandPath = output.path + ".command"
        process = launched
        ownsStateFile = true

        LivePump.prepare()
        let ready = LivePump.run(until: {
            FileManager.default.fileExists(atPath: output.path)
                && (try? WindowReader.windowSnapshot(
                    processID: launched.processIdentifier,
                    allowUnvalidatedBuild: true
                ).windowTitle) == "Mecum Qt Probe"
        }, timeout: 5)
        if let person, person.processIdentifier != processID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
            person.activate()
        }
        let background = LivePump.run(until: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier != launched.processIdentifier
        }, timeout: 2)
        guard ready && background else {
            stop()
            throw LiveFailure.unsupported(
                "Qt probe failed to open in the background: ready=\(ready) background=\(background)"
            )
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if ownsStateFile { try? FileManager.default.removeItem(atPath: statePath) }
        if ownsStateFile { try? FileManager.default.removeItem(atPath: commandPath) }
    }

    func sendNativeCommand(_ action: String) throws {
        nextCommandSequence += 1
        let data = try JSONSerialization.data(withJSONObject: [
            "sequence": nextCommandSequence,
            "action": action,
        ])
        try data.write(to: URL(fileURLWithPath: commandPath), options: .atomic)
    }
}

/// The opt-in Qt 6 fixture provides target-side counters where DaVinci's
/// Project Manager has no scroll position or held-key observation.
@Suite("Qt 6 fixture qualification", .serialized)
@MainActor
struct QtFixtureLiveTests {

    @Test(
        "a Qt 6 popup opened by the target's native API is scoped and closed",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func nativePopupMenu() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func probeState() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let personBefore = UserSeatState.capture()
            let handBefore = stage.fence.snapshot().observedEventCount
            var adopted: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let initial = (try probeState()["comboIndex"] as? NSNumber)?.intValue ?? -1
                try #require(initial == 0)

                let turn = try await stage.seat.acquire()
                do {
                    let receipt = try await stage.seat.useNativePopupMenu(
                        of: window,
                        turn: turn,
                        opening: { try target.sendNativeCommand("openCombo") },
                        choosing: { menu in
                            print("QT6_NATIVE menu=\(menu.window.windowNumber) frame=\(menu.frame)")
                            try target.sendNativeCommand("chooseBeta")
                            return true
                        }
                    )
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(turn)
                    let chosen = LivePump.run(until: {
                        (try? probeState()["comboIndex"] as? NSNumber)?.intValue == 1
                    }, timeout: 2)
                    print("QT6_NATIVE requested=\(receipt.selectionRequested)"
                        + " closed-by=\(receipt.closedBy)"
                        + " target-chosen=\(chosen)")
                    #expect(stage.virtualBounds.contains(receipt.menu.frame))
                    #expect(receipt.selectionRequested)
                    #expect(receipt.closedBy == .chosenItem)
                    #expect(chosen)
                    #expect((try probeState()["comboText"] as? String) == "Beta")
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(turn)
                    throw error
                }
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                if physicalEvents == 0 { #expect(UserSeatState.capture() == personBefore) }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6_NATIVE release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "a Qt 6 combo popup is chosen through the dropdown menu scope",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func dropdownMenu() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func probeState() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let personBefore = UserSeatState.capture()
            let handBefore = stage.fence.snapshot().observedEventCount
            var adopted: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let geometryReady = LivePump.run(until: {
                    guard let frame = try? probeState()["comboFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(geometryReady)
                let candidate = try probeState()["comboFrame"] as? [NSNumber]
                let frame = try #require(candidate)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let location = try #require(InputLocation(
                    screenPoint: CGPoint(
                        x: frame[0].doubleValue + frame[2].doubleValue / 2,
                        y: frame[1].doubleValue + frame[3].doubleValue / 2
                    ), observedIn: geometry
                ))
                let initial = (try probeState()["comboIndex"] as? NSNumber)?.intValue ?? -1
                try #require(initial == 0)

                let turn = try await stage.seat.acquire()
                do {
                    let result = try await stage.seat.useDropdownMenu(
                        openedAt: location,
                        of: window,
                        turn: turn,
                        keyInterval: .milliseconds(80)
                    ) { menu in
                        print("QT6_DROPDOWN menu=\(menu.window.windowNumber) frame=\(menu.frame)")
                        return [125, 36]
                    }
                    print("QT6_DROPDOWN requested=\(result.selectionRequested)"
                        + " closed-by=\(result.closedBy)"
                        + " opening=\(String(describing: result.opening?.eventCount))"
                        + " keys=\(result.choosing.map(\.eventCount))")
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(turn)
                    let changed = LivePump.run(until: {
                        (try? probeState()["comboIndex"] as? NSNumber)?.intValue == 1
                    }, timeout: 2)
                    #expect(result.selectionRequested)
                    #expect(changed, "Qt did not select Beta from its combo popup")
                    #expect((try probeState()["comboText"] as? String) == "Beta")
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(turn)
                    throw error
                }
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                if physicalEvents == 0 { #expect(UserSeatState.capture() == personBefore) }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6_DROPDOWN release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "a Qt 6 menu opens on the virtual display and is verified closed",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func contextMenu() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let statePath = target.statePath
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func probeState() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            let handBefore = stage.fence.snapshot().observedEventCount
            let personBefore = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let geometryReady = LivePump.run(until: {
                    guard let frame = try? probeState()["textFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(geometryReady)
                let candidate = try probeState()["textFrame"] as? [NSNumber]
                let frame = try #require(candidate)
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let point = try #require(InputLocation(
                    screenPoint: CGPoint(
                        x: frame[0].doubleValue + frame[2].doubleValue / 2,
                        y: frame[1].doubleValue + frame[3].doubleValue / 2
                    ),
                    observedIn: geometry
                ))
                let previousRightClicks = (try probeState()["rightClicks"] as? NSNumber)?.intValue ?? -1
                let previousChoices = (try probeState()["menuChoices"] as? NSNumber)?.intValue ?? -1
                let turn = try await stage.seat.acquire()
                let reference = try await liveObservation(stage.seat)
                let outcome = try await stage.seat.withContextMenu(
                    openedAt: point, observation: reference, turn: turn
                ) { interaction in
                    let open = (try? probeState()["menuOpen"] as? Bool) == true
                    print("QT6_MENU open=\(open) window=\(interaction.menu.window.windowNumber)"
                        + " frame=\(interaction.menu.frame)")
                    switch await interaction.observe() {
                        case .success(let delivery):
                            print("QT6_MENU capture=qualified"
                                + " pixels=\(delivery.frame.geometry.pixelSize)")
                            do {
                                let actionReady = LivePump.run(until: {
                                    (try? probeState()["menuChoiceFrame"] as? [NSNumber])?.count == 4
                                }, timeout: 1)
                                guard actionReady,
                                      let action = try probeState()["menuChoiceFrame"] as? [NSNumber]
                                else {
                                    Issue.record("Qt did not publish the menu action geometry")
                                    return
                                }
                                let actionPoint = try #require(InputLocation(
                                    screenPoint: CGPoint(
                                        x: action[0].doubleValue + action[2].doubleValue / 2,
                                        y: action[1].doubleValue + action[3].doubleValue / 2
                                    ),
                                    observedIn: delivery.geometry
                                ))
                                let choice = try await interaction.send(
                                    .click(actionPoint), observation: delivery.reference
                                )
                                print("QT6_MENU choice-events=\(choice.eventCount)"
                                    + " action-frame=\(action)")
                            } catch {
                                Issue.record("Qt menu item could not be selected: \(error)")
                            }
                        case .failure(let reason):
                            Issue.record("Qt menu surface could not be observed: \(reason)")
                    }
                }
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                let rightClicks = (try probeState()["rightClicks"] as? NSNumber)?.intValue ?? -1
                let choices = (try probeState()["menuChoices"] as? NSNumber)?.intValue ?? -1
                let stillOpen = (try probeState()["menuOpen"] as? Bool) == true
                print("QT6_MENU cleanup=\(outcome.cleanup)"
                    + " right-clicks=\(previousRightClicks)->\(rightClicks)"
                    + " choices=\(previousChoices)->\(choices)"
                    + " still-open=\(stillOpen)")
                #expect(stage.virtualBounds.contains(outcome.menu.frame))
                #expect(rightClicks == previousRightClicks + 1)
                #expect(choices == previousChoices + 1)
                #expect(!stillOpen)
                switch outcome.cleanup {
                    case .verifiedClosed: break
                    case .notVerified(let reason): Issue.record("Qt 6 menu not closed: \(reason)")
                }
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                if physicalEvents == 0 { #expect(UserSeatState.capture() == personBefore) }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let result = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6_MENU release=\(result)")
                #expect(result == .returned)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "background commands change Qt widget state without changing the User Seat",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func widgetCommands() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let statePath = target.statePath
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func number(_ key: String) -> Int {
            (try? state()[key] as? NSNumber)?.intValue ?? -1
        }

        func string(_ key: String) -> String {
            (try? state()[key] as? String) ?? ""
        }

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
            try #require(
                personBefore.frontmostProcessID != processID,
                "The Qt fixture must be in the background before the seat adopts it"
            )
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                print("QT6 after-stage=\(UserSeatState.capture())"
                    + " recovery=\(String(describing: stage.seat.lastFocusRecovery))")
                let geometryReady = LivePump.run(until: {
                    guard let frame = try? state()["textFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(geometryReady, "Qt did not publish staged widget geometry")

                @MainActor
                func point(_ key: String, x: CGFloat = 0.5, y: CGFloat = 0.5) throws -> InputLocation {
                    let candidate = try state()[key] as? [NSNumber]
                    let values = try #require(candidate)
                    try #require(values.count == 4)
                    let screenPoint = CGPoint(
                        x: values[0].doubleValue + values[2].doubleValue * x,
                        y: values[1].doubleValue + values[3].doubleValue * y
                    )
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let observation = try #require(WindowGeometryProbe.observation(of: server))
                    return try #require(InputLocation(
                        screenPoint: screenPoint, observedIn: observation
                    ))
                }

                @MainActor
                func send(
                    _ command: InputCommand,
                    until effect: @MainActor () -> Bool
                ) async throws -> Bool {
                    let turn = try await stage.seat.acquire()
                    var posted: InputReceipt?
                    do {
                        let reference = try await liveObservation(stage.seat)
                        let receipt = try await stage.seat.send(
                            command, observation: reference, turn: turn, platform: QtPlatform()
                        )
                        posted = receipt
                        let changed = LivePump.run(until: { effect() }, timeout: 2)
                        print("QT6 kind=\(command.kind) effect=\(changed)"
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

                let buttonBefore = number("clicks")
                #expect(try await send(.click(point("buttonFrame")), until: {
                    number("clicks") == buttonBefore + 1
                }))

                let scrollBefore = number("scroll")
                #expect(try await send(.scroll(point("scrollFrame"), deltaY: -4), until: {
                    number("scroll") > scrollBefore
                }))

                let sliderBefore = number("slider")
                #expect(try await send(.drag(from: point("sliderFrame", x: 0.1),
                                             to: point("sliderFrame", x: 0.8)), until: {
                    number("slider") > sliderBefore
                }))

                let field = try WindowReader.windowSnapshot(
                    processID: processID, windowNumber: window.id,
                    allowUnvalidatedBuild: true
                ).axTree.first { $0.role == "AXTextField" && $0.description == "Probe Text" }
                print("QT6 field-ax=\(String(describing: field?.frame))"
                    + " fixture-frame=\(String(describing: try state()["textFrame"]))")
                #expect(try await send(.click(point("textFrame")), until: {
                    (try? WindowReader.windowSnapshot(
                        processID: processID, windowNumber: window.id,
                        allowUnvalidatedBuild: true
                    ).axTree.first(where: { $0.description == "Probe Text" })?.isFocused) == true
                }))

                #expect(try await send(.insertText("qt6bulk"), until: {
                    string("text") == "qt6bulk"
                }))
                #expect(try await send(.text("é🧪"), until: {
                    string("text") == "qt6bulké🧪"
                }))
                #expect(try await send(.key(virtualKey: 51, text: ""), until: {
                    string("text") == "qt6bulké"
                }))

                let doubleBefore = number("doubleClicks")
                #expect(try await send(.click(point("textFrame", x: 0.2), count: 2), until: {
                    number("doubleClicks") > doubleBefore
                }))

                let keyBefore = number("keyDowns")
                let heldTurn = try await stage.seat.acquire()
                do {
                    for (phase, expected) in [
                        (KeyPhase.down, 1),
                        (.repeated(count: 3), 4),
                        (.up, 4),
                    ] {
                        let reference = try await liveObservation(stage.seat)
                        let receipt = try await stage.seat.send(
                            .key(virtualKey: 124, text: "", phase: phase),
                            observation: reference, turn: heldTurn, platform: QtPlatform()
                        )
                        let counted = LivePump.run(until: {
                            number("keyDowns") == keyBefore + expected
                        }, timeout: 2)
                        print("QT6 key-phase=\(phase) count=\(number("keyDowns"))"
                            + " events=\(receipt.eventCount)")
                        try stage.seat.confirm(receipt, counted ? .observed : .absent)
                        try #require(counted, "Qt did not receive the expected key phase")
                    }
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(heldTurn)
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(heldTurn)
                    throw error
                }

                let personAfter = UserSeatState.capture()
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                print("QT6 user-seat-before=\(personBefore) after=\(personAfter)"
                    + " physical-events=\(physicalEvents)")
                if physicalEvents == 0 { #expect(personAfter == personBefore) }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6 release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }
}
