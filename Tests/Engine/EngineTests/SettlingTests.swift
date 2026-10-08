//
//  SettlingTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// Where the act cycle waits for a gesture's effect: through the settling role when it was given
/// one, capped at the click settle, and through the fixed pause otherwise. No screen, no sleep.
@Suite("Settling after a gesture")
struct SettlingTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls

    /// A settling role that records each wait with what had happened by then.
    final class RecordingSettling: Settling, @unchecked Sendable {
        struct Wait: Equatable {
            var processID: pid_t
            var cap      : Duration
            var gestures : Int
            var scenes   : Int
        }
        var waits: [Wait] = []
        /// How many gestures had been delivered when each `prepare` ran.
        var prepares: [Int] = []
        var scenes  : ScriptedScenes?
        var actuator: RecordingActuator?
        func prepare(in processID: pid_t) async {
            prepares.append(actuator?.gestures.count ?? 0)
        }
        func settle(in processID: pid_t, cap: Duration) async {
            waits.append(Wait(
                processID: processID,
                cap      : cap,
                gestures : actuator?.gestures.count ?? 0,
                scenes   : scenes?.calls ?? 0
            ))
        }
    }

    /// The pauses the engine slept, in order.
    final class Pauses: @unchecked Sendable {
        var slept: [Duration] = []
    }

    private let pid: pid_t = 4242
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                       title: "Export", number: 1)

    private let toggleOff = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                         bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02),
                                         state: .off)
    private let toggleOn  = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                         bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02),
                                         state: .on)

    private func field(value: String?) -> SceneElement {
        SceneElement(id: "control|name", kind: .control, label: "Project Name",
                     bounds: NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.03), role: "AXTextField",
                     value: value)
    }

    private func scene(_ elements: [SceneElement]) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "Export",
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements
        ), frame: frame)
    }

    private func engine(
        scenes  : ScriptedScenes,
        actuator: RecordingActuator,
        controls: FakeControls? = nil,
        settling: RecordingSettling?,
        pauses  : Pauses
    ) -> ActionEngine {
        settling?.scenes   = scenes
        settling?.actuator = actuator
        return ActionEngine(
            ActionEngine.Dependencies(
                scenes  : scenes,
                actuator: actuator,
                windows : ScriptedWindows([[mainWindow]]),
                controls: controls,
                settling: settling
            ),
            pause: { pauses.slept.append($0) }
        )
    }

    @Test("a click waits through the settling role, capped at the click settle, before the scene after it")
    func aClickSettlesBeforeItsScene() async {
        let scenes   = ScriptedScenes([scene([toggleOff]), scene([toggleOn])])
        let actuator = RecordingActuator()
        let settling = RecordingSettling()
        let pauses   = Pauses()
        let outcome = await engine(scenes: scenes, actuator: actuator, settling: settling, pauses: pauses)
            .act(ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: "Facebook", verb: .click))

        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        // After the one gesture and before the second perception: the scene is taken after the settle.
        let cap = ActionTiming.standard.clickSettle
        #expect(settling.waits == [.init(processID: pid, cap: cap, gestures: 1, scenes: 1)])
        #expect(scenes.calls == 2)
        #expect(pauses.slept.isEmpty, "the role replaces the fixed pause, it does not add to it")
        #expect(settling.prepares == [0], "the reference is taken before the gesture goes out")
    }

    @Test("type_text settles once, after the click and the text, before the scene that judges it")
    func typingSettlesAfterItsLastGesture() async {
        let scenes   = ScriptedScenes([scene([field(value: "")])])
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focused = "Mecum"
        let settling = RecordingSettling()
        let pauses   = Pauses()
        let outcome = await engine(
            scenes: scenes, actuator: actuator, controls: controls, settling: settling, pauses: pauses
        ).deliver(InputRequest(
            processID: pid, bundleID: "com.x", appName: "X",
            input: .typeText("Mecum", into: "Project Name", replacing: true)
        ))

        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(settling.waits.count == 1)
        #expect(settling.waits.first?.gestures == actuator.gestures.count)
        #expect(settling.waits.first?.scenes == 1)
        #expect(settling.waits.first?.cap == ActionTiming.standard.clickSettle)
        #expect(pauses.slept.isEmpty)
        #expect(actuator.gestures.count > 1)
        #expect(settling.prepares == [0], "one reference, before the first gesture")
    }

    @Test("with no settling role the engine sleeps the click settle, as before the role existed")
    func noRoleSleepsTheFixedPause() async {
        let scenes   = ScriptedScenes([scene([toggleOff]), scene([toggleOn])])
        let actuator = RecordingActuator()
        let pauses   = Pauses()
        let outcome = await engine(scenes: scenes, actuator: actuator, settling: nil, pauses: pauses)
            .act(ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: "Facebook", verb: .click))

        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(pauses.slept == [ActionTiming.standard.clickSettle])
        #expect(scenes.calls == 2)
    }
}
