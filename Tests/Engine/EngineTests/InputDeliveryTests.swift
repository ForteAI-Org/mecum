//
//  InputDeliveryTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// The inputs beyond a click over the act cycle's own doubles: what goes out, in which order, and
/// which outcome the reading afterwards earns. No screen, no sleep.
@Suite("Input delivery")
struct InputDeliveryTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls
    typealias FakeActivation    = ActionEngineTests.FakeActivation

    // MARK: Fixtures

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                       title: "Export", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56),
                                        title: nil, number: 9)

    /// A text field centred at 500,432.
    private func field(value: String?, id: String = "control|name") -> SceneElement {
        SceneElement(id: id, kind: .control, label: "Project Name",
                     bounds: NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.03), role: "AXTextField",
                     value: value)
    }

    /// A row centred at 940,832.
    private let export = SceneElement(id: "control|export", kind: .control, label: "Export",
                                      bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.08, height: 0.03))

    private let trash = SceneElement(id: "control|trash", kind: .control, label: "Trash",
                                     bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.08, height: 0.03))

    private func scene(_ elements: [SceneElement], title: String = "Export", token: String? = nil) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements,
            token: token.map(SceneToken.init(rawValue:))
        ), frame: frame)
    }

    /// The window with a contextual menu of these rows open in the pop-up at 300,300.
    private func menuScene(_ labels: [String]) -> PerceivedWindow {
        let rows = labels.enumerated().map { index, label in
            SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label, bounds: NormalizedRect(
                x: 0.22, y: Double(207 + 28 * index) / 800, width: 0.05, height: 14.0 / 800.0))
        }
        return scene([export] + rows)
    }

    private func request(_ input: InputRequest.Input, dryRun: Bool = false) -> InputRequest {
        InputRequest(processID: pid, bundleID: "com.x", appName: "X", input: input, isDryRun: dryRun)
    }

    private func engine(
        scenes     : ScriptedScenes,
        actuator   : RecordingActuator = RecordingActuator(),
        windows    : ScriptedWindows? = nil,
        controls   : FakeControls? = nil,
        activation : FakeActivation? = nil,
        permissions: ActionPermissions = ActionPermissions()
    ) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: scenes, actuator: actuator, windows: windows ?? ScriptedWindows([[mainWindow]]),
                controls: controls, activation: activation
            ),
            permissions: permissions, pause: { _ in }
        )
    }

    private var fieldPoint: CGPoint { scene([]).globalPoint(of: field(value: nil)) }

    /// Where the engine aims at `export`: 940,832, give or take the last bit of a double.
    private var exportPoint: CGPoint { scene([]).globalPoint(of: export) }

    private let selectAll: [Gesture] = [
        .key(code: Key.upArrow, modifiers: .command),
        .key(code: Key.downArrow, modifiers: [.command, .shift]),
        .character("a", modifiers: .command),
    ]

    // MARK: type_text

    @Test("replacing clicks the field, selects what it holds, types, and the value read back decides")
    func replaceIsVerifiedByTheValue() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "My Project"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message == "typed into 'Project Name': the field reads 'My Project'")
        #expect(actuator.gestures == [.click(at: fieldPoint)] + selectAll + [.type("My Project")])
        #expect(actuator.confirmations == [.observed])
    }

    @Test("an unreadable field is selected with a triple click, and one read as empty is only clicked, with no key")
    func replaceSendsNoKeyToAFieldItCannotRead() async {
        for (value, preparation) in [(nil, [Gesture.click(at: fieldPoint, count: 3)]),
                                     ("",  [Gesture.click(at: fieldPoint)])] as [(String?, [Gesture])] {
            let actuator = RecordingActuator()
            _ = await engine(scenes: ScriptedScenes([scene([field(value: value)])]), actuator: actuator)
                .deliver(request(.typeText("io la sto usando", into: "Project Name", replacing: true)))
            // Slack's empty composer reads as nothing, and an Up arrow there edits the last message.
            #expect(actuator.gestures == preparation + [.type("io la sto usando")])
        }
    }

    @Test("a value that is not the typed text is acted_unverified, and says what the field reads")
    func wrongValueIsUnverified() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "New Project 2My Project"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("reads 'New Project 2My Project', not 'My Project'"))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("without a focus reading the after-scene's value decides, and no value at all is unverified")
    func sceneValueIsTheFallback() async {
        let typed = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")]),
                                                         scene([field(value: "My Project")])]))
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(typed.kind == .foundActed, Comment(rawValue: typed.message))
        let unread = await engine(scenes: ScriptedScenes([scene([field(value: nil)])]))
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(unread.kind == .actedUnverified)
        #expect(unread.message.contains("no field's value could be read"))
    }

    @Test("a short text is typed a key pair per character and a long one is inserted on one event")
    func shortTypesLongInserts() async {
        for (count, inserts) in [(ActionEngine.typedTextLimit, false), (ActionEngine.typedTextLimit + 1, true)] {
            let text = String(repeating: "a", count: count)
            let actuator = RecordingActuator()
            _ = await engine(scenes: ScriptedScenes([scene([field(value: "")])]), actuator: actuator)
                .deliver(request(.typeText(text, into: "Project Name", replacing: true)))
            #expect(actuator.gestures.last == (inserts ? .insert(text) : .type(text)))
        }
    }

    @Test("appending moves to the field's end instead of selecting, and expects the old value first")
    func appendKeepsTheValue() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "Budget 2027"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "Budget")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText(" 2027", into: "Project Name", replacing: false)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: fieldPoint), .key(code: Key.downArrow, modifiers: .command),
                                      .type(" 2027")])
    }

    @Test("a dry run types nothing, and an empty text is refused")
    func typeDryRunAndEmpty() async {
        let actuator = RecordingActuator()
        let rehearsal = await engine(scenes: ScriptedScenes([scene([field(value: "x")])]), actuator: actuator)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(rehearsal.message == "would click 'Project Name' at 500,432, select what it holds and type 10 "
            + "characters")
        let empty = await engine(scenes: ScriptedScenes([scene([field(value: "x")])]), actuator: actuator)
            .deliver(request(.typeText("", into: "Project Name", replacing: true)))
        #expect(empty.kind == .refused)
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: press_key

    @Test("Command-Q and Command-W are refused before any event, even with destructive actions allowed")
    func quitAndCloseAreRefused() async {
        let actuator = RecordingActuator()
        let allowed = ActionPermissions(allowsDestructive: true)
        for chord in [KeyChord(.character("q"), modifiers: .command),
                      KeyChord(.character("w"), modifiers: [.command, .shift])] {
            let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                       permissions: allowed)
                .deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == .refused)
        }
        #expect(actuator.gestures.isEmpty)
    }

    @Test("Command-Delete needs the person's permission")
    func commandDeleteIsDestructive() async {
        let chord = KeyChord(.delete, modifiers: .command)
        let refused = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.pressKey(chord, times: 1)))
        #expect(refused.kind == .refused)
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                         permissions: ActionPermissions(allowsDestructive: true))
            .deliver(request(.pressKey(chord, times: 1)))
        #expect(actuator.gestures == [.key(code: Key.delete, modifiers: .command)])
    }

    @Test("a key is found_acted only when the scene changed, and repeats go out as separate presses")
    func keyIsJudgedByTheScene() async {
        let actuator = RecordingActuator()
        let landed = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Render Queue")]),
                                  actuator: actuator)
            .deliver(request(.pressKey(KeyChord(.return), times: 1)))
        #expect(landed.kind == .foundActed)
        #expect(landed.message == "pressed return: navigates to Render Queue")
        #expect(actuator.gestures == [.key(code: Key.return)])

        let repeated = RecordingActuator()
        let ghost = await engine(scenes: ScriptedScenes([scene([export])]), actuator: repeated)
            .deliver(request(.pressKey(KeyChord(.down), times: 3)))
        #expect(ghost.kind == .actedUnverified)
        #expect(ghost.message.hasPrefix("pressed down 3 times: this window did NOT change"))
        #expect(repeated.gestures == Array(repeating: .key(code: Key.downArrow), count: 3))
        #expect(repeated.confirmations == [.absent])
    }

    @Test("a letter's chord goes by character, and an unseen Command chord says a menu does not answer here")
    func menuShortcutNote() async {
        let actuator = RecordingActuator()
        let copy = KeyChord(.character("c"), modifiers: .command)
        let background = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.pressKey(copy, times: 1)))
        #expect(actuator.gestures == [.character("c", modifiers: .command)])
        #expect(background.kind == .actedUnverified)
        #expect(background.message.contains("does nothing on this background window"))
        let foreground = await engine(scenes: ScriptedScenes([scene([export])]),
                                      activation: FakeActivation(frontmost: pid))
            .deliver(request(.pressKey(copy, times: 1)))
        #expect(!foreground.message.contains("background window"))
    }

    @Test("a key dry run presses nothing")
    func keyDryRun() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.pressKey(KeyChord(.character("n"), modifiers: [.command, .shift]), times: 1),
                             dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message == "would press shift+cmd+n into X's window")
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: scroll

    @Test("a scroll goes out over its target, down negative, and new rows are its effect")
    func scrollOverTarget() async {
        let actuator = RecordingActuator()
        let row = SceneElement(id: "text|budget", kind: .text, label: "Budget 2027",
                               bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02))
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export, row])]),
                                   actuator: actuator)
            .deliver(request(.scroll(lines: -3, over: "Export")))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message == "scrolled 3 lines down over 'Export': reveals elements")
        #expect(actuator.gestures == [.scroll(at: exportPoint, deltaY: -3)])
    }

    @Test("without a target a scroll turns over the window's centre, and nothing moving is unverified")
    func scrollOverWindow() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.scroll(lines: 2, over: nil)))
        #expect(actuator.gestures == [.scroll(at: CGPoint(x: 600, y: 500), deltaY: 2)])
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("Nothing moved"))
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.scroll(lines: 1, over: nil), dryRun: true))
        #expect(rehearsal.message == "would scroll 1 line up over the window's centre at 600,500")
        let none = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.scroll(lines: 0, over: nil)))
        #expect(none.kind == .refused)
    }

    // MARK: drag

    @Test("a drag goes from one target to the other, and a mere repaint is unverified")
    func dragBetweenTargets() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export, field(value: nil)], token: "a"),
                                                           scene([export, field(value: nil)], token: "b")]),
                                   actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Project Name"))))
        #expect(actuator.gestures == [.drag(from: exportPoint, to: fieldPoint)])
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("cannot be told from a repaint"))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("a drag by an offset ends that far away, and a change it caused is found_acted")
    func dragByOffset() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Moved")]),
                                   actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .offset(dx: -40, dy: 10))))
        let end = CGPoint(x: exportPoint.x - 40, y: exportPoint.y + 10)
        #expect(actuator.gestures == [.drag(from: exportPoint, to: end)])
        #expect(outcome.kind == .foundActed)
    }

    @Test("dropping on a destructive target is refused, and a drag dry run drags nothing")
    func dragPolicyAndDryRun() async {
        let actuator = RecordingActuator()
        let refused = await engine(scenes: ScriptedScenes([scene([export, trash])]), actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Trash"))))
        #expect(refused.kind == .refused)
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export, field(value: nil)])]), actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Project Name")), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: context_menu

    @Test("a contextual menu opens with a right click and its row is chosen by the pop-up path")
    func contextMenuChoosesByKeyboard() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow],
                                       [popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menuScene(["Copy", "Paste"]),
                                                           scene([export])]),
                                   actuator: actuator, windows: windows)
            .deliver(request(.contextMenu(on: "Export", item: "Paste")))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: exportPoint, button: .right), .type("Paste"),
                                      .key(code: Key.rightArrow), .key(code: Key.return)])
        #expect(actuator.confirmations == [.observed])
    }

    @Test("an item the menu does not offer is an honest miss, and the menu is closed instead of guessed at")
    func contextMenuMissingItem() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menuScene(["Copy", "Paste"])]),
                                   actuator: actuator, windows: windows)
            .deliver(request(.contextMenu(on: "Export", item: "Rename")))
        #expect(outcome.kind == .honestMiss)
        #expect(outcome.message.contains("it offered 'Copy', 'Paste'; the menu was closed"))
        #expect(actuator.gestures == [.click(at: exportPoint, button: .right), .key(code: Key.escape)])
    }

    @Test("no menu after the right click is unverified, a destructive item is refused, a dry run clicks nothing")
    func contextMenuEdges() async {
        let actuator = RecordingActuator()
        let noMenu = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.contextMenu(on: "Export", item: "Copy")))
        #expect(noMenu.kind == .actedUnverified)
        #expect(noMenu.message.contains("no contextual menu could be read"))
        #expect(actuator.confirmations == [.unknown])

        let untouched = RecordingActuator()
        let destructive = await engine(scenes: ScriptedScenes([scene([export])]), actuator: untouched)
            .deliver(request(.contextMenu(on: "Export", item: "Move to Trash")))
        #expect(destructive.kind == .refused)
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export])]), actuator: untouched)
            .deliver(request(.contextMenu(on: "Export", item: "Copy"), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(untouched.gestures.isEmpty)
    }
}
