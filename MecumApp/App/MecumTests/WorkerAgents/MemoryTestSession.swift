//
//  MemoryTestSession.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore

/// MemoryTestSession answers select with the evidence the real selector would attach, or without it.
@MainActor
final class MemoryTestSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var withEvidence = true
    var observeFails = false
    var actFails = false
    var actOutcome: ActOutcome?
    /// What the control reads after the menu closes; the requested item when nil.
    var readback: DropdownReadback?
    private(set) var selections = 0

    /// The controls the synthetic window shows, left to right.
    var sceneLabels: [String] = []
    /// The application and window the scenes show; the selection's evidence stays in the routing window.
    var sceneBundleID = "test.synthetic.mixer"
    var sceneWindowTitle = "Synthetic Routing"

    private var scene: SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: sceneBundleID, appName: "Synthetic Mixer", windowTitle: sceneWindowTitle,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: sceneLabels.enumerated().map { index, label in
                SceneElement(id: "control|\(label)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.2, width: 0.15, height: 0.05))
            }
        )
        scene.coverage = .window
        return scene
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot { scene }

    func observe() async throws -> SceneSnapshot {
        if observeFails { throw AutomationFailure("Synthetic capture failure.") }
        return scene
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        if actFails { throw AutomationFailure("Synthetic transport failure.") }
        return actOutcome ?? ActOutcome(.foundActed, "synthetic act", scene: scene)
    }

    func menu(path: [String], expectingWindow: String) async throws -> ActOutcome {
        return ActOutcome(.foundActed, "synthetic native menu", evidence: .menu(.init(
            bundleID: sceneBundleID, windowTitle: sceneWindowTitle, path: path,
            expectedWindow: expectingWindow, effect: .openedWindow)))
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        selections += 1
        guard withEvidence else { return ActOutcome(.foundActed, "synthetic selection", scene: scene) }
        let evidence = DropdownEvidence(
            bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing", control: control,
            controlRole: "AXPopUpButton", section: nil, valueBefore: control, requestedItem: item,
            readback: readback ?? .window(item), menuClosedByChoice: true
        )
        return ActOutcome.dropdownSelection(evidence, menuWindowNumber: 987_654_321, scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        if actFails { throw AutomationFailure("Synthetic transport failure.") }
        return ActOutcome(.foundActed, "synthetic input", scene: scene)
    }

    func close() async { id = nil }
}
