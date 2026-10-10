//
//  OperationCheckTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import PerceptionCore
import Testing

/// What the engine's oracles report with each outcome (`OperationCheck`, G76 D1): the condition each path
/// judged, its verdict and limits, and the gesture that really went out, separate from the outcome's kind.
@Suite("The check each engine path reports with its outcome")
struct OperationCheckTests {

    typealias Scenes   = ActionEngineTests.ScriptedScenes
    typealias Actuator = ActionEngineTests.RecordingActuator
    typealias Windows  = ActionEngineTests.ScriptedWindows
    typealias Controls = ActionEngineTests.FakeControls
    typealias Observer = ActionEngineTests.RecordingObserver

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242
    private let main  = WindowRow(
        layer: 0,
        frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
        title: "Export",
        number: 1
    )
    private let popup = WindowRow(
        layer: 101,
        frame: CGRect(x: 300, y: 300, width: 220, height: 56),
        title: nil,
        number: 9
    )

    private func scene(_ elements: [SceneElement], token: String? = nil) -> PerceivedWindow {
        PerceivedWindow(
            scene: SceneSnapshot(
                bundleID: "com.x",
                appName: "X",
                windowTitle: "Export",
                viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                elements: elements,
                token: token.map(SceneToken.init(rawValue:))
            ),
            frame: frame
        )
    }

