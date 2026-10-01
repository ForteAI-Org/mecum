//
//  IntakeSession.swift
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

/// IntakeSession stands in for `AutomationSession` with the Seat and the Driver replaced by a
/// synthetic window, and nothing else replaced: every observed scene and every scene an action
/// returns goes through the same `SceneIntake`, and a select's proof is built by the real
/// `DropdownReadback` rule from the before and after scenes, exactly as the selector does.
@MainActor
final class IntakeSession: AutomationSessionOperating {

    private let intake: SceneIntake
    private(set) var id: UUID?
    private(set) var calls: [String] = []

    var bundleID: String
    var windowTitle: String
    /// The window's controls, left to right; a dropdown reads its value as its label.
    var labels: [String]
    /// What the dropdown reads after a select; the requested item when nil.
    var valueAfterSelect: String?
    var observeFails = false

    init(intake: SceneIntake, bundleID: String, windowTitle: String, labels: [String]) {
        self.intake      = intake
        self.bundleID    = bundleID
        self.windowTitle = windowTitle
        self.labels      = labels
    }

    private var scene: SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: bundleID, appName: "Synthetic Mixer", windowTitle: windowTitle,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: labels.enumerated().map { index, label in
                SceneElement(id: "control|\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.2, width: 0.15, height: 0.05))
            }
        )
        scene.coverage = .window
        return scene
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
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
        throw AutomationFailure("The synthetic window has no act targets.")
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
