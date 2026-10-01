//
//  ControlSession.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// ControlSession stands in for `AutomationSession` with the Seat, the Driver and perception replaced
/// by an invented window of controls, and nothing else replaced: `act` runs the real `ActionEngine`,
/// whose scene source reads that window, whose actuator clicks it and whose window listing lists it,
/// and every observed or returned scene goes through the same `SceneIntake`. It reads no application,
/// window, screen or file.
@MainActor
final class ControlSession: AutomationSessionOperating {

    /// Window is the invented application window, shared by the engine's role doubles. The engine
    /// performs one call at a time and the test changes the window only between calls, so its state
    /// has one writer at any moment. Element ids come from `SceneIdentity`, as perception derives
    /// them, so controls that share a label share an id.
    ///
    /// A gesture on a control may open a surface, as `reactions` says: a menu, listed as a pop-up
    /// window at the control and perceived as its rows, or a window, listed with its own number and
    /// perceived instead of this one. An Escape closes an open menu; `closeSurfaces` closes anything.
    nonisolated final class Window: @unchecked Sendable {

        /// Toggle is one control the window paints, top to bottom; a button has no state.
        struct Toggle {
            let label: String
            var state: ControlState?
            let section: String?
            /// The panel the scene shows in braces, as Pro Tools names each strip's controls by its track.
            let container: String?

            init(_ label: String, _ state: ControlState?, section: String? = nil, container: String? = nil) {
                self.label     = label
                self.state     = state
                self.section   = section
                self.container = container
            }

            func isShown(as element: SceneElement) -> Bool {
                element.label == label && element.section == section && element.container == container
            }
        }

        /// Surface is what a gesture opens.
        enum Surface: Equatable {
            case menu([String])
            case window(String)
        }

        var bundleID: String
        var title: String
        var toggles: [Toggle]
        /// What each gesture on a control opens, by the control's label; nothing when absent.
        var reactions: [String: [ClickEvidence.Gesture: Surface]] = [:]
        /// Whether an opened menu is listed far from the control clicked, as another menu would be.
        var menuElsewhere = false
        /// Whether an open menu is perceived as the Seat captures one (`SeatSceneProvider`): one still of the
        /// window and the menu, cropped to their union, with the window's title and controls beside its rows.
        var capturesMenuWithWindow = false
        /// Whether an open menu's rows can be read; false paints the menu with nothing legible.
        var menuRowsReadable = true
        /// Whether a gesture also opens a second, unrelated window.
        var opensSecondWindow = false
        /// Whether a click flips the toggle it lands on; false is a control that ignores it.
        var clickFlips = true
        /// Whether perception can read the states; false paints every toggle without one.
        var showsStates = true
        /// Whether, after a click, perception splits each toggle in two elements at one place.
        var splitsAfterClick = false
        /// Whether, after a click, the toggle clicked is painted without a state.
        var hidesClickedState = false
        /// The title the window shows once it has been clicked, as a window replaced by another.
        var titleAfterClick: String?
        /// How many of the engine's perceptions paint no state, counted from the next one.
        var perceptionsWithoutState = 0
        /// How far every toggle moves right, in window widths, from the engine's second perception.
        var shiftFromSecondPerception = 0.0
        /// After a click, the toggle clicked is no longer perceived, and a toggle with its label and section,
        /// in this state, is painted beside its place over this fraction of its width: the next strip's homonym.
        var homonymBesideAfterClick: (state: ControlState, overlap: Double)?
        /// Whether delivering a click fails.
        var clickFails = false
        var closesOnClick = false
        var closed = false
        var completeInventoryAvailable = true
        var hidesInsteadOfClosing = false
        var disappearsWithApplication = false
        /// Whether any gesture paints a "Details" control in this window: a change inside it, no new surface.
        var gestureRevealsDetails = false
        /// Whether the window server lists no rows for the application until the next gesture, although
        /// it answers: the list is empty, not unavailable.
        var listsNothingBeforeNextGesture = false
        private(set) var clicks = 0
        /// Every gesture delivered, in order.
        private(set) var gestures: [ClickEvidence.Gesture] = []
        private(set) var opened: Surface?
        private var openedAt = CGPoint.zero
        private var perceptions = 0
        private var offset = 0.0
        private var clicked: Int?

        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

        init(bundleID: String, title: String, toggles: [Toggle]) {
            self.bundleID = bundleID
            self.title    = title
            self.toggles  = toggles
        }

        func state(of label: String, section: String? = nil, container: String? = nil) -> ControlState? {
            toggles.first { $0.label == label && $0.section == section && $0.container == container }?.state
        }

        func set(_ label: String, _ state: ControlState, section: String? = nil, container: String? = nil) {
            guard let index = toggles.firstIndex(where: {
                $0.label == label && $0.section == section && $0.container == container
            }) else { return }
            toggles[index].state = state
        }

        /// Closes an open menu or window, as the person would between turns.
        func closeSurfaces() {
            opened = nil
        }

        /// The window the engine perceives, which advances the perception-driven effects: the open
        /// menu or window when there is one, else this window.
        func perceive() -> PerceivedWindow {
            perceptions += 1
            if perceptions == 2 { offset = shiftFromSecondPerception }
            let hidesStates = perceptionsWithoutState > 0
            perceptionsWithoutState = max(0, perceptionsWithoutState - 1)
            switch opened {
                case .menu(let items)? where capturesMenuWithWindow:
                    let union = frame.union(menuFrame)
                    return PerceivedWindow(scene: windowAndMenuScene(items, in: union), frame: union)
                case .menu(let items)?   : return PerceivedWindow(scene: menuScene(items), frame: menuFrame)
                case .window(let title)? : return PerceivedWindow(scene: windowScene(title), frame: frame)
                case nil                 : return PerceivedWindow(scene: scene(hidingStates: hidesStates), frame: frame)
            }
        }

        var scene: SceneSnapshot {
            switch opened {
                case .menu(let items)?  : menuScene(items)
                case .window(let title)?: windowScene(title)
                case nil                : scene(hidingStates: false)
            }
        }

        /// The windows the application lists, front to back, as the window server answers now.
        var listing: [WindowRow] {
            let parent = WindowRow(layer: 0, frame: frame.offsetBy(dx: 50, dy: 50), title: "Synthetic Project", number: 20)
            return listsNothingBeforeNextGesture || (closed && disappearsWithApplication) ? [] : (closed ? [parent] : rows + (closesOnClick ? [parent] : []))
        }

        /// The windows the application lists, front to back.
        var rows: [WindowRow] {
            let main = WindowRow(layer: 0, frame: frame, title: title, number: 1)
            let second = WindowRow(layer: 0, frame: frame.offsetBy(dx: 40, dy: 40), title: "Synthetic Log", number: 7)
            switch opened {
                case .menu?:
                    return [WindowRow(layer: 101, frame: menuFrame, title: nil, number: 5), main]
                        + (opensSecondWindow ? [second] : [])
                case .window(let title)?:
                    return [WindowRow(layer: 0, frame: frame.insetBy(dx: 100, dy: 100), title: title, number: 6), main]
                        + (opensSecondWindow ? [second] : [])
                case nil:
                    return [main]
            }
        }

        private var menuFrame: CGRect {
            let origin = menuElsewhere ? CGPoint(x: frame.maxX - 200, y: frame.maxY - 150) : openedAt
            return CGRect(origin: origin, size: CGSize(width: 180, height: 120))
        }

        private func menuScene(_ items: [String]) -> SceneSnapshot {
            var scene = SceneSnapshot(
                bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: "",
                viewportPixelSize: ViewportPixelSize(width: 360, height: 240),
                elements: (menuRowsReadable ? items : []).enumerated().map { index, item in
                    let bounds = NormalizedRect(x: 0.05, y: 0.05 + Double(index) * 0.2, width: 0.9, height: 0.15)
                    let id = SceneIdentity.key(kind: .text, label: item, bounds: bounds, isUnlabeled: false)
                    return SceneElement(id: id, kind: .text, label: item, bounds: bounds)
                }
            )
            scene.coverage = .window
            return scene
        }

        /// The window and its open menu in one scene over `union`, as a Seat capture with a pop-up open reads
        /// them: a window control mostly under the menu is hidden by it.
        private func windowAndMenuScene(_ items: [String], in union: CGRect) -> SceneSnapshot {
            func isHidden(_ element: SceneElement) -> Bool {
                let rect = CGRect(x: frame.minX + element.bounds.x * frame.width, y: frame.minY + element.bounds.y * frame.height,
                                  width: element.bounds.width * frame.width, height: element.bounds.height * frame.height)
                let covered = rect.intersection(menuFrame)
                return !covered.isNull && covered.width * covered.height > rect.width * rect.height * 0.5
            }
            func placed(_ elements: [SceneElement], from source: CGRect) -> [SceneElement] {
                elements.map { element in
                    let bounds = NormalizedRect(
                        x: (source.minX + element.bounds.x * source.width - union.minX) / union.width,
                        y: (source.minY + element.bounds.y * source.height - union.minY) / union.height,
                        width: element.bounds.width * source.width / union.width,
                        height: element.bounds.height * source.height / union.height)
                    return SceneElement(id: element.id, kind: element.kind, label: element.label, bounds: bounds,
                                        state: element.state, container: element.container, section: element.section)
                }
            }
            var scene = SceneSnapshot(
                bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: title,
                viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200),
                elements: placed(scene(hidingStates: false).elements.filter { !isHidden($0) }, from: frame)
                    + placed(menuScene(items).elements, from: menuFrame)
            )
            scene.coverage = .windowAndPopups
            return scene
        }

