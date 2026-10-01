//
//  SyntheticWindowSession.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SyntheticWindowSession stands in for `AutomationSession` with the Seat and the Driver replaced by
/// an invented window, and nothing else replaced. It reads no application, window, screen or file.
/// Every observed scene and every scene an action returns goes through the same `SceneIntake`, and
/// a select's proof is built by the real `DropdownReadback` rule, exactly as the selector does.
@MainActor
final class SyntheticWindowSession: AutomationSessionOperating {

    private let intake: SceneIntake
    private(set) var id: UUID?
    private(set) var calls: [String] = []

    var bundleID: String
    var windowTitle: String
    /// The window's controls, left to right; a dropdown reads its value as its label.
    var labels: [String]
    /// Synthetic states and effects are fixtures; ActionEngine attribution is tested separately.
    var toggleStates: [String: ControlState] = [:]
    var clickEffects: [String: [ClickEvidence.Gesture: ClickEvidence.Effect]] = [:]
    /// What the dropdown reads after a select; the requested item when nil.
    var valueAfterSelect: String?
    var observeFails = false
    /// Invented captions shown as text before the controls, such as a tab name or a field label.
    var captions: [String] = []
    /// What a control does, by label, as the brain would annotate it; a dropdown says so here.
    var descriptions: [String: String] = [:]
    private var openedSurface: ClickEvidence.Effect?

    init(intake: SceneIntake, bundleID: String, windowTitle: String, labels: [String]) {
        self.intake      = intake
        self.bundleID    = bundleID
        self.windowTitle = windowTitle
        self.labels      = labels
    }

    private var scene: SceneSnapshot {
        if let openedSurface {
            switch openedSurface {
                case .menuOpened(let items):
                    var menu = SceneSnapshot(
                        bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: "",
                        viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
                        elements: items.enumerated().map { index, item in
                            SceneElement(id: "menu|\(index)", kind: .text, label: item,
                                         bounds: NormalizedRect(x: 0.05, y: 0.1 + Double(index) * 0.1,
                                                                width: 0.3, height: 0.05))
                        }
                    )
                    menu.coverage = .window
                    return menu
                case .windowOpened(let title):
                    var window = SceneSnapshot(
                        bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: title,
                        viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: []
                    )
                    window.coverage = .window
                    return window
                case .windowClosed, .unattributed:
                    break
            }
        }
        var scene = SceneSnapshot(
            bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: windowTitle,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: captions.enumerated().map { index, caption in
                SceneElement(id: "text|\(index)", kind: .text, label: caption,
                             bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.1, width: 0.15, height: 0.04))
            } + labels.enumerated().map { index, label in
                SceneElement(id: "control|\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.2, width: 0.15, height: 0.05),
                             state: toggleStates[label], does: descriptions[label])
            }
        )
        scene.coverage = .window
        return scene
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
        openedSurface = nil
        return try await observe()
    }

    func observe() async throws -> SceneSnapshot {
        calls.append("observe")
        if observeFails { throw AutomationFailure("Synthetic capture failure.") }
        return try await intake.learn(from: scene).scene
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome {
        calls.append("act")
        let before = scene
        guard case .found(let control) = before.resolve(target: target, preferStateful: verb == .setToggle,
                                                        section: section) else {
            return ActOutcome(.honestMiss, "synthetic target missing or ambiguous", scene: before)
        }
        if verb == .setToggle {
            guard let desiredState, let stateBefore = toggleStates[control.label] else {
                return ActOutcome(.actedUnverified, "synthetic toggle state unavailable", scene: before)
            }
            let changed = stateBefore != desiredState
            if changed { toggleStates[control.label] = desiredState }
            let proof = ToggleEvidence(
                bundleID: bundleID, windowTitle: windowTitle, control: control.label,
                controlRole: control.role, section: control.section, container: control.container,
                desiredState: desiredState,
                stateBefore: .read(stateBefore, .resolvedElement),
                click: changed ? .sent : .none,
                stateAfter: changed ? .read(desiredState, .sameElement) : nil
            )
            let after = scene
            _ = try? await intake.learn(fromOutcomeScene: after)
            return ActOutcome(changed ? .foundActed : .actedNoop, "synthetic toggle", scene: after,
                              evidence: .toggle(proof))
        }
        guard let gesture = ClickEvidence.Gesture(verb) else {
            return ActOutcome(.refused, "unsupported synthetic action", scene: before)
        }
        let effect = clickEffects[control.label]?[gesture] ?? .unattributed(.noChange)
        openedSurface = effect
        let after = scene
        let proof = ClickEvidence(
            bundleID: bundleID, windowTitle: windowTitle, target: control.label,
            targetRole: control.role, section: control.section, container: control.container, gesture: gesture,
            delivery: .sent, effect: effect
        )
        _ = try? await intake.learn(fromOutcomeScene: after)
        return ActOutcome(proof.isVerified ? .foundActed : .actedUnverified,
                          "synthetic gesture", scene: after, evidence: .click(proof))
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        let before = scene
        guard case .found(let opener) = before.resolve(target: control),
              let index = labels.firstIndex(of: opener.label) else {
            return ActOutcome(.honestMiss, "dropdown '\(control)' is missing or ambiguous", scene: before)
        }
        labels[index] = valueAfterSelect ?? item
        let after = scene
        let evidence = DropdownEvidence(
            bundleID: bundleID, windowTitle: windowTitle, control: opener.label, controlRole: opener.role,
            section: opener.section, valueBefore: opener.value ?? opener.label, requestedItem: item,
            readback: .atControl(opener.bounds, in: after, windowSizeKept: true),
            menuClosedByChoice: true
        )
        let outcome = ActOutcome.dropdownSelection(evidence, menuWindowNumber: 555_111_999, scene: after)
        _ = try? await intake.learn(fromOutcomeScene: outcome.scene)
        return outcome
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        throw AutomationFailure("The synthetic window has no input targets.")
    }

    func close() async {
        calls.append("close")
        id = nil
    }
}
