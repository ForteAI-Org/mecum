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
        init(_ rows: [[WindowRow]]) { queue = rows }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            queue.count > 1 ? queue.removeFirst() : (queue.first ?? [])
        }
    }

    /// A window listing that answers each call in turn, a failure included, as a window server that
    /// could not be asked once.
    final class FallibleWindows: WindowListing, @unchecked Sendable {
        var queue: [Result<[WindowRow], Unavailable>]
        init(_ answers: [Result<[WindowRow], Unavailable>]) { queue = answers }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            try (queue.count > 1 ? queue.removeFirst() : (queue.first ?? .success([]))).get()
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

    /// A scene source that perceives once and then fails, as a window that vanished after the gesture.
    final class NoSceneAfterFirst: SceneProviding, @unchecked Sendable {
        private var first: PerceivedWindow?
        init(_ scene: PerceivedWindow) { first = scene }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            guard let scene = first else { throw Unavailable() }
            first = nil
            return scene
        }
    }

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

    private func engine(scenes: any SceneProviding, actuator: RecordingActuator = RecordingActuator(),
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

    // MARK: Click evidence

    /// The point a gesture on `export` is delivered at.
    private var exportPoint: CGPoint { scene([export]).globalPoint(of: export) }

    /// A pop-up listed at `origin`, the way a menu opened by a gesture there is.
    private func menuRow(at origin: CGPoint, number: Int = 9) -> WindowRow {
        WindowRow(layer: 101, frame: CGRect(origin: origin, size: CGSize(width: 180, height: 120)), title: nil,
                  number: number)
    }

    /// The pop-up's rows as the scene after the gesture perceives them.
    private func menuScene(_ items: [String] = ["Cut", "Copy", "Paste"]) -> PerceivedWindow {
        scene(items.enumerated().map { index, item in
            SceneElement(id: "text|\(item.lowercased())", kind: .text, label: item,
                         bounds: rect(0.1, 0.1 + Double(index) * 0.2))
        }, title: "")
    }

    /// The census before the gesture and the listing after it, as the engine reads them in order.
    private func listings(after: [WindowRow]) -> ScriptedWindows {
        ScriptedWindows([[mainWindow], [mainWindow], after])
    }

    @Test("a right-click that opens a menu at the target proves it, as a right-click and nothing else")
    func rightClickOpensMenu() async throws {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menuScene()]), actuator: actuator,
                                   windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(actuator.gestures == [.click(at: exportPoint, button: .right)])
        #expect(outcome.kind == .foundActed)
        let proof = try #require(outcome.click)
        #expect(proof.gesture == .rightClick && proof.delivery == .sent)
        #expect(proof.effect == .menuOpened(items: ["Copy", "Cut", "Paste"]))
        #expect(proof.target == "Export" && proof.windowTitle == "Export" && proof.bundleID == "com.x")
        #expect(proof.isVerified && proof.surface == .menu)
        #expect(outcome.evidence == .click(proof))
    }

    /// The outcome's sentence names a few items; the proof keeps every readable row, as long as it is.
    @Test("a menu's proof keeps every readable row, whatever their number or length, and no mark without text")
    func menuProofKeepsEveryRow() async throws {
        let items = ["Cut", "Copy", "Paste", "Delete", "Select All", "Find", "Spelling", "Substitutions",
                     "Transformations applied to the whole selected passage", "•"]
        let menu = scene(items.enumerated().map { index, item in
            SceneElement(id: "text|\(index)", kind: .text, label: item, bounds: rect(0.1, 0.05 + Double(index) * 0.09))
        }, title: "")
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menu]),
                                   windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(outcome.click?.effect == .menuOpened(items: items.dropLast().sorted()))
    }

    @Test("a click that opens a menu at the target is proven the same way; one pressed open says so")
    func clickOpensMenu() async throws {
        let clicked = await engine(scenes: ScriptedScenes([scene([export]), menuScene()]),
                                   windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export"))
        #expect(clicked.click?.gesture == .click)
        #expect(clicked.click?.effect == .menuOpened(items: ["Copy", "Cut", "Paste"]))
        let controls = FakeControls(); controls.pressSucceeds = true
        let actuator = RecordingActuator()
        let pressed = await engine(scenes: ScriptedScenes([scene([export]), menuScene()]), actuator: actuator,
                                   windows: listings(after: [menuRow(at: exportPoint), mainWindow]), controls: controls)
            .act(request("Export"))
        #expect(actuator.gestures.isEmpty)
        #expect(pressed.click?.delivery == .pressed && pressed.click?.isVerified == true)
    }

    @Test("a double-click is one gesture of two clicks, and a new window it opens links origin and destination")
    func doubleClickOpensWindow() async throws {
        let actuator = RecordingActuator()
        let project = WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 600, height: 400), title: "Project 1",
                                number: 2)
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Project 1")]),
                                   actuator: actuator, windows: listings(after: [project, mainWindow]))
            .act(request("Export", verb: .doubleClick))
        #expect(actuator.gestures == [.click(at: exportPoint, count: 2)], "one gesture, never two clicks")
        let proof = try #require(outcome.click)
        #expect(proof.gesture == .doubleClick && proof.gesture.clickCount == 2)
        #expect(proof.windowTitle == "Export" && proof.effect == .windowOpened(title: "Project 1"))
        #expect(proof.surface == .window(title: "Project 1"))
    }

    @Test("a census that could not be taken before the gesture attributes no window, not even the one clicked in")
    func clickWithoutCensus() async throws {
        let windows = FallibleWindows([.success([mainWindow]), .failure(Unavailable()), .success([mainWindow])])
        let outcome = await ActionEngine(
            ActionEngine.Dependencies(scenes: ScriptedScenes([scene([export]), scene([export])]),
                                      actuator: RecordingActuator(), windows: windows, controls: nil, activation: nil,
                                      expectations: nil, observer: nil),
            permissions: ActionPermissions(), pause: { _ in }
        ).act(request("Export", verb: .doubleClick))
        let proof = try #require(outcome.click)
        #expect(proof.delivery == .sent)
        #expect(proof.surface == nil, "the window the gesture was delivered in is not a window it opened")
        #expect(!proof.isVerified)
    }

    @Test("a window list that answers but omits the window clicked in attributes it to no gesture")
    func emptyCensusBeforeGesture() async throws {
        let appeared = SceneElement(id: "control|details", kind: .control, label: "Details", bounds: rect(0.3, 0.5))
        for verb in [ActionVerb.click, .doubleClick, .rightClick] {
            for before in [[WindowRow](), [WindowRow(layer: 0, frame: CGRect(x: 900, y: 900, width: 300, height: 200),
                                                     title: "Palette", number: 3)]] {
                let windows = ScriptedWindows([before, before, [mainWindow]])
                let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export, appeared])]),
                                           windows: windows).act(request("Export", verb: verb))
                let proof = try #require(outcome.click)
                #expect(proof.surface == nil, "\(verb) \(before): \(proof.effect)")
                #expect(!proof.isVerified)
            }
        }
    }

    @Test("an origin window re-created under a new number is not a window the gesture opened")
    func recreatedOrigin() async throws {
        let recreated = WindowRow(layer: 0, frame: frame, title: "Export", number: 12)
        let appeared = SceneElement(id: "control|details", kind: .control, label: "Details", bounds: rect(0.3, 0.5))
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export, appeared])]),
                                   windows: listings(after: [recreated])).act(request("Export", verb: .doubleClick))
        #expect(outcome.click?.surface == nil)
        let sibling = WindowRow(layer: 0, frame: CGRect(x: 300, y: 300, width: 600, height: 400), title: "Export",
                                number: 2)
        let opened = await engine(scenes: ScriptedScenes([scene([export]), scene([export, appeared])]),
                                  windows: listings(after: [sibling, mainWindow])).act(request("Export", verb: .doubleClick))
        #expect(opened.click?.surface == .window(title: "Export"), "a second window of the same title still opened")
    }

    /// A window list that shows a pop-up only once the scene after the gesture has been perceived, as a
    /// menu that opens while that capture is taken.
    final class PopupAfterReading: WindowListing, @unchecked Sendable {
        let scenes: ScriptedScenes
        let main: WindowRow
        let popup: WindowRow
        init(scenes: ScriptedScenes, main: WindowRow, popup: WindowRow) {
            self.scenes = scenes; self.main = main; self.popup = popup
        }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            scenes.calls >= 2 ? [popup, main] : [main]
        }
    }

    /// The scene a Seat capture reads while a pop-up is open (`SeatSceneProvider`): one still of the window
    /// and the pop-up, cropped to their union, with the window's title and controls beside the pop-up's rows.
    private func windowAndMenu(rows: [String], menuAt origin: CGPoint) -> PerceivedWindow {
        let menu = CGRect(origin: origin, size: CGSize(width: 180, height: 120))
        let union = frame.union(menu)
        func normalized(_ rect: CGRect) -> NormalizedRect {
            NormalizedRect(x: (rect.minX - union.minX) / union.width, y: (rect.minY - union.minY) / union.height,
                           width: rect.width / union.width, height: rect.height / union.height)
        }
        func global(_ bounds: NormalizedRect) -> CGRect {
            CGRect(x: frame.minX + bounds.x * frame.width, y: frame.minY + bounds.y * frame.height,
                   width: bounds.width * frame.width, height: bounds.height * frame.height)
        }
        let controls = [export,
                        SceneElement(id: "control|render", kind: .control, label: "Render", bounds: rect(0.1, 0.1)),
                        SceneElement(id: "control|tracks", kind: .control, label: "Tracks", bounds: rect(0.1, 0.3))]
            .map { SceneElement(id: $0.id, kind: $0.kind, label: $0.label, bounds: normalized(global($0.bounds))) }
        let items = rows.enumerated().map { index, row in
            SceneElement(id: "text|\(row.lowercased())", kind: .text, label: row,
                         bounds: normalized(CGRect(x: menu.minX + 10, y: menu.minY + 10 + Double(index) * 30,
                                                   width: 150, height: 20)))
        }
        var scene = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Export",
                                  viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                                  elements: controls + items)
        scene.coverage = .windowAndPopups
        return PerceivedWindow(scene: scene, frame: union)
    }

    @Test("in a capture of the window and its pop-up, the menu's items are the rows inside the pop-up only")
    func menuItemsInsideThePopup() async throws {
        let unreadable = await engine(scenes: ScriptedScenes([scene([export]), windowAndMenu(rows: [], menuAt: exportPoint)]),
                                      windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(unreadable.click?.effect == .unattributed(.unreadableSurface),
                "the window's own controls are not the menu's items: \(String(describing: unreadable.click?.effect))")
        #expect(unreadable.click?.isVerified != true)
        let readable = await engine(scenes: ScriptedScenes([scene([export]),
                                                            windowAndMenu(rows: ["Cut", "Copy", "Paste"],
                                                                          menuAt: exportPoint)]),
                                    windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(readable.kind == .foundActed)
        #expect(readable.click?.effect == .menuOpened(items: ["Copy", "Cut", "Paste"]))
        #expect(readable.click?.isVerified == true)
        // TextEdit, 28/09/2026: the model was told "opens menu(1,0|12|14…)", the window's own labels.
        #expect(readable.message.contains("Copy|Cut|Paste"), "\(readable.message)")
        #expect(!["Render", "Tracks", "Export|"].contains { readable.message.contains($0) }, "\(readable.message)")
    }

    @Test("menu items read from a capture taken before the pop-up was listed are no proof of that menu")
    func menuItemsFromAnotherCapture() async throws {
        let labels = ["Cut", "Copy"].enumerated().map { index, label in
            SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label, bounds: rect(0.1, 0.1 + Double(index) * 0.1))
        }
        let mainAfter = scene([export] + labels)
        let scenes = ScriptedScenes([scene([export]), mainAfter])
        let listing = PopupAfterReading(scenes: scenes, main: mainWindow, popup: menuRow(at: exportPoint))
        let outcome = await ActionEngine(
            ActionEngine.Dependencies(scenes: scenes, actuator: RecordingActuator(), windows: listing, controls: nil,
                                      activation: nil, expectations: nil, observer: nil),
            permissions: ActionPermissions(), pause: { _ in }
        ).act(request("Export", verb: .rightClick))
        #expect(outcome.click?.surface == nil, "\(String(describing: outcome.click?.effect))")
        #expect(outcome.click?.effect == .unattributed(.menuNotCaptured))
        let menuRead = ScriptedScenes([scene([export]), mainAfter, menuScene()])
        let reread = await ActionEngine(
            ActionEngine.Dependencies(scenes: menuRead, actuator: RecordingActuator(),
                                      windows: PopupAfterReading(scenes: menuRead, main: mainWindow,
                                                                 popup: menuRow(at: exportPoint)),
                                      controls: nil, activation: nil, expectations: nil, observer: nil),
            permissions: ActionPermissions(), pause: { _ in }
        ).act(request("Export", verb: .rightClick))
        #expect(reread.click?.effect == .menuOpened(items: ["Copy", "Cut", "Paste"]),
                "a capture taken while the pop-up is listed reads its own items")
    }

    @Test("a click credited with a surface but not verified by the scenes carries no verified surface")
    func unverifiedOutcomeCarriesNoSurface() async throws {
        let project = WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 600, height: 400), title: "Project 1",
                                number: 2)
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Project 1")]),
                                   windows: listings(after: [project, mainWindow]),
                                   expectations: FixedExpectation(effect: .menuOpened(labels: ["A", "B"])))
            .act(request("Export", verb: .doubleClick))
        #expect(outcome.kind != .foundActed)
        #expect(outcome.click?.isVerified != true, "\(outcome.kind): \(String(describing: outcome.click?.effect))")
    }

    @Test("after the click, one homonym elsewhere is not the control clicked, whatever its id")
    func homonymElsewhereAfterClick() async throws {
        let elsewhere = SceneElement(id: "control|facebook#2", kind: .control, label: "Facebook",
                                     bounds: NormalizedRect(x: 0.6, y: 0.7, width: 0.05, height: 0.02), state: .on)
        let sameID = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                  bounds: NormalizedRect(x: 0.6, y: 0.7, width: 0.05, height: 0.02), state: .on)
        for after in [elsewhere, sameID] {
            let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([after])]))
                .act(request("Facebook", verb: .setToggle, desired: .on))
            #expect(outcome.kind == .actedUnverified, "\(after.id)")
            #expect(outcome.toggle?.change == .unverified)
            #expect(outcome.toggle?.stateAfter?.definiteState == nil)
        }
    }

    @Test("after the click, a homonym that only grazes the control's place is not its reading, whatever it reads")
    func adjacentHomonymAfterClick() async throws {
        // The 03-r2 reproducer: the control clicked spans x 0.200-0.250 and is not perceived after the click;
        // the next strip's control with the same label spans x 0.249-0.299, in the same (nil) section.
        let neighbour = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                     bounds: NormalizedRect(x: 0.249, y: 0.2, width: 0.05, height: 0.02), state: .on)
        let labelled = SceneElement(id: "control|facebook#2", kind: .control, label: "Facebook",
                                    bounds: neighbour.bounds, state: .on)
        for after in [neighbour, labelled] {
            let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([after])]))
                .act(request("Facebook", verb: .setToggle, desired: .on))
            #expect(outcome.kind == .actedUnverified, "\(after.id)")
            #expect(outcome.toggle?.stateAfter == .unreadable(.notAtPlace), "\(after.id)")
            #expect(outcome.toggle?.change == .unverified, "\(after.id)")
        }
        // Beside the control still at its place, the neighbour is not a second candidate, and the state that
        // matches the request does not choose it: the control clicked reads off.
        let both = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOff, neighbour])]))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(both.kind == .actedUnverified)
        #expect(both.toggle?.stateAfter == .read(.off, .sameElement))
    }

    @Test("after the click, the control at its place is read, a little moved or resized as it repaints")
    func controlAtItsPlaceAfterClick() async throws {
        let nudged = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                  bounds: NormalizedRect(x: 0.21, y: 0.203, width: 0.05, height: 0.02), state: .on)
        let grown = SceneElement(id: "control|facebook", kind: .control, label: "Facebook",
                                 bounds: NormalizedRect(x: 0.195, y: 0.198, width: 0.07, height: 0.025), state: .on)
        for after in [toggleOn, nudged, grown] {
            let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([after])]))
                .act(request("Facebook", verb: .setToggle, desired: .on))
            #expect(outcome.kind == .foundActed, "\(after.bounds)")
            #expect(outcome.toggle?.stateAfter == .read(.on, .sameElement), "\(after.bounds)")
            #expect(outcome.toggle?.change == .changed, "\(after.bounds)")
        }
    }

    @Test("a found_acted is not proof: a menu elsewhere, several surfaces or another window attribute nothing")
    func clickUnattributed() async throws {
        let far = CGPoint(x: 150, y: 150)
        let elsewhere = await engine(scenes: ScriptedScenes([scene([export]), menuScene()]),
                                     windows: listings(after: [menuRow(at: far), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(elsewhere.kind == .foundActed, "the outcome still reports the menu it saw")
        #expect(elsewhere.click?.effect == .unattributed(.surfaceElsewhere))
        #expect(elsewhere.click?.isVerified == false)

        let log = WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 600, height: 400), title: "Log", number: 3)
        let several = await engine(scenes: ScriptedScenes([scene([export]), menuScene()]),
                                   windows: listings(after: [menuRow(at: exportPoint), log, mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(several.click?.effect == .unattributed(.severalSurfaces))

        let project = WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 600, height: 400), title: "Project",
                                number: 2)
        let notPerceived = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Render")]),
                                        windows: listings(after: [project, mainWindow]))
            .act(request("Export", verb: .doubleClick))
        #expect(notPerceived.kind == .foundActed)
        #expect(notPerceived.click?.effect == .unattributed(.otherWindow))

        let oneRow = await engine(scenes: ScriptedScenes([scene([export]), menuScene(["Cut"])]),
                                  windows: listings(after: [menuRow(at: exportPoint), mainWindow]))
            .act(request("Export", verb: .rightClick))
        #expect(oneRow.click?.effect == .unattributed(.unreadableSurface))
    }

    @Test("a scene that changed, did not change, repainted or could not be read opens nothing")
    func clickWithoutSurface() async throws {
        let rows = [export] + ["Cut", "Copy", "Paste"].enumerated().map { index, label in
            SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label,
                         bounds: rect(0.3, 0.3 + Double(index) * 0.03))
        }
        let revealed = await engine(scenes: ScriptedScenes([scene([export]), scene(rows)])).act(request("Export"))
        #expect(revealed.kind == .foundActed)
        #expect(revealed.click?.effect == .unattributed(.otherChange))
        let retitled = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Queue")]))
            .act(request("Export"))
        #expect(retitled.kind == .foundActed)
        #expect(retitled.click?.effect == .unattributed(.otherChange), "a new title without a new window is no window")
        let ghost = await engine(scenes: ScriptedScenes([scene([export])])).act(request("Export"))
        #expect(ghost.click?.effect == .unattributed(.noChange))
        let repaint = await engine(scenes: ScriptedScenes([scene([export], token: "a"), scene([export], token: "b")]))
            .act(request("Export"))
        #expect(repaint.click?.effect == .unattributed(.repaint))
        let lost = await engine(scenes: NoSceneAfterFirst(scene([export]))).act(request("Export", verb: .doubleClick))
        #expect(lost.click == ClickEvidence(bundleID: "com.x", windowTitle: "Export", target: "Export",
                                            targetRole: nil, section: nil, gesture: .doubleClick, delivery: .sent,
                                            effect: .unattributed(.noScene)))
    }

    @Test("a failed delivery and a dry run are no proof; a failure is kept with its gesture")
    func clickFailureAndDryRun() async throws {
        let actuator = RecordingActuator(); actuator.failure = Unavailable()
        let failed = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .act(request("Export", verb: .rightClick))
        #expect(failed.click?.delivery == .failed && failed.click?.gesture == .rightClick)
        #expect(failed.click?.effect == .unattributed(.notDelivered))
        #expect(failed.click?.isVerified == false)
        let dry = await engine(scenes: ScriptedScenes([scene([export])])).act(request("Export", dryRun: true))
        #expect(dry.kind == .dryRun && dry.click == nil)
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

    // MARK: set_toggle evidence

    private func facebook(_ state: ControlState?, id: String = "control|facebook", section: String? = nil)
        -> SceneElement {
        SceneElement(id: id, kind: .control, label: "Facebook",
                     bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: state, section: section)
    }

    @Test("a toggle turned off to on carries both readings, their sources and the click")
    func toggleEvidenceOffToOn() async throws {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), actuator: actuator)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(outcome.kind == .foundActed)
        let proof = try #require(outcome.toggle)
        #expect(proof.stateBefore == .read(.off, .resolvedElement))
        #expect(proof.click == .sent)
        #expect(proof.stateAfter == .read(.on, .sameElement))
        #expect(proof.change == .changed)
        #expect(proof.control == "Facebook" && proof.bundleID == "com.x" && proof.windowTitle == "Export")
        #expect(outcome.evidence == .toggle(proof))
        #expect(outcome.dropdown == nil)
        #expect(actuator.gestures.count == 1)
    }

    @Test("a toggle turned on to off is proven the same way, with the state the request asked for")
    func toggleEvidenceOnToOff() async throws {
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOn]), scene([toggleOff])]))
            .act(request("Facebook", verb: .setToggle, desired: .off))
        let proof = try #require(outcome.toggle)
        #expect(outcome.kind == .foundActed)
        #expect(proof.desiredState == .off)
        #expect(proof.stateBefore == .read(.on, .resolvedElement) && proof.stateAfter == .read(.off, .sameElement))
        #expect(proof.change == .changed)
    }

    @Test("a toggle already in the requested state sends nothing and proves no change")
    func toggleEvidenceAlreadySet() async throws {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOn])]), actuator: actuator)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(outcome.kind == .actedNoop)
        let proof = try #require(outcome.toggle)
        #expect(proof.click == .none && proof.stateAfter == nil)
        #expect(proof.change == .alreadySet && proof.isVerified)
        #expect(actuator.gestures.isEmpty)
    }

    @Test("an unknown start is read again on the same control before any click")
    func toggleUnknownStartReadAgain() async throws {
        let actuator = RecordingActuator()
        let scenes = ScriptedScenes([scene([facebook(nil)]), scene([facebook(.off)]), scene([facebook(.on)])])
        let outcome = await engine(scenes: scenes, actuator: actuator).act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(outcome.kind == .foundActed)
        let proof = try #require(outcome.toggle)
        #expect(proof.stateBefore == .read(.off, .sameElement))
        #expect(proof.change == .changed)
        #expect(actuator.gestures.count == 1)
        #expect(scenes.calls == 3, "resolve, read again, read after")
    }

    @Test("a start that stays unknown is refused without a blind click, with the reason kept")
    func toggleUnknownStartRefused() async throws {
        let actuator = RecordingActuator()
        let unknown = await engine(scenes: ScriptedScenes([scene([facebook(.unknown)]), scene([facebook(nil)])]),
                                   actuator: actuator, controls: FakeControls(toggle: .mixed))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(unknown.kind == .refused)
        #expect(unknown.message.contains("not clicking blind"))
        let proof = try #require(unknown.toggle)
        #expect(proof.stateBefore == .unreadable(.indefinite))
        #expect(proof.click == .none && proof.change == .unverified)
        #expect(actuator.gestures.isEmpty)
        let gone = await engine(scenes: ScriptedScenes([scene([facebook(nil)]), scene([export])]), actuator: actuator)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(gone.toggle?.stateBefore == .unreadable(.notFound))
        #expect(actuator.gestures.isEmpty)
    }

    @Test("after the click, several controls that could be it attribute nothing, whatever they read")
    func toggleAmbiguousAfter() async throws {
        let after = scene([facebook(.on, id: "control|facebook#2"), facebook(.on, id: "control|facebook#3")])
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), after]))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(outcome.kind == .actedUnverified)
        let proof = try #require(outcome.toggle)
        #expect(proof.click == .sent)
        #expect(proof.stateAfter == .unreadable(.severalMatches))
        #expect(proof.change == .unverified)
        let relabelled = scene([facebook(.on, id: "control|facebook#2")])
        let single = await engine(scenes: ScriptedScenes([scene([toggleOff]), relabelled]))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(single.toggle?.stateAfter == .read(.on, .sameLabel))
        let otherSection = scene([facebook(.on, id: "control|facebook#2", section: "Sharing")])
        let elsewhere = await engine(scenes: ScriptedScenes([scene([facebook(.off, section: "Accounts")]), otherSection]))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(elsewhere.toggle?.stateAfter == .unreadable(.notFound))
    }

    @Test("a failed click and a missing scene afterwards are kept as such in the evidence")
    func toggleFailures() async throws {
        let actuator = RecordingActuator()
        actuator.failure = Unavailable()
        let failed = await engine(scenes: ScriptedScenes([scene([toggleOff])]), actuator: actuator)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(failed.kind == .actedUnverified)
        #expect(failed.toggle?.click == .failed && failed.toggle?.stateAfter == nil)
        let noScene = ActionEngine(ActionEngine.Dependencies(scenes: OneScene(scene([toggleOff])),
                                                             actuator: RecordingActuator(),
                                                             windows: ScriptedWindows([[mainWindow]])), pause: { _ in })
        let unread = await noScene.act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(unread.kind == .actedUnverified)
        #expect(unread.toggle?.stateAfter == .unreadable(.noScene))
    }

    // MARK: Attributing a toggle's readings

    /// A Mute with the id perception derives from its label, so every Mute in a scene shares it.
    private func mute(_ state: ControlState?, _ section: String? = nil, x: Double = 0.1, y: Double = 0.1)
        -> SceneElement {
        let bounds = NormalizedRect(x: x, y: y, width: 0.05, height: 0.02)
        return SceneElement(id: SceneIdentity.key(kind: .control, label: "Mute", bounds: bounds, isUnlabeled: false),
                            kind: .control, label: "Mute", bounds: bounds, state: state, section: section)
    }

    private func setMute(_ scenes: [PerceivedWindow], section: String? = nil, actuator: RecordingActuator = RecordingActuator(),
                         controls: FakeControls? = nil) async -> ActOutcome {
        await engine(scenes: ScriptedScenes(scenes), actuator: actuator, controls: controls)
            .act(request("Mute", verb: .setToggle, section: section, desired: .on))
    }

    @Test("a homonym in another section never proves the control, and never blocks it either")
    func toggleHomonymsBySection() async throws {
        let unread = await setMute([scene([mute(.off, "Track 1"), mute(.on, "Track 2", y: 0.4)]),
                                    scene([mute(nil, "Track 1"), mute(.on, "Track 2", y: 0.4)])], section: "Track 1")
        #expect(unread.kind == .actedUnverified)
        #expect(unread.toggle?.stateAfter == .unreadable(.indefinite), "Track 2's state is not Track 1's")
        let both = await setMute([scene([mute(.off, "Track 1"), mute(.off, "Track 2", y: 0.4)]),
                                  scene([mute(.on, "Track 1"), mute(.off, "Track 2", y: 0.4)])], section: "Track 1")
        #expect(both.kind == .foundActed)
        #expect(both.toggle?.stateAfter == .read(.on, .sameElement))
    }

    /// A strip's controls share a scene section and carry their strip as a container. The request names the
    /// container in its own case; the proof keeps what the scene showed.
    @Test("a toggle's proof keeps the section and container the scene showed, never the request's words")
    func toggleProofKeepsObservedPlace() async throws {
        func strip(_ state: ControlState, _ container: String, y: Double) -> SceneElement {
            var element = mute(state, "Strip", y: y)
            element.container = container
            return element
        }
        let outcome = await setMute([scene([strip(.off, "Track 1", y: 0.1), strip(.off, "Track 2", y: 0.4)]),
                                     scene([strip(.off, "Track 1", y: 0.1), strip(.on, "Track 2", y: 0.4)])],
                                    section: "track 2")
        #expect(outcome.kind == .foundActed)
        #expect(outcome.toggle?.section == "Strip")
        #expect(outcome.toggle?.container == "Track 2")
    }

    @Test("a homonym that appears after the click is told apart by the control's place, and never guessed")
    func toggleHomonymsByPlace() async throws {
        let rows = await setMute([scene([mute(.off)]), scene([mute(.on), mute(.off, y: 0.4)])])
        #expect(rows.kind == .foundActed)
        #expect(rows.toggle?.stateAfter == .read(.on, .sameElement))
        let blank = await setMute([scene([mute(.off)]), scene([mute(nil), mute(.on, y: 0.4)])])
        #expect(blank.toggle?.stateAfter == .unreadable(.indefinite), "the newcomer's state is not the control's")
        let resized = PerceivedWindow(scene: scene([mute(.on), mute(.off, y: 0.4)]).scene,
                                      frame: CGRect(x: 100, y: 100, width: 900, height: 800))
        let unsure = await setMute([scene([mute(.off)]), resized])
        #expect(unsure.toggle?.stateAfter == .unreadable(.severalMatches), "a resized window locates no place")
    }

    @Test("a scene of another window after the click proves nothing, even with an accessibility reading")
    func toggleOtherWindow() async throws {
        let other = await setMute([scene([mute(.off)]), scene([mute(.on)], title: "Other")],
                                  controls: FakeControls(toggle: .on))
        #expect(other.kind == .actedUnverified)
        #expect(other.toggle?.stateAfter == .unreadable(.otherWindow))
        // After the click, a lone control elsewhere may be a homonym: its state proves nothing (R5).
        let moved = await setMute([scene([mute(.off, "Track 1")]), scene([mute(.on, "Track 1", x: 0.5)])])
        #expect(moved.toggle?.stateAfter == .unreadable(.notAtPlace), "a lone control elsewhere is not the one clicked")
        let stayed = await setMute([scene([mute(.off, "Track 1")]), scene([mute(.on, "Track 1")])])
        #expect(stayed.toggle?.stateAfter == .read(.on, .sameElement), "the control at its place is itself")
    }

    @Test("reading the start again clicks the control where it is now, and never borrows a homonym")
    func toggleRereadGeometryAndIdentity() async throws {
        let actuator = RecordingActuator()
        let fresh = scene([mute(.off, x: 0.6)])
        let moved = await setMute([scene([mute(nil)]), fresh, scene([mute(.on, x: 0.6)])], actuator: actuator)
        #expect(moved.kind == .foundActed)
        #expect(actuator.gestures == [.click(at: fresh.globalPoint(of: mute(.off, x: 0.6)))])
        let borrowing = RecordingActuator()
        let other = await setMute([scene([mute(nil, "Track 1")]), scene([mute(.off, "Track 2", y: 0.4)])],
                                  section: "Track 1", actuator: borrowing)
        #expect(other.kind == .refused)
        #expect(other.toggle?.stateBefore == .unreadable(.notFound))
        #expect(borrowing.gestures.isEmpty, "no click on the strength of another control's state")
        let elsewhere = RecordingActuator()
        let retitled = await setMute([scene([mute(nil)]), scene([mute(.off)], title: "Other")], actuator: elsewhere)
        #expect(retitled.toggle?.stateBefore == .unreadable(.otherWindow))
        #expect(elsewhere.gestures.isEmpty)
    }

    /// A scene source that answers once and then has nothing, like a window that went away.
    final class OneScene: SceneProviding, @unchecked Sendable {
        var scene: PerceivedWindow?
        init(_ scene: PerceivedWindow) { self.scene = scene }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            guard let scene else { throw Unavailable() }
            self.scene = nil
            return scene
        }
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
                                   windows: ScriptedWindows([[popupWindow, mainWindow]])).act(request("Export"))
        #expect(outcome.kind == .actedNoop)
        #expect(outcome.message.contains("closed the menu"))
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