    private func element(_ id: String, _ label: String, state: ControlState? = nil, role: String? = "AXButton",
                         value: String? = nil) -> SceneElement {
        SceneElement(
            id: id,
            kind: .control,
            label: label,
            bounds: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.03),
            role: role,
            state: state,
            value: value
        )
    }

    private func engine(
        _ scenes: Scenes,
        actuator: Actuator = Actuator(),
        windows: Windows? = nil,
        controls: Controls? = nil,
        observer: Observer? = nil
    ) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: scenes,
                actuator: actuator,
                windows: windows ?? Windows([[main]]),
                controls: controls,
                activation: nil,
                expectations: nil,
                observer: observer
            ),
            permissions: ActionPermissions(),
            pause: { _ in }
        )
    }

    private func request(_ target: String, verb: ActionVerb = .click, desired: ControlState? = nil) -> ActionRequest {
        ActionRequest(
            processID: pid,
            bundleID: "com.x",
            appName: "X",
            target: target,
            verb: verb,
            desiredState: desired
        )
    }

    @Test("set_toggle already in the requested state: a passed reading, no gesture, and the observer gets the reading")
    func toggleAlreadySatisfied() async throws {
        let actuator = Actuator(), observer = Observer()
        let outcome = await engine(
            Scenes([scene([element("t", "Wi-Fi", state: .on, role: "AXCheckBox")])]),
            actuator: actuator,
            observer: observer
        ).act(request("Wi-Fi", verb: .setToggle, desired: .on))
        let check = try #require(outcome.check)
        #expect(outcome.kind == .actedNoop && actuator.gestures.isEmpty)
        #expect(check.condition == .requestedStateAlreadyPresent && check.verdict == .passed
                && check.performed == .none)
        #expect(check.expected == "on" && check.observed == "on" && check.target?.label == "Wi-Fi")
        #expect(observer.records.first?.attempt == .notAttempted(reason: "requested_state_already_present"))
        #expect(observer.records.first?.before != nil, "the reading's perception is kept")
    }

    @Test("set_toggle read back after the click: passed, failed or unknown by what was read")
    func toggleReadBack() async throws {
        let off = element("t", "Wi-Fi", state: .off, role: "AXCheckBox"),
            on = element("t", "Wi-Fi", state: .on, role: "AXCheckBox")
        let passed = await engine(Scenes([scene([off]), scene([on])]), controls: Controls(toggle: .on))
            .act(request("Wi-Fi", verb: .setToggle, desired: .on))
        #expect(passed.check?.condition == .stateAfterGesture && passed.check?.verdict == .passed)
        let failed = await engine(Scenes([scene([off]), scene([off])]), controls: Controls(toggle: .off))
            .act(request("Wi-Fi", verb: .setToggle, desired: .on))
        #expect(failed.check?.verdict == .failed && failed.check?.observed == "off")
        let unreadable = element("t", "Wi-Fi", role: "AXCheckBox")
        let unknown = await engine(Scenes([scene([off]), scene([unreadable])]), controls: Controls(toggle: nil))
            .act(request("Wi-Fi", verb: .setToggle, desired: .on))
        #expect(unknown.check?.verdict == .unknown && unknown.check?.limits.contains(.readbackUnavailable) == true)
    }

    @Test("S03: a click replaced by closing an open pop-up reports the recovery it made and never the click")
    func popupRecovery() async throws {
        let actuator = Actuator()
        let export = element("e", "Export")
        let outcome = await engine(Scenes([scene([export]), scene([export])]), actuator: actuator,
                                   windows: Windows([[popup, main], [main]])).act(request("Export"))
        let check = try #require(outcome.check)
        #expect(outcome.kind == .actedNoop && actuator.gestures == [.key(code: Key.escape)])
        #expect(check.condition == .recoveryInsteadOfRequest && check.verdict == .passed)
        #expect(check.performed == .substitute && check.substitute == "escape")
    }

    @Test("a click judged by the scene difference: a landed effect passes window-wide, an identical scene fails, a repaint is unknown")
    func clickVerdicts() async throws {
        let save = element("s", "Save"), dialog = element("d", "Replace")
        let landed = await engine(Scenes([scene([save], token: "a"), scene([save, dialog], token: "b")]))
            .act(request("Save"))
        #expect(landed.check?.condition == .structuralEffect && landed.check?.verdict == .passed)
        #expect(landed.check?.limits == [.windowWide, .noExpectation] && landed.check?.performed == .requested)
        let ghost = await engine(Scenes([scene([save], token: "a"), scene([save], token: "a")])).act(request("Save"))
        #expect(ghost.check?.verdict == .failed && ghost.check?.observed == "unchanged")
        let repaint = await engine(Scenes([scene([save], token: "a"), scene([save], token: "b")])).act(request("Save"))
        #expect(repaint.check?.verdict == .unknown && repaint.check?.limits.contains(.unattributed) == true)
        let failing = Actuator()
        failing.failure = ActionEngineTests.Unavailable()
        let undelivered = await engine(Scenes([scene([save])]), actuator: failing).act(request("Save"))
        #expect(undelivered.check?.performed == .uncertain && undelivered.check?.limits == [.deliveryUncertain])
    }

    @Test("a double, triple or right click is judged as a click is: by the scene difference, window-wide, the gesture requested",
          arguments: [ActionVerb.doubleClick, .tripleClick, .rightClick])
    func otherClickVerbs(verb: ActionVerb) async throws {
        let save = element("s", "Save"), dialog = element("d", "Replace")
        let landed = await engine(Scenes([scene([save], token: "a"), scene([save, dialog], token: "b")]))
            .act(request("Save", verb: verb))
        let check = try #require(landed.check)
        #expect(check.condition == .structuralEffect && check.verdict == .passed && check.performed == .requested)
        #expect(check.limits.contains(.windowWide) && check.target?.label == "Save")
        let ghost = await engine(Scenes([scene([save], token: "a"), scene([save], token: "a")]))
            .act(request("Save", verb: verb))
        #expect(ghost.check?.verdict == .failed)
    }

    @Test("a key with modifiers pressed twice and a drag are judged window-wide by the scene difference, with no expectation, like a scroll")
    func keysAndDrags() async throws {
        let list = element("l", "Files", role: "AXList"), album = element("t", "Album")
        let chord = KeyChord(.character("s"), modifiers: [.command, .shift])
        let pressed = await engine(
            Scenes([scene([list], token: "a"), scene([list, album], token: "b")])
        ).deliver(InputRequest(
            processID: pid, bundleID: "com.x", appName: "X", input: .pressKey(chord, times: 2)
        ))
        #expect(pressed.check?.condition == .structuralEffect && pressed.check?.verdict == .passed)
        #expect(pressed.check?.limits == [.windowWide, .noExpectation] && pressed.check?.performed == .requested)
        let dragged = await engine(
            Scenes([scene([list, album], token: "a"), scene([list, album], token: "a")])
        ).deliver(InputRequest(
            processID: pid, bundleID: "com.x", appName: "X", input: .drag(from: "Files", to: .target("Album"))
        ))
        #expect(dragged.check?.condition == .structuralEffect && dragged.check?.verdict == .failed,
                "\(dragged.kind): \(dragged.message) \(String(describing: dragged.check))")
        #expect(dragged.check?.target?.label == "Files")
    }

    @Test("a miss, an ambiguity and a refusal say no gesture went out; a miss resolved no target")
    func noGesture() async throws {
        let miss = await engine(Scenes([scene([element("s", "Save")])])).act(request("Nothing"))
        #expect(miss.check == .unchecked(performed: .none, limits: [.targetNotResolved]))
        let destructive = await engine(Scenes([scene([element("d", "Delete All")])])).act(request("Delete All"))
        #expect(destructive.kind == .refused && destructive.check?.performed == OperationCheck.Performed.none)
    }

    @Test("typing is checked by reading the field back; an insertion without an expected value stays unknown")
    func inputChecks() async throws {
        let field = element("f", "Name", role: "AXTextField", value: "")
        let controls = Controls()
        controls.focused = "foto_web.jpg"
        let observer = Observer()
        let typed = await engine(
            Scenes([scene([field]), scene([field])]),
            controls: controls,
            observer: observer
        ).deliver(InputRequest(
            processID: pid,
            bundleID: "com.x",
            appName: "X",
            input: .typeText("foto_web.jpg", into: "Name", replacing: true)
        ))
        #expect(typed.check?.condition == .valueReadBack && typed.check?.verdict == .passed)
        #expect(typed.check?.expected == "foto_web.jpg" && typed.check?.observed == "foto_web.jpg")
        #expect(observer.inputs.first?.target?.id == "f", "the record names the field the input resolved")
        let inserted = await engine(Scenes([scene([field])]), controls: Controls()).deliver(InputRequest(
            processID: pid, bundleID: "com.x", appName: "X", input: .insertText("hello", expecting: nil)
        ))
        #expect(inserted.check?.condition == OperationCheck.Condition.none && inserted.check?.verdict == .unknown)
        #expect(inserted.check?.limits == [.noExpectedValue])
    }

    @Test("a key, a scroll and a drag are judged window-wide by the scene difference, with no expectation")
    func inputSceneDifference() async throws {
        let list = element("l", "Files", role: "AXList")
        let scrolled = await engine(
            Scenes([scene([list], token: "a"), scene([list], token: "a")])
        ).deliver(InputRequest(
            processID: pid, bundleID: "com.x", appName: "X", input: .scroll(lines: -3, over: "Files")
        ))
        #expect(scrolled.check?.condition == .structuralEffect && scrolled.check?.verdict == .failed)
        #expect(scrolled.check?.limits == [.windowWide, .noExpectation] && scrolled.check?.target?.label == "Files")
    }
}
