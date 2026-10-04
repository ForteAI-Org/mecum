//
//  ActionEngineTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// The act cycle over doubles that honor the roles: a scene source that answers a scripted sequence,
/// an actuator that records gestures, a window list that answers a scripted census, a control reader
/// with scripted values. No screen, no sleep.
@Suite("Action engine")
struct ActionEngineTests {

    // MARK: Doubles

    final class ScriptedScenes: SceneProviding, @unchecked Sendable {
        var queue: [PerceivedWindow]
        var calls = 0
        init(_ scenes: [PerceivedWindow]) { queue = scenes }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            calls += 1
            guard !queue.isEmpty else { throw Unavailable() }
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    final class RecordingActuator: Actuating, @unchecked Sendable {
        var gestures: [Gesture] = []
        var confirmations: [DeliveryEffect] = []
        var failure: (any Error)?
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            if let failure { throw failure }
            gestures.append(gesture)
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
            confirmations.append(effect)
        }
    }

    final class ScriptedWindows: WindowListing, @unchecked Sendable {
        var queue: [[WindowRow]]
        var readsUntilFailure: Int?
        init(_ rows: [[WindowRow]]) { queue = rows }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            if let remaining = readsUntilFailure {
                guard remaining > 0 else { throw Unavailable() }
                readsUntilFailure = remaining - 1
            }
            return queue.count > 1 ? queue.removeFirst() : (queue.first ?? [])
        }
    }

    final class FakeControls: ControlPressing, @unchecked Sendable {
        var pressed: [String] = []
        var pressSucceeds = false
        var values: [String?]
        var toggle: ControlState?
        var focused: String?
        init(values: [String?] = [nil], toggle: ControlState? = nil) { self.values = values; self.toggle = toggle }
        func pressControl(labelled label: String, in processID: pid_t) async -> Bool { pressed.append(label); return pressSucceeds }
        func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
            values.count > 1 ? values.removeFirst() : values.first ?? nil
        }
        func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { toggle }
        func focusedFieldValue(in processID: pid_t) async -> String? { focused }
    }

    final class FakeActivation: ApplicationActivating, @unchecked Sendable {
        var frontmost: pid_t?
        var activated: [pid_t] = []
        init(frontmost: pid_t?) { self.frontmost = frontmost }
        func frontmostProcessID() async -> pid_t? { frontmost }
        func activate(_ processID: pid_t) async { activated.append(processID) }
    }

    final class RecordingObserver: ActionObserving, @unchecked Sendable {
        var records: [ActionRecord] = []
        func record(_ record: ActionRecord) async { records.append(record) }
    }

    struct FixedExpectation: EffectExpecting {
        var effect: SceneEffect?
        func expectedEffect(of verb: ActionVerb, on element: SceneElement, in bundleID: String) async -> SceneEffect? { effect }
    }

    struct Unavailable: Error {}

    // MARK: Fixtures

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242

    private func rect(_ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.02) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func scene(_ elements: [SceneElement], title: String = "Export", token: String? = nil) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements,
            token: token.map(SceneToken.init(rawValue:))
        ), frame: frame)
    }

    private let toggleOff = SceneElement(id: "control|facebook", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .off)
    private let toggleOn  = SceneElement(id: "control|facebook", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .on)
    private let export    = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.08, height: 0.03))

    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Export", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56), title: nil, number: 9)

    private func request(_ target: String, verb: ActionVerb = .click, section: String? = nil,
                         desired: ControlState? = nil, dryRun: Bool = false) -> ActionRequest {
        ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: target, verb: verb,
                      section: section, desiredState: desired, isDryRun: dryRun)
    }

    private func engine(scenes: ScriptedScenes, actuator: RecordingActuator = RecordingActuator(),
                        windows: ScriptedWindows? = nil, controls: FakeControls? = nil, activation: FakeActivation? = nil,
                        expectations: FixedExpectation? = nil, observer: RecordingObserver? = nil,
                        permissions: ActionPermissions = ActionPermissions()) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: scenes, actuator: actuator, windows: windows ?? ScriptedWindows([[mainWindow]]),
                controls: controls, activation: activation, expectations: expectations, observer: observer
            ),
            permissions: permissions, pause: { _ in }
        )
    }

    // MARK: Resolution and policy

    @Test("a click resolves the native Create button instead of its sentence caption")
    func createButtonAndCaption() async {
        let caption = SceneElement(id: "text|create", kind: .text, label: "Create", bounds: rect(0.04, 0.30))
        let button = SceneElement(id: "control|create", kind: .control, label: "Create",
                                  bounds: rect(0.86, 0.85), role: "AXButton")
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([caption, button])]), actuator: actuator)
            .act(request("Create", dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message.contains("1010,788"))
        #expect(actuator.gestures.isEmpty)
    }

    @Test("no scene is an honest miss that says whether a window exists")
    func noScene() async {
        let noWindow = await engine(scenes: ScriptedScenes([]), windows: ScriptedWindows([[]])).act(request("Export"))
        #expect(noWindow.kind == .honestMiss)
        #expect(noWindow.message.contains("NO window open"))
        let hasWindow = await engine(scenes: ScriptedScenes([])).act(request("Export"))
        #expect(hasWindow.message.contains("could not be perceived"))
    }

    @Test("a missing target is an honest miss with the closest labels")
    func missingTarget() async {
        let outcome = await engine(scenes: ScriptedScenes([scene([export])])).act(request("the Export button"))
        #expect(outcome.kind == .honestMiss)
        #expect(outcome.message.contains("closest on screen: 'Export'"))
    }

    @Test("a shared label is ambiguous with a section hint, and a section resolves it")
    func ambiguous() async {
        var tab = export; tab.id = "control|export"; tab.section = "top bar"; tab.bounds = rect(0.3, 0.02)
        var button = export; button.section = "bottom bar"
        let actuator = RecordingActuator()
        let scenes = ScriptedScenes([scene([tab, button]), scene([tab, button]), scene([tab, button], title: "Render Queue")])
        let engine = engine(scenes: scenes, actuator: actuator)
        let outcome = await engine.act(request("Export"))
        #expect(outcome.kind == .ambiguous)
        #expect(outcome.message.contains("section:'top bar'") && outcome.message.contains("section:'bottom bar'"))
        let resolved = await engine.act(request("Export", section: "bottom bar"))
        #expect(resolved.kind == .foundActed, Comment(rawValue: resolved.message))
        #expect(actuator.gestures.count == 1)
    }

    @Test("a destructive target is refused unless the person allowed it")
    func destructive() async {
        let trash = SceneElement(id: "control|delete", kind: .control, label: "Delete", bounds: rect(0.5, 0.5))
        let refused = await engine(scenes: ScriptedScenes([scene([trash])])).act(request("Delete"))
        #expect(refused.kind == .refused)
        let actuator = RecordingActuator()
        let allowed = await engine(scenes: ScriptedScenes([scene([trash]), scene([trash], title: "Gone")]), actuator: actuator,
                                   permissions: ActionPermissions(allowsDestructive: true)).act(request("Delete"))
        #expect(allowed.kind == .foundActed)
        #expect(actuator.gestures.count == 1)
    }

    @Test("a dry run performs nothing and names the point and the expectation")
    func dryRun() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                   expectations: FixedExpectation(effect: .windowTitleChanged(title: "Render Queue")))
            .act(request("Export", dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message.contains("at 940,832"), Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("navigates to Render Queue"))
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: The click cycle

    @Test("a structural change lands, is recorded, and the click hits the element's point")
    func landed() async throws {
        let actuator = RecordingActuator(), observer = RecordingObserver()
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), actuator: actuator, observer: observer)
            .act(request("Facebook"))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.message == "clicked 'Facebook': toggles")
        #expect(actuator.gestures == [.click(at: CGPoint(x: 100 + 0.225 * 1000, y: 100 + 0.21 * 800))])
        let record = try #require(observer.records.first)
        #expect(record.effect == .stateFlip(from: .off, to: .on))
        #expect(record.verb == .click)
        #expect(actuator.confirmations == [.observed], "a landed effect closes the delivery as observed")
    }

    @Test("an identical scene is a ghost and says nothing else changed")
    func ghost() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.absent], "an identical scene is verified absence")
        #expect(outcome.message.contains("did NOT change"))
        #expect(outcome.message.contains("likely did not register"))
        #expect(outcome.message.contains("Nothing else in X changed"))
    }

    @Test("a repaint is unattributable, and a window that appeared elsewhere is named instead of blaming the click")
    func repaintWithElsewhere() async {
        let before = scene([export], token: "a"), after = scene([export], token: "b")
        let windows = ScriptedWindows([[mainWindow], [mainWindow], [WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 400, height: 300), title: "Save", number: 2), mainWindow]])
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([before, after]), actuator: actuator, windows: windows)
            .act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.unknown], "a repaint establishes nothing")
        #expect(outcome.message.contains("nothing structural"))
        #expect(outcome.message.contains("NEW window \"Save\" appeared"))
        #expect(!outcome.message.contains("likely did not register"))
    }

    @Test("an expectation is compared by family")
    func expectation() async {
        let matching = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]),
                                    expectations: FixedExpectation(effect: .stateFlip(from: .on, to: .off))).act(request("Facebook"))
        #expect(matching.kind == .foundActed)
        #expect(matching.message.hasSuffix("(as expected)"))
        let surprised = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]),
                                     expectations: FixedExpectation(effect: .menuOpened(labels: []))).act(request("Facebook"))
        #expect(surprised.kind == .actedUnverified)
        #expect(surprised.message.contains("expected opens menu() but observed toggles"))
    }

    @Test("a menu is believed only while a pop-up window exists, and its rows become the effect")
    func menuGating() async {
        let base = scene([export])
        let rows = [export] + ["Cut", "Copy", "Paste"].enumerated().map { i, label in
            SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label, bounds: rect(0.3, 0.3 + Double(i) * 0.03))
        }
        let noPopup = await engine(scenes: ScriptedScenes([base, scene(rows)])).act(request("Export"))
        #expect(noPopup.message.contains("reveals elements"))
        let withPopup = await engine(scenes: ScriptedScenes([base, scene(rows)]),
                                     windows: ScriptedWindows([[mainWindow], [mainWindow], [popupWindow, mainWindow]]))
            .act(request("Export"))
        #expect(withPopup.kind == .foundActed)
        #expect(withPopup.message.contains("opens menu(Copy|Cut|Export"))
    }

    @Test("activation happens only when the app is not in front, and never with a pop-up open")
    func activation() async {
        let behind = FakeActivation(frontmost: 1)
        _ = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), activation: behind).act(request("Export"))
        #expect(behind.activated == [pid])
        let inFront = FakeActivation(frontmost: pid)
        _ = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), activation: inFront).act(request("Export"))
        #expect(inFront.activated.isEmpty)
    }

    @Test("a triple click is one train of three at the element's point")
    func tripleClick() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), actuator: actuator)
            .act(request("Export", verb: .tripleClick))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.message.hasPrefix("triple-clicked 'Export'"))
        #expect(actuator.gestures == [.click(at: scene([export]).globalPoint(of: export), count: 3)])
    }

    @Test("a dropdown opened by its own press action is not also clicked")
    func openedByPress() async {
        let combo = SceneElement(id: "control|48000", kind: .control, label: "48000", bounds: rect(0.3, 0.4), role: "AXComboBox")
        let controls = FakeControls(); controls.pressSucceeds = true
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([combo]), scene([combo], title: "changed")]), actuator: actuator, controls: controls)
            .act(request("48000"))
        #expect(controls.pressed == ["48000"])
        #expect(actuator.gestures.isEmpty)
        #expect(outcome.kind == .foundActed)
    }

    @Test("delivery failure is reported, never hidden")
    func deliveryFailure() async {
        let actuator = RecordingActuator(); actuator.failure = Unavailable()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("delivery failed"))
        #expect(actuator.confirmations == [.unknown], "a failed delivery is still closed, as unknown")
    }

    // MARK: set_toggle

    @Test("set_toggle is idempotent, needs a state, and verifies the read-back")
    func setToggle() async {
        let already = await engine(scenes: ScriptedScenes([scene([toggleOff])])).act(request("Facebook", verb: .setToggle, desired: .off))
        #expect(already.kind == .actedNoop)
        let noState = await engine(scenes: ScriptedScenes([scene([toggleOff])])).act(request("Facebook", verb: .setToggle))
        #expect(noState.kind == .refused)
        let flipped = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), controls: FakeControls(toggle: .on))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(flipped.kind == .foundActed)
        #expect(flipped.message == "set 'Facebook' → on")
        let stuck = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOff])]), controls: FakeControls(toggle: .off))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(stuck.kind == .actedUnverified)
        #expect(stuck.message.contains("now reads 'off'"))
    }

    // MARK: Pop-ups

    private var listScene: PerceivedWindow {
        // A two-row list at 300,300 (220×56) over the 1000×800 window at 100,100.
        func row(_ id: String, _ label: String, y: CGFloat) -> SceneElement {
            SceneElement(id: id, kind: .text, label: label, bounds: NormalizedRect(
                x: (320.0 - 100.0) / 1000.0, y: Double((y - 100) / 800), width: 0.05, height: 14.0 / 800.0))
        }
        return scene([export, row("text|48000", "48000", y: 307), row("text|96000", "96000", y: 335)])
    }

    @Test("a target inside an open pop-up is picked by keyboard and verified by the control's value")
    func popupKeyboardPick() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(values: ["48000", "96000"])
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator,
                                   windows: ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("keyboard 1↓ + Return"))
        #expect(actuator.gestures == [.key(code: Key.downArrow), .key(code: Key.return)])
    }

    @Test("without a readable control the pick falls back to type-ahead and commits only while open")
    func popupTypeAhead() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator, windows: windows).act(request("96000"))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("type-ahead"))
        #expect(actuator.gestures == [.type("96000"), .key(code: Key.rightArrow), .key(code: Key.return)])
    }

    @Test("a target outside an open pop-up closes it first and says so")
    func popupOutside() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator,
                                   windows: ScriptedWindows([[popupWindow, mainWindow], [mainWindow]])).act(request("Export"))
        #expect(outcome.kind == .actedNoop)
        #expect(outcome.message.contains("closed the menu"))
        #expect(actuator.gestures == [.key(code: Key.escape)])
    }

    @Test("a menu still visible after Escape is reported unverified without clicking through", arguments: [false, true])
    func popupDismissalUnconfirmed(deliveryFails: Bool) async {
        let actuator = RecordingActuator()
        if deliveryFails { actuator.failure = Unavailable() }
        let outcome = await engine(
            scenes  : ScriptedScenes([listScene]),
            actuator: actuator,
            windows : ScriptedWindows([[popupWindow, mainWindow]])
        ).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("still open"))
        #expect(!outcome.message.contains("closed the menu"))
        #expect(!outcome.message.contains("again now"))
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures == (deliveryFails ? [] : [.key(code: Key.escape)]))
    }

    @Test("a failed window census cannot prove a menu was dismissed")
    func popupDismissalCensusUnavailable() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[popupWindow, mainWindow]])
        windows.readsUntilFailure = 1
        let outcome = await engine(
            scenes  : ScriptedScenes([listScene, scene([export])]),
            actuator: actuator,
            windows : windows
        ).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(!outcome.message.contains("closed the menu"))
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures == [.key(code: Key.escape)])
    }

    // MARK: Observe

    @Test("describe and check_goal read the live scene")
    func observe() async {
        let engine = engine(scenes: ScriptedScenes([scene([export], title: "Export Settings")]))
        let described = await engine.describeScene(of: pid, appName: "X")
        #expect(described.message.contains("scene_token:"))
        let missing = await engine.describeSection(named: "nowhere", of: pid, appName: "X")
        #expect(missing.kind == .honestMiss)
        let verified = await engine.checkGoal(evidence: "export settings", of: pid, appName: "X")
        #expect(verified.kind == .foundActed)
        let unverified = await engine.checkGoal(evidence: "Render Queue", of: pid, appName: "X")
        #expect(unverified.kind == .refused)
        #expect(unverified.message.contains("does not show"))
    }

    @Test("where menus open under the person's pointer, right_click is refused off a text field")
    func rightClickOutsideTheSeatIsRefused() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                   permissions: ActionPermissions(contextMenusOnTextFieldsOnly: true))
            .act(request("Export", verb: .rightClick))
        #expect(outcome.kind == .refused)
        #expect(actuator.gestures.isEmpty)
    }
}