        private func windowScene(_ title: String) -> SceneSnapshot {
            let bounds = NormalizedRect(x: 0.4, y: 0.8, width: 0.2, height: 0.05)
            var scene = SceneSnapshot(
                bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: title,
                viewportPixelSize: ViewportPixelSize(width: 1200, height: 800),
                elements: [SceneElement(id: SceneIdentity.key(kind: .control, label: "OK", bounds: bounds,
                                                              isUnlabeled: false),
                                        kind: .control, label: "OK", bounds: bounds)]
            )
            scene.coverage = .window
            return scene
        }

        private func scene(hidingStates: Bool) -> SceneSnapshot {
            let split = splitsAfterClick && clicks > 0
            var scene = SceneSnapshot(
                bundleID: bundleID, appName: "Synthetic Mixer",
                windowTitle: clicks > 0 ? titleAfterClick ?? title : title,
                viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200),
                elements: toggles.enumerated().flatMap { index, toggle in
                    let painted = showsStates && !hidingStates && !(hidesClickedState && clicked == index)
                    var bounds = NormalizedRect(x: 0.1 + offset, y: 0.1 + Double(index) * 0.1, width: 0.1, height: 0.05)
                    var state = painted ? toggle.state : nil
                    if clicks > 0, clicked == index, let homonym = homonymBesideAfterClick {
                        bounds = NormalizedRect(x: bounds.x + bounds.width * (1 - homonym.overlap), y: bounds.y,
                                                width: bounds.width, height: bounds.height)
                        state = homonym.state
                    }
                    let id = SceneIdentity.key(kind: .control, label: toggle.label, bounds: bounds, isUnlabeled: false)
                    let element = SceneElement(id: id, kind: .control, label: toggle.label, bounds: bounds,
                                               state: state, container: toggle.container, section: toggle.section)
                    return split ? [element, element] : [element]
                } + (gestureRevealsDetails && !gestures.isEmpty ? [details] : [])
            )
            scene.coverage = .window
            return scene
        }

        private var details: SceneElement {
            let bounds = NormalizedRect(x: 0.6, y: 0.8, width: 0.1, height: 0.05)
            return SceneElement(id: SceneIdentity.key(kind: .control, label: "Details", bounds: bounds, isUnlabeled: false),
                                kind: .control, label: "Details", bounds: bounds)
        }

        func click(at point: CGPoint, gesture: ClickEvidence.Gesture) throws {
            if clickFails { throw AutomationFailure("Synthetic delivery failure.") }
            clicks += 1
            gestures.append(gesture)
            listsNothingBeforeNextGesture = false
            let normalized = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
            guard opened == nil, let element = scene.element(at: normalized),
                  let index = toggles.firstIndex(where: { $0.isShown(as: element) })
            else { return }
            clicked = index
            if closesOnClick { closed = true; return }
            if let surface = reactions[element.label]?[gesture] {
                opened = surface
                openedAt = point
                return
            }
            guard gesture == .click, clickFlips, let state = toggles[index].state else { return }
            toggles[index].state = state.toggled
        }

        func pressEscape() {
            if case .menu? = opened { opened = nil }
        }
    }

    nonisolated private struct Scenes: SceneProviding {
        let window: Window
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            guard !window.closed else { throw AutomationFailure("Window closed") }
            return window.perceive()
        }
    }

    nonisolated private struct Clicks: Actuating {
        let window: Window
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            switch gesture {
                case .click(let point, let button, let count):
                    let pointer: ClickEvidence.Gesture = button == .right ? .rightClick
                        : count == 3 ? .tripleClick : count == 2 ? .doubleClick : .click
                    try window.click(at: point, gesture: pointer)
                case .key(let code, _) where code == Key.escape:
                    window.pressEscape()
                default:
                    return
            }
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    nonisolated private struct Rows: WindowListing {
        let window: Window
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            window.listing
        }
        func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]? {
            guard window.completeInventoryAvailable else { return nil }
            if window.closed && window.hidesInsteadOfClosing {
                return window.rows + window.listing
            }
            return window.listing
        }
    }

    private let intake: SceneIntake
    let window: Window
    private(set) var id: UUID?
    /// Whether the tool call fails before the engine runs, like a transport error.
    var actFails = false

    init(intake: SceneIntake, window: Window) {
        self.intake = intake
        self.window = window
    }

    func open(application: String, window title: String?) async throws -> SceneSnapshot {
        id = UUID()
        return try await observe()
    }

    func observe() async throws -> SceneSnapshot {
        try await intake.learn(from: window.scene).scene
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        if actFails { throw AutomationFailure("Synthetic transport failure.") }
        let engine = ActionEngine(
            ActionEngine.Dependencies(scenes: Scenes(window: window), actuator: Clicks(window: window),
                                      windows: Rows(window: window)),
            pause: { _ in }
        )
        let outcome = await engine.act(ActionRequest(
            processID: 4242, bundleID: window.bundleID, appName: "Synthetic Mixer",
            target: target, verb: verb, section: section, desiredState: desiredState
        ))
        _ = try await intake.learn(fromOutcomeScene: outcome.scene)
        return outcome
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        throw AutomationFailure("The synthetic control window has no dropdown.")
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("The synthetic control window takes no typed or dragged input.")
    }

    func close() async {
        id = nil
    }
}
