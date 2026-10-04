//
//  QtFixtureLiveTests.swift
//  AgentSeatKit
//

import AppKit
import Carbon
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

    init(scriptName: String = "QtProbe.py") throws {
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
            .appendingPathComponent("Tools/Driver/" + scriptName)
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
        "Qt native QDrag delivers the exact owned MIME payload to another widget",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func nativeDrag() async throws {
        let target = try QtProbeTarget(scriptName: "QtNativeDragProbe.py")
        defer { target.stop() }
        let original = try WindowReader.windowSnapshot(
            processID            : target.processID,
            allowUnvalidatedBuild: true
        )
        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        try #require(try state()["fixture"] as? String == "qt-native-drag")
        let payload = try #require(try state()["payload"] as? String)
        try #require(payload.hasPrefix("mecum-native-drag-") && payload.count > 32)
        var failure: (any Error)?
        try await LiveStage.run(
            needsFixture : false,
            needsChrome  : false,
            configuration: SeatHostConfiguration(
                restoresUserFocus            : true,
                allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let physicalBefore = stage.fence.snapshot().observedEventCount
            let person = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                try #require(person.frontmostProcessID != target.processID)
                adopted = try await stage.seat.adopt(
                    original.reference,
                    platform: QtPlatform(),
                    title   : original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let contained = await LivePump.settle(until: {
                    guard let values = try? state()["destinationFrame"] as? [NSNumber], values.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGRect(
                        x     : values[0].doubleValue,
                        y     : values[1].doubleValue,
                        width : values[2].doubleValue,
                        height: values[3].doubleValue
                    ))
                }, timeout: 3)
                try #require(contained)
                @MainActor
                func point(_ name: String) throws -> InputLocation {
                    let values = try #require(state()[name + "Frame"] as? [NSNumber])
                    try #require(values.count == 4)
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    return try #require(InputLocation(
                        screenPoint: CGPoint(
                            x: values[0].doubleValue + values[2].doubleValue / 2,
                            y: values[1].doubleValue + values[3].doubleValue / 2
                        ),
                        observedIn: geometry
                    ))
                }
                let turn = try await stage.seat.acquire()
                var posted: InputReceipt?
                do {
                    let observation = try await liveObservation(stage.seat)
                    try #require(observation.surface.windowNumber == window.id)
                    let receipt = try await stage.seat.send(
                        .drag(
                            from: point("source"),
                            to  : point("destination")
                        ),
                        observation: observation,
                        turn       : turn
                    )
                    posted = receipt
                    let transferred = await LivePump.settle(until: {
                        guard let value = try? state() else { return false }
                        return (value["presses"] as? NSNumber)?.intValue == 1
                            && (value["dragStarted"] as? NSNumber)?.intValue == 1
                            && (value["enters"] as? NSNumber)?.intValue ?? 0 > 0
                            && (value["drops"] as? NSNumber)?.intValue == 1
                            && value["received"] as? String == payload
                            && value["dragFinished"] as? Bool == true
                            && (value["dragResult"] as? NSNumber)?.intValue == 1
                    }, timeout: 3)
                    try stage.seat.confirm(receipt, transferred ? .observed : .absent)
                    posted = nil
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(turn)
                    let data = try JSONSerialization.data(
                        withJSONObject: state(),
                        options       : .sortedKeys
                    )
                    print("QT_NATIVE_DRAG effect=\(transferred) preparation=\(receipt.preparation)"
                        + " state=\(String(decoding: data, as: UTF8.self))")
                    try #require(transferred, "Native QDrag did not transfer the owned payload")
                } catch {
                    if let posted { try? stage.seat.confirm(posted, .unknown) }
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(turn)
                    throw error
                }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT_NATIVE_DRAG release=\(outcome)")
                #expect(outcome == .returned)
            }
            let physical = stage.fence.snapshot().observedEventCount - physicalBefore
            let unchanged = UserSeatState.capture() == person
            print("QT_NATIVE_DRAG physical-events=\(physical) user-seat-preserved=\(unchanged)")
            #expect(physical == 0)
            #expect(unchanged)
        }
        if let failure { throw failure }
    }

    @Test(
        "Qt Quick text, scrolling and an internal cross-item drop have independent effects",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func quickCommands() async throws {
        try await runQuickCommands(includingComposition: false)
    }

    @Test(
        "Qt Quick preserves native dead-key preedit through commit",
        .enabled(
            if: qtFixtureSkipReason() == nil
                && ProcessInfo.processInfo.environment["AGENTSEAT_QT_IME_TESTS"] == "1",
            "AGENTSEAT_QT_IME_TESTS=1 and the Qt fixture prerequisites are required"))
    func inputMethodComposition() async throws {
        try await runQuickCommands(includingComposition: true)
    }

    private enum CompositionEnding {
        case commit
        case deadline
        case cancellation
    }

    @Test(
        "Qt native composition expires while the consumer is still waiting",
        .enabled(
            if: qtFixtureSkipReason() == nil
                && ProcessInfo.processInfo.environment["AGENTSEAT_QT_IME_TESTS"] == "1",
            "AGENTSEAT_QT_IME_TESTS=1 and the Qt fixture prerequisites are required"))
    func inputMethodDeadline() async throws {
        try await runQuickCommands(includingComposition: true, ending: .deadline)
    }

    @Test(
        "Qt native composition restores after cancellation with marked text open",
        .enabled(
            if: qtFixtureSkipReason() == nil
                && ProcessInfo.processInfo.environment["AGENTSEAT_QT_IME_TESTS"] == "1",
            "AGENTSEAT_QT_IME_TESTS=1 and the Qt fixture prerequisites are required"))
    func inputMethodCancellation() async throws {
        try await runQuickCommands(includingComposition: true, ending: .cancellation)
    }

    private func runQuickCommands(
        includingComposition: Bool,
        ending              : CompositionEnding = .commit
    ) async throws {
        var composition: (sourceID: String, dead: CGKeyCode, commit: CGKeyCode)?
        if includingComposition {
            guard let resolved = nativeDeadKeySequence() else {
                throw LiveFailure.unsupported(
                    "The Qt composition row requires a current keyboard layout with an acute dead key"
                )
            }
            composition = resolved
        }
        let target = try QtProbeTarget(scriptName: "QtQuickProbe.py")
        defer { target.stop() }
        let original = try WindowReader.windowSnapshot(
            processID: target.processID, allowUnvalidatedBuild: true
        )
        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        try #require(try state()["fixture"] as? String == "qt-quick")
        var failure: (any Error)?
        try await LiveStage.run(
            needsFixture: false,
            needsChrome: false,
            configuration: SeatHostConfiguration(
                restoresUserFocus: true, allowUnvalidatedFocusRecovery: true
            )
        ) { stage in
            let physicalBefore = stage.fence.snapshot().observedEventCount
            let person = UserSeatState.capture()
            var adopted: AdoptedWindow?
            do {
                try #require(person.frontmostProcessID != target.processID)
                adopted = try await stage.seat.adopt(original.reference, platform: QtPlatform(),
                                                     title: original.windowTitle)
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                let ready = await LivePump.settle(until: {
                    guard let values = try? state()["fieldFrame"] as? [NSNumber], values.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGRect(
                        x: values[0].doubleValue, y: values[1].doubleValue,
                        width: values[2].doubleValue, height: values[3].doubleValue
                    ))
                }, timeout: 3)
                try #require(ready, "Qt Quick did not publish contained item geometry")

                @MainActor
                func point(_ name: String) throws -> InputLocation {
                    let values = try #require(state()[name + "Frame"] as? [NSNumber])
                    try #require(values.count == 4)
                    let server = try #require(WindowServerProbe.geometry(of: window.id))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    return try #require(InputLocation(
                        screenPoint: CGPoint(x: values[0].doubleValue + values[2].doubleValue / 2,
                                             y: values[1].doubleValue + values[3].doubleValue / 2),
                        observedIn: geometry
                    ))
                }

                var compositionTurn: Turn?
                @MainActor
                func send(_ command: InputCommand, effect: @MainActor () throws -> Bool) async throws {
                    let ownsTurn = compositionTurn == nil
                    let turn: Turn
                    if let active = compositionTurn { turn = active }
                    else { turn = try await stage.seat.acquire() }
                    var posted: InputReceipt?
                    do {
                        let observation = try await liveObservation(stage.seat)
                        try #require(observation.surface.windowNumber == window.id)
                        let receipt = try await stage.seat.send(command, observation: observation, turn: turn)
                        posted = receipt
                        let changed = await LivePump.settle(until: { (try? effect()) == true }, timeout: 2)
                        try stage.seat.confirm(receipt, changed ? .observed : .absent)
                        posted = nil
                        _ = await stage.seat.concludeObservation()
                        if ownsTurn { try stage.seat.release(turn) }
                        print("QT_QUICK command=\(command.kind) effect=\(changed) events=\(receipt.eventCount)"
                            + " preparation=\(receipt.preparation)")
                        if !changed {
                            let data = try JSONSerialization.data(withJSONObject: state(), options: .sortedKeys)
                            print("QT_QUICK unexpected-state=\(String(decoding: data, as: UTF8.self))")
                        }
                        try #require(changed)
                    } catch {
                        if let posted { try? stage.seat.confirm(posted, .unknown) }
                        _ = await stage.seat.concludeObservation()
                        if ownsTurn { try? stage.seat.release(turn) }
                        throw error
                    }
                }

                if composition == nil {
                    try await send(.click(point("button"))) { (try state()["clicks"] as? NSNumber)?.intValue == 1 }
                }
                try await send(.click(point("field"))) { try state()["activeFocus"] as? Bool == true }
                if let composition {
                    let turn = try await stage.seat.acquire()
                    compositionTurn = turn
                    do {
                        let entry = try await liveObservation(stage.seat)
                        var isBodyWaiting = false
                        @MainActor @Sendable
                        func body() async throws {
                            try await send(.key(
                                virtualKey: composition.dead,
                                text      : "",
                                modifiers : .option
                            )) {
                                let value = try state()
                                return value["text"] as? String == ""
                                    && value["inputMethodComposing"] as? Bool == true
                                    && (value["preeditText"] as? String)?.isEmpty == false
                            }
                            switch ending {
                            case .commit:
                                try await send(.key(
                                    virtualKey: composition.commit,
                                    text      : ""
                                )) {
                                    let value = try state()
                                    return value["text"] as? String == "é"
                                        && value["inputMethodComposing"] as? Bool == false
                                        && value["preeditText"] as? String == ""
                                }
                            case .deadline:
                                try await Task.sleep(for: .seconds(2))
                                try #require(try state()["applicationState"] as? String == "ApplicationInactive")
                                let late = try await liveObservation(stage.seat)
                                let eventsBefore = try #require(state()["inputMethodEvents"] as? [[String: Any]]).count
                                await #expect(throws: InputFailure.nativeTextInputRefused(.contextClosed)) {
                                    try await stage.seat.send(
                                        .key(virtualKey: composition.commit, text: ""),
                                        observation: late,
                                        turn       : turn
                                    )
                                }
                                try #require(try (state()["inputMethodEvents"] as? [[String: Any]])?.count == eventsBefore)
                            case .cancellation:
                                isBodyWaiting = true
                                try await Task.sleep(for: .seconds(5))
                            }
                        }
                        let budget: Duration = ending == .deadline ? .milliseconds(1500) : .seconds(3)
                        let operation = Task { @MainActor in
                            try await stage.seat.withNativeTextInput(
                                observation: entry,
                                turn       : turn,
                                within     : budget,
                                operation  : body
                            )
                        }
                        defer { operation.cancel() }
                        if ending == .cancellation {
                            let waiting = await LivePump.settle(until: { isBodyWaiting }, timeout: 2)
                            try #require(waiting, "Cancellation did not reach a live native preedit")
                            operation.cancel()
                        }
                        let cleanup: InputCleanupResult
                        switch await operation.result {
                        case .success(let result):
                            try #require(ending == .commit)
                            cleanup = result
                        case .failure(let error):
                            let failure = try #require(error as? NativeTextInputFailure)
                            if ending == .deadline {
                                try #require(failure.cause as? InputFailure == .nativeTextInputRefused(.contextClosed))
                            } else if ending == .cancellation {
                                try #require(failure.cause is CancellationError)
                            } else { throw error }
                            cleanup = failure.cleanup
                        }
                        compositionTurn = nil
                        try #require(cleanup == .succeeded)
                        let inactive = await LivePump.settle(until: {
                            (try? state()["applicationState"] as? String) == "ApplicationInactive"
                        }, timeout: 2)
                        try #require(inactive, "The native input context did not restore Qt's inactive state")
                        try stage.seat.release(turn)
                    } catch {
                        compositionTurn = nil
                        try? stage.seat.release(turn)
                        throw error
                    }
                    print("QT_COMPOSITION source=\(composition.sourceID) dead=\(composition.dead)"
                        + " commit=\(composition.commit) ending=\(ending) native-context-restored=true")
                    try #require(nativeDeadKeySequence()?.sourceID == composition.sourceID)
                } else {
                    try await send(.text("é🧪")) { try state()["text"] as? String == "é🧪" }
                    try await send(.insertText(" qml bulk")) {
                        let value = try state()
                        return value["text"] as? String == "é🧪 qml bulk" && value["activeFocus"] as? Bool == true
                    }
                    try await send(.key(virtualKey: 123, text: "", modifiers: .shift)) {
                        try state()["selectedText"] as? String == "k"
                    }
                    try await send(.scroll(point("scroll"), deltaY: -4)) {
                        (try state()["scroll"] as? NSNumber)?.doubleValue ?? 0 > 0
                    }
                    let initialSource = try #require(state()["sourceFrame"] as? [NSNumber])
                    try await send(.drag(from: point("source"), to: point("destination"))) {
                        let value = try state()
                        guard let source = value["sourceFrame"] as? [NSNumber], source.count == 4,
                              let destination = value["destinationFrame"] as? [NSNumber], destination.count == 4
                        else { return false }
                        let destinationBody = CGRect(
                            x: destination[0].doubleValue, y: destination[1].doubleValue,
                            width: destination[2].doubleValue, height: destination[3].doubleValue
                        )
                        let sourceHotSpot = CGPoint(x: source[0].doubleValue + source[2].doubleValue / 2,
                                                    y: source[1].doubleValue + source[3].doubleValue / 2)
                        return (value["drops"] as? NSNumber)?.intValue == 1
                            && (value["dragEnters"] as? NSNumber)?.intValue ?? 0 > 0
                            && (value["dragReleases"] as? NSNumber)?.intValue == 1
                            && source[0].doubleValue > initialSource[0].doubleValue + 250
                            && destinationBody.contains(sourceHotSpot)
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: state(), options: .sortedKeys)
                print("QT_QUICK state=\(String(decoding: data, as: UTF8.self))")
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT_QUICK release=\(outcome)")
                #expect(outcome == .returned)
            }
            let physical = stage.fence.snapshot().observedEventCount - physicalBefore
            let unchanged = UserSeatState.capture() == person
            print("QT_QUICK isolation physical-events=\(physical) user-seat-preserved=\(unchanged)")
            #expect(physical == 0)
            #expect(unchanged)
        }
        if let failure { throw failure }
    }

    @Test(
        "a native Qt file dialog is followed and cancelled without selecting a file",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func nativeFileDialog() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

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
                let openerReady = LivePump.run(until: {
                    guard let frame = try? state()["nativeFileOpenFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(openerReady)
                let frame = try #require(state()["nativeFileOpenFrame"] as? [NSNumber])
                let server = try #require(WindowServerProbe.geometry(of: window.id))
                let geometry = try #require(WindowGeometryProbe.observation(of: server))
                let location = try #require(InputLocation(
                    screenPoint: CGPoint(
                        x: frame[0].doubleValue + frame[2].doubleValue / 2,
                        y: frame[1].doubleValue + frame[3].doubleValue / 2
                    ),
                    observedIn: geometry
                ))
                var firstVisiblePanelFrame: CGRect?
                var physicalVisiblePanelSamples = 0
                let sampler = Task { @MainActor in
                    while !Task.isCancelled {
                        let surfaces = WindowServerProbe.surfaces(
                            ownedBy              : Set([processID]),
                            allowUnvalidatedBuild: true
                        ) ?? []
                        for surface in surfaces where surface.level == 8 && surface.isVisible
                            && surface.reference.windowNumber != window.id {
                            if firstVisiblePanelFrame == nil { firstVisiblePanelFrame = surface.reference.frame }
                            if !stage.virtualBounds.contains(surface.reference.frame) {
                                physicalVisiblePanelSamples += 1
                            }
                        }
                        do { try await Task.sleep(for: .milliseconds(10)) }
                        catch { return }
                    }
                }
                defer { sampler.cancel() }
                let turn = try await stage.seat.acquire()
                let reference = try await liveObservation(stage.seat)
                let receipt = try await stage.seat.send(
                    .click(location), observation: reference, turn: turn, platform: QtPlatform()
                )
                let opened = LivePump.run(until: {
                    (try? state()["fileDialogOpen"] as? Bool) == true
                        && (try? state()["fileDialogMode"] as? String) == "native"
                }, timeout: 4)
                try stage.seat.confirm(receipt, opened ? .observed : .absent)
                _ = await stage.seat.concludeObservation()
                try stage.seat.release(turn)
                try #require(opened)

                let searchStarted = DispatchTime.now().uptimeNanoseconds
                var firstSurfaceAt: UInt64?
                var firstSurfaceFollowScans: Int?
                var panelWindowNumber: Int?
                let foundPanel = await LivePump.settle(until: {
                    let surfaces = WindowServerProbe.surfaces(
                        ownedBy: Set([processID]), allowUnvalidatedBuild: true
                    ) ?? []
                    for surface in surfaces where surface.level == 8
                        && surface.reference.windowNumber != window.id {
                        if firstSurfaceAt == nil {
                            firstSurfaceAt = DispatchTime.now().uptimeNanoseconds
                            firstSurfaceFollowScans = stage.seat.windowFollowScanCount
                        }
                        panelWindowNumber = surface.reference.windowNumber
                        return true
                    }
                    return false
                }, timeout: 3)
                try #require(foundPanel, "Qt did not publish the native file panel")
                let panelNumber = try #require(panelWindowNumber)
                let autoContained = await LivePump.settle(until: {
                    guard stage.seat.adoptedWindows.contains(where: {
                        $0.id == panelNumber
                    }), let surface = WindowServerProbe.geometry(of: panelNumber)
                    else { return false }
                    return stage.virtualBounds.contains(surface.frame)
                }, timeout: 1.1)
                let autoCheckedAt = DispatchTime.now().uptimeNanoseconds
                let visibleToAutoCheckMS = firstSurfaceAt.map {
                    Int((autoCheckedAt - $0) / 1_000_000)
                } ?? -1
                print("QT6_NATIVE_FILE auto-contained=\(autoContained)"
                    + " visible-to-auto-check-ms=\(visibleToAutoCheckMS)"
                    + " follow-scans=\(stage.seat.windowFollowScanCount)")
                #expect(autoContained, "Qt window follower did not automatically contain the native panel")
                sampler.cancel()
                print("QT6_NATIVE_FILE first-visible-frame=\(String(describing: firstVisiblePanelFrame))"
                    + " physical-visible-samples=\(physicalVisiblePanelSamples)")
                if ProcessInfo.processInfo.environment["AGENTSEAT_QT_PANEL_BIRTH_TESTS"] == "1" {
                    #expect(
                        firstVisiblePanelFrame.map(stage.virtualBounds.contains) == true
                            && physicalVisiblePanelSamples == 0,
                        "The native Qt panel became visible outside the Virtual Display"
                    )
                }
                let panel = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: panelNumber,
                    allowUnvalidatedBuild: true
                )
                try #require(panel.windowTitle == "Probe Native File Dialog")
                let panelProcesses = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService"
                ).map(\.processIdentifier)
                let allPIDs = Set(panelProcesses + [processID])
                let surfaces = WindowServerProbe.surfaces(
                    ownedBy: allPIDs, allowUnvalidatedBuild: true
                ) ?? []
                for surface in surfaces {
                    print("QT6_NATIVE_FILE owner=\(surface.reference.processID)"
                        + " window=\(surface.reference.windowNumber)"
                        + " level=\(surface.level) visible=\(surface.isVisible)"
                        + " frame=\(surface.reference.frame)")
                }
                let panelAttestedAt = DispatchTime.now().uptimeNanoseconds
                let firstSurfaceMS = firstSurfaceAt.map {
                    Int(($0 - searchStarted) / 1_000_000)
                } ?? -1
                let panelAttestedMS = Int((panelAttestedAt - searchStarted) / 1_000_000)
                print("QT6_NATIVE_FILE first-surface-ms=\(firstSurfaceMS)"
                    + " panel-attested-ms=\(panelAttestedMS)"
                    + " first-surface-follow-scans=\(firstSurfaceFollowScans ?? -1)"
                    + " follow-scans=\(stage.seat.windowFollowScanCount)")
                print("QT6_NATIVE_FILE panel-service-count=\(panelProcesses.count)"
                    + " parent=\(window.id)"
                    + " adopted=\(stage.seat.adoptedWindows.map(\.id))"
                    + " person=\(UserSeatState.capture())")
                let currentPanelFrame = try #require(
                    WindowServerProbe.geometry(of: panel.windowNumber)
                ).frame
                if !stage.virtualBounds.contains(currentPanelFrame) {
                    print("QT6_NATIVE_FILE physical-panel=\(panel.windowFrame)"
                        + " attempting-exact-adoption=\(panel.windowNumber)")
                    let ownedPanel: AdoptedWindow
                    if let existing = stage.seat.adoptedWindows.first(where: {
                        $0.id == panel.windowNumber
                    }) {
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
                let panelContainedAt = DispatchTime.now().uptimeNanoseconds
                let containmentMS = Int((panelContainedAt - searchStarted) / 1_000_000)
                let moveAndStageMS = Int((panelContainedAt - panelAttestedAt) / 1_000_000)
                print("QT6_NATIVE_FILE containment-ms=\(containmentMS)"
                    + " move-and-stage-ms=\(moveAndStageMS)")
                let placedPanel = try WindowReader.windowSnapshot(
                    processID: processID,
                    windowNumber: panel.windowNumber,
                    allowUnvalidatedBuild: true
                )
                let placedServer = try #require(WindowServerProbe.geometry(of: panel.windowNumber))
                try #require(stage.virtualBounds.contains(placedServer.frame))
                let cancel = try #require(placedPanel.axTree.first {
                    $0.role == "AXButton" && $0.title == "Cancel"
                })
                let cancelFrame = try #require(cancel.frame)
                print("QT6_NATIVE_FILE panel=\(panel.windowNumber)"
                    + " cancel-frame=\(cancelFrame)")
                let panelServer = try #require(WindowServerProbe.geometry(of: panel.windowNumber))
                let panelGeometry = try #require(WindowGeometryProbe.observation(of: panelServer))
                let cancelPoint = try #require(InputLocation(
                    screenPoint: CGPoint(x: cancelFrame.midX, y: cancelFrame.midY),
                    observedIn: panelGeometry
                ))
                let followed = await LivePump.settle(until: {
                    stage.seat.adoptedWindows.contains { $0.id == panel.windowNumber }
                }, timeout: 5)
                try #require(followed)
                print("QT6_NATIVE_FILE selected=\(String(describing: stage.seat.currentTarget?.id))"
                    + " panel=\(panel.windowNumber)")
                let cancelTurn = try await stage.seat.acquire()
                do {
                    let cancelReference = try await liveObservation(stage.seat)
                    let cancellation = try await stage.seat.send(
                        .click(cancelPoint), observation: cancelReference,
                        turn: cancelTurn, platform: QtPlatform()
                    )
                    let closed = LivePump.run(until: {
                        (try? state()["fileDialogOpen"] as? Bool) == false
                    }, timeout: 4)
                    try stage.seat.confirm(cancellation, closed ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(cancelTurn)
                    try #require(closed)
                    #expect((try state()["fileDialogAccepted"] as? Bool) == false)
                    print("QT6_NATIVE_FILE closed=\(closed) events=\(cancellation.eventCount)")
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(cancelTurn)
                    throw error
                }
            } catch {
                try? target.sendNativeCommand("closeFileDialog")
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let parent {
                for child in stage.seat.adoptedWindows where child.id != parent.id {
                    _ = await stage.seat.release(child, .leaveOnVirtualDisplay)
                }
                let outcome = await stage.seat.release(parent, .returnToUserSeat)
                print("QT6_NATIVE_FILE release=\(outcome)"
                    + " person-after=\(UserSeatState.capture())")
                #expect(outcome == .returned)
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                if physicalEvents == 0 {
                    #expect(UserSeatState.capture() == personBefore)
                }
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "a Qt 6 widget file dialog is followed and cancelled without selecting a file",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func widgetFileDialog() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func location(_ frameKey: String, in windowNumber: Int) throws -> InputLocation {
            let frame = try #require(state()[frameKey] as? [NSNumber])
            try #require(frame.count == 4)
            let server = try #require(WindowServerProbe.geometry(of: windowNumber))
            let geometry = try #require(WindowGeometryProbe.observation(of: server))
            return try #require(InputLocation(
                screenPoint: CGPoint(
                    x: frame[0].doubleValue + frame[2].doubleValue / 2,
                    y: frame[1].doubleValue + frame[3].doubleValue / 2
                ),
                observedIn: geometry
            ))
        }

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
            var dialog: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                parent = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = parent, !stage.seat.isStaged(window) {
                    parent = try await stage.seat.stage(window)
                }
                let window = try #require(parent)
                let openerReady = LivePump.run(until: {
                    guard let frame = try? state()["fileOpenFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(openerReady)

                let openTurn = try await stage.seat.acquire()
                do {
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(try location("fileOpenFrame", in: window.id)),
                        observation: reference, turn: openTurn, platform: QtPlatform()
                    )
                    let opened = LivePump.run(until: {
                        (try? state()["fileDialogOpen"] as? Bool) == true
                    }, timeout: 3)
                    try stage.seat.confirm(receipt, opened ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(openTurn)
                    try #require(opened)
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(openTurn)
                    throw error
                }

                var observed: ObservedWindow?
                let discovered = LivePump.run(until: {
                    let surfaces = WindowServerProbe.surfaces(
                        ownedBy: Set([processID]), allowUnvalidatedBuild: true
                    ) ?? []
                    observed = surfaces.lazy
                        .filter { $0.reference.windowNumber != window.id && $0.isVisible }
                        .compactMap { surface in
                            try? WindowReader.windowSnapshot(
                                processID: processID,
                                windowNumber: surface.reference.windowNumber,
                                allowUnvalidatedBuild: true
                            )
                        }
                        .first { $0.windowTitle == "Probe Widget File Dialog" }
                    return observed != nil
                }, timeout: 4)
                try #require(discovered)
                let child = try #require(observed)
                let followed = await LivePump.settle(until: {
                    stage.seat.adoptedWindows.contains { $0.id == child.windowNumber }
                }, timeout: 10)
                try #require(followed)
                guard let adopted = stage.seat.adoptedWindows.first(where: {
                    $0.id == child.windowNumber
                }) else {
                    throw LiveFailure.unsupported("The Qt widget file dialog was not adopted")
                }
                dialog = adopted
                let server = try #require(WindowServerProbe.geometry(of: adopted.id))
                print("QT6_FILE_DIALOG window=\(adopted.id) frame=\(server.frame)")
                try #require(stage.virtualBounds.contains(server.frame))
                let cancelReady = LivePump.run(until: {
                    (try? state()["fileCancelFrame"] as? [NSNumber])?.count == 4
                }, timeout: 3)
                try #require(cancelReady)

                let cancelTurn = try await stage.seat.acquire()
                do {
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(try location("fileCancelFrame", in: adopted.id)),
                        observation: reference, turn: cancelTurn, platform: QtPlatform()
                    )
                    let closed = LivePump.run(until: {
                        (try? state()["fileDialogOpen"] as? Bool) == false
                    }, timeout: 3)
                    try stage.seat.confirm(receipt, closed ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(cancelTurn)
                    try #require(closed)
                    #expect((try state()["fileDialogAccepted"] as? Bool) == false)
                    print("QT6_FILE_DIALOG cancelled=\(closed) events=\(receipt.eventCount)")
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(cancelTurn)
                    throw error
                }
                let childRelease = await stage.seat.release(adopted, .leaveOnVirtualDisplay)
                dialog = nil
                print("QT6_FILE_DIALOG child-release=\(childRelease)")
                #expect(childRelease == .leftOnVirtualDisplay)
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                let personAfter = UserSeatState.capture()
                print("QT6_FILE_DIALOG physical-events=\(physicalEvents)"
                    + " user-seat-before=\(personBefore) after=\(personAfter)")
                if physicalEvents == 0 { #expect(personAfter == personBefore) }
            } catch {
                try? target.sendNativeCommand("closeFileDialog")
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let dialog { _ = await stage.seat.release(dialog, .leaveOnVirtualDisplay) }
            if let parent {
                let outcome = await stage.seat.release(parent, .returnToUserSeat)
                print("QT6_FILE_DIALOG release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "two Qt 6 windows can switch the observed target without taking the User Seat",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func switchTargets() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func location(_ frameKey: String, in windowNumber: Int) throws -> InputLocation {
            let frame = try #require(state()[frameKey] as? [NSNumber])
            try #require(frame.count == 4)
            let server = try #require(WindowServerProbe.geometry(of: windowNumber))
            let geometry = try #require(WindowGeometryProbe.observation(of: server))
            return try #require(InputLocation(
                screenPoint: CGPoint(
                    x: frame[0].doubleValue + frame[2].doubleValue / 2,
                    y: frame[1].doubleValue + frame[3].doubleValue / 2
                ),
                observedIn: geometry
            ))
        }

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
            var second: AdoptedWindow?
            do {
                try #require(personBefore.frontmostProcessID != processID)
                parent = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = parent, !stage.seat.isStaged(window) {
                    parent = try await stage.seat.stage(window)
                }
                let window = try #require(parent)
                let frameReady = LivePump.run(until: {
                    guard let frame = try? state()["secondOpenFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(frameReady)

                @MainActor
                func click(
                    _ frameKey: String,
                    in windowNumber: Int,
                    until effect: @MainActor () -> Bool
                ) async throws {
                    let turn = try await stage.seat.acquire()
                    do {
                        let reference = try await liveObservation(stage.seat)
                        let receipt = try await stage.seat.send(
                            .click(try location(frameKey, in: windowNumber)),
                            observation: reference, turn: turn, platform: QtPlatform()
                        )
                        let changed = LivePump.run(until: effect, timeout: 3)
                        try stage.seat.confirm(receipt, changed ? .observed : .absent)
                        _ = await stage.seat.concludeObservation()
                        try stage.seat.release(turn)
                        try #require(changed)
                    } catch {
                        _ = await stage.seat.concludeObservation()
                        try? stage.seat.release(turn)
                        throw error
                    }
                }

                try await click("secondOpenFrame", in: window.id) {
                    (try? state()["secondOpen"] as? Bool) == true
                }
                var opened: ObservedWindow?
                let discovered = LivePump.run(until: {
                    let surfaces = WindowServerProbe.surfaces(
                        ownedBy: Set([processID]), allowUnvalidatedBuild: true
                    ) ?? []
                    opened = surfaces.lazy
                        .filter { $0.reference.windowNumber != window.id && $0.isVisible }
                        .compactMap { surface in
                            try? WindowReader.windowSnapshot(
                                processID: processID,
                                windowNumber: surface.reference.windowNumber,
                                allowUnvalidatedBuild: true
                            )
                        }
                        .first { $0.windowTitle == "Probe Secondary" }
                    return opened != nil
                }, timeout: 3)
                try #require(discovered)
                let auxiliaryWindow = try #require(opened)
                let followed = await LivePump.settle(until: {
                    stage.seat.adoptedWindows.contains { $0.id == auxiliaryWindow.windowNumber }
                }, timeout: 10)
                try #require(followed)
                guard let auxiliary = stage.seat.adoptedWindows.first(where: {
                    $0.id == auxiliaryWindow.windowNumber
                }) else {
                    throw LiveFailure.unsupported("The secondary Qt window was not adopted")
                }
                second = auxiliary
                let switched = try await stage.seat.switchTarget(to: auxiliary)
                try #require(switched.id == auxiliary.id)
                print("QT6_SWITCH first=\(switched.id)"
                    + " current=\(String(describing: stage.seat.currentTarget?.id))")
                let auxiliaryReady = LivePump.run(until: {
                    guard let frame = try? state()["secondButtonFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(auxiliaryReady)
                try await click("secondButtonFrame", in: auxiliary.id) {
                    (try? state()["secondClicks"] as? NSNumber)?.intValue == 1
                }

                let returned = try await stage.seat.switchTarget(to: window)
                try #require(returned.id == window.id)
                try #require(stage.seat.currentTarget?.id == window.id)
                let parentReady = LivePump.run(until: {
                    guard let frame = try? state()["buttonFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(parentReady)
                try await click("buttonFrame", in: window.id) {
                    (try? state()["clicks"] as? NSNumber)?.intValue == 1
                }
                print("QT6_SWITCH second=\(returned.id)"
                    + " auxiliary-clicks=\((try state()["secondClicks"] as? NSNumber)?.intValue ?? -1)"
                    + " parent-clicks=\((try state()["clicks"] as? NSNumber)?.intValue ?? -1)")

                try target.sendNativeCommand("closeSecond")
                let closed = LivePump.run(until: {
                    (try? state()["secondOpen"] as? Bool) == false
                }, timeout: 2)
                try #require(closed)
                let childRelease = await stage.seat.release(auxiliary, .leaveOnVirtualDisplay)
                second = nil
                #expect(childRelease == .leftOnVirtualDisplay)
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                let personAfter = UserSeatState.capture()
                print("QT6_SWITCH physical-events=\(physicalEvents)"
                    + " user-seat-before=\(personBefore) after=\(personAfter)")
                if physicalEvents == 0 { #expect(personAfter == personBefore) }
            } catch {
                try? target.sendNativeCommand("closeSecond")
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let second { _ = await stage.seat.release(second, .leaveOnVirtualDisplay) }
            if let parent {
                let outcome = await stage.seat.release(parent, .returnToUserSeat)
                print("QT6_SWITCH release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "a Qt 6 modal child is followed, cancelled and removed in the background",
        .enabled(
            if: qtFixtureSkipReason() == nil,
            Comment(rawValue: qtFixtureSkipReason() ?? "")))
    func modalChild() async throws {
        let target = try QtProbeTarget()
        defer { target.stop() }
        let processID = target.processID
        let original = try WindowReader.windowSnapshot(
            processID: processID, allowUnvalidatedBuild: true
        )
        try #require(original.windowTitle == "Mecum Qt Probe")

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.statePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func location(_ frameKey: String, in windowNumber: Int) throws -> InputLocation {
            let frame = try #require(state()[frameKey] as? [NSNumber])
            try #require(frame.count == 4)
            let server = try #require(WindowServerProbe.geometry(of: windowNumber))
            let geometry = try #require(WindowGeometryProbe.observation(of: server))
            return try #require(InputLocation(
                screenPoint: CGPoint(
                    x: frame[0].doubleValue + frame[2].doubleValue / 2,
                    y: frame[1].doubleValue + frame[3].doubleValue / 2
                ),
                observedIn: geometry
            ))
        }

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
                let frameReady = LivePump.run(until: {
                    guard let frame = try? state()["modalFrame"] as? [NSNumber], frame.count == 4
                    else { return false }
                    return stage.virtualBounds.contains(CGPoint(
                        x: frame[0].doubleValue, y: frame[1].doubleValue
                    ))
                }, timeout: 3)
                try #require(frameReady)

                let openingTurn = try await stage.seat.acquire()
                do {
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(try location("modalFrame", in: window.id)),
                        observation: reference, turn: openingTurn, platform: QtPlatform()
                    )
                    let opened = LivePump.run(until: {
                        (try? state()["modalOpen"] as? Bool) == true
                    }, timeout: 3)
                    try stage.seat.confirm(receipt, opened ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(openingTurn)
                    try #require(opened)
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(openingTurn)
                    throw error
                }

                let dialog = try WindowReader.windowSnapshot(
                    processID: processID, allowUnvalidatedBuild: true
                )
                try #require(dialog.windowTitle == "Probe Modal")
                let followed = await LivePump.settle(until: {
                    stage.seat.adoptedWindows.contains { $0.id == dialog.windowNumber }
                }, timeout: 10)
                let child = try #require(stage.seat.adoptedWindows.first {
                    $0.id == dialog.windowNumber
                })
                let childServer = try #require(WindowServerProbe.geometry(of: child.id))
                print("QT6_MODAL followed=\(followed) child=\(child.id)"
                    + " frame=\(childServer.frame)")
                try #require(followed)
                try #require(stage.virtualBounds.contains(childServer.frame))
                let cancelReady = LivePump.run(until: {
                    (try? state()["modalCancelFrame"] as? [NSNumber])?.count == 4
                }, timeout: 2)
                try #require(cancelReady)

                let cancelTurn = try await stage.seat.acquire()
                do {
                    let reference = try await liveObservation(stage.seat)
                    let receipt = try await stage.seat.send(
                        .click(try location("modalCancelFrame", in: child.id)),
                        observation: reference, turn: cancelTurn, platform: QtPlatform()
                    )
                    let closed = LivePump.run(until: {
                        (try? state()["modalOpen"] as? Bool) == false
                    }, timeout: 3)
                    try stage.seat.confirm(receipt, closed ? .observed : .absent)
                    _ = await stage.seat.concludeObservation()
                    try stage.seat.release(cancelTurn)
                    print("QT6_MODAL cancelled=\(closed) events=\(receipt.eventCount)")
                    try #require(closed)
                    if let identity = child.reference.identity {
                        let presence = stage.seat.logicalSurfacePresence(of: identity)
                        print("QT6_MODAL presence=\(presence)")
                    }
                    print("QT6_MODAL server-after=\(String(describing: WindowServerProbe.geometry(of: child.id)?.frame))")
                    let childRelease = await stage.seat.release(child, .leaveOnVirtualDisplay)
                    print("QT6_MODAL child-release=\(childRelease)")
                    #expect(childRelease == .leftOnVirtualDisplay)
                    #expect(!stage.seat.adoptedWindows.contains { $0.id == child.id })
                } catch {
                    _ = await stage.seat.concludeObservation()
                    try? stage.seat.release(cancelTurn)
                    throw error
                }
                let physicalEvents = stage.fence.snapshot().observedEventCount - handBefore
                if physicalEvents == 0 {
                    #expect(UserSeatState.capture() == personBefore)
                }
            } catch {
                try? target.sendNativeCommand("closeModal")
                _ = LivePump.run(until: {
                    (try? state()["modalOpen"] as? Bool) == false
                }, timeout: 2)
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6_MODAL release=\(outcome)")
                #expect(outcome == .returned)
            }
        }
        if let failure { throw failure }
    }

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
                let report = await stage.seat.releaseAssignment()
                print("QT6_NATIVE assignment-release=\(report.outcome)"
                    + " window=\(String(describing: report.windows[adopted.id]))"
                    + " obligations=\(report.obligations.count)")
                #expect(report.isComplete)
                #expect(report.windows[adopted.id] == .returned)
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
        let verifiesSettledHome = ProcessInfo.processInfo.environment["AGENTSEAT_QT_INITIAL_POSITION"] != nil
        if verifiesSettledHome {
            try #require(MultiWindowLiveTests.stageManagerIsEnabled,
                         "The Qt geometry tier requires Stage Manager already enabled")
        }

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
            let currentHome = try WindowReader.windowSnapshot(
                processID            : processID,
                windowNumber         : original.reference.windowNumber,
                allowUnvalidatedBuild: true
            ).reference
            if verifiesSettledHome {
                print("QT_GEOMETRY discovered=\(original.reference.frame) current-home=\(currentHome.frame)")
            }
            var adopted: AdoptedWindow?
            do {
                adopted = try await stage.seat.adopt(
                    original.reference, platform: QtPlatform(), title: original.windowTitle
                )
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let window = try #require(adopted)
                if verifiesSettledHome {
                    #expect(VirtualWindowPlacementCheck.framesMatch(
                        window.originalFrame,
                        currentHome.frame
                    ))
                    print("QT_GEOMETRY owed=\(window.originalFrame)")
                }
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

                let canvasPresses = number("canvasPresses")
                #expect(try await send(.click(point("canvasFrame")), until: {
                    number("canvasPresses") == canvasPresses + 1
                        && number("canvasReleases") > 0
                }))
                let canvasScrolls = number("canvasScrolls")
                #expect(try await send(.scroll(point("canvasFrame"), deltaY: -4), until: {
                    number("canvasScrolls") == canvasScrolls + 1
                }))
                let canvasMoves = number("canvasMoves")
                let canvasReleases = number("canvasReleases")
                #expect(try await send(.drag(from: point("canvasFrame", x: 0.2),
                                             to: point("canvasFrame", x: 0.8)), until: {
                    number("canvasMoves") > canvasMoves
                        && number("canvasReleases") == canvasReleases + 1
                }))
                let canvasKeys = number("canvasKeys")
                #expect(try await send(.text("k"), until: {
                    number("canvasKeys") == canvasKeys + 1
                        && string("canvasKeyText") == "k"
                }))
                print("QT6_CANVAS presses=\(number("canvasPresses"))"
                    + " moves=\(number("canvasMoves"))"
                    + " releases=\(number("canvasReleases"))"
                    + " scrolls=\(number("canvasScrolls"))"
                    + " keys=\(number("canvasKeys"))"
                    + " last-x=\(number("canvasLastX"))")

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
                if verifiesSettledHome { #expect(physicalEvents == 0) }
            } catch {
                failure = error
            }
            _ = await stage.seat.concludeObservation()
            if let adopted {
                let outcome = await stage.seat.release(adopted, .returnToUserSeat)
                print("QT6 release=\(outcome)")
                #expect(outcome == .returned)
                if verifiesSettledHome, outcome == .returned {
                    for _ in 0..<3 {
                        try await Task.sleep(for: .milliseconds(100))
                        let body = try WindowReader.windowSnapshot(
                            processID            : processID,
                            windowNumber         : adopted.id,
                            allowUnvalidatedBuild: true
                        ).reference.frame
                        #expect(VirtualWindowPlacementCheck.framesMatch(
                            body,
                            currentHome.frame
                        ))
                        print("QT_GEOMETRY returned-body=\(body)")
                    }
                }
                if outcome == .returned && failure == nil {
                    do {
                        try stage.seat.releaseAssignedApplication()
                        print("QT6 assignment-released=true")
                    } catch { failure = error }
                }
            }
        }
        if let failure { throw failure }
    }
}
