//
//  SceneMapper.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// The Perception layer's scene as the lab hands it to a planner: the same
/// elements in the same order, numbered from one.
///
/// The number is the whole reason this mapper exists. A `PerceptionCore`
/// element carries a stable identity and no index, and `SemanticAction` names
/// an element by a small integer a model can copy back without inventing one.
/// The index is assigned here, in scene order, and means something only for
/// the observation it was assigned in: the next frame renumbers everything.
enum SceneMapper {

    /// Numbers the scene's elements and renders the text a model reads.
    /// `image` is the frame the elements were measured on, so a normalized
    /// bound is a pixel in it and an action can be aimed at an element's
    /// centre without a second conversion.
    static func observation(from scene: SceneSnapshot, image: CGImage,
                            timing: PerceptionTiming = PerceptionTiming()) -> SceneObservation {
        let elements = scene.elements.enumerated().map { offset, element in
            SceneObservation.Element(
                index   : offset + 1,
                identity: element.id,
                kind    : element.kind.rawValue,
                label   : element.label,
                role    : element.role,
                state   : element.state?.rawValue,
                value   : element.value,
                bounds  : element.bounds.cgRect
            )
        }
        return SceneObservation(
            image   : image,
            elements: elements,
            text    : text(of: scene, elements: elements),
            token   : scene.token.rawValue,
            timing  : timing
        )
    }

    /// The scene map: the header and the panels `SceneRendering` prints, with
    /// one numbered line per element under the panel it lives in.
    ///
    /// It is `mapText` with the indices added and nothing summarized. The map
    /// tier shows a handful of notable rows per panel, which is right for a
    /// model that names a target by label; here a planner may act only on an
    /// element it was shown, so an element left out of the text is an element
    /// that cannot be clicked.
    static func text(of scene: SceneSnapshot, elements: [SceneObservation.Element]) -> String {
        let placed = Array(zip(scene.elements.map(\.section), elements))
        var lines = ["app: \(scene.appName) — \"\(scene.windowTitle)\""]
        lines.append(scene.sections.isEmpty
                     ? "\(elements.count) elements"
                     : "\(elements.count) elements in \(scene.sections.count) sections")
        for section in scene.sections {
            let members = placed.filter { $0.0 == section.name }.map(\.1)
            let bounds = section.bounds
            lines.append(String(format: "▣ %@  @ %.2f,%.2f %.2f×%.2f — %d elements",
                                section.name, bounds.x, bounds.y, bounds.width, bounds.height,
                                members.count))
            lines.append(contentsOf: members.map(line))
        }
        let loose = placed.filter { $0.0 == nil }.map(\.1)
        if !loose.isEmpty {
            if !scene.sections.isEmpty { lines.append("▣ (unsectioned) — \(loose.count) elements") }
            lines.append(contentsOf: loose.map(line))
        }
        return lines.joined(separator: "\n")
    }

    /// One element, in the shape `PlannerPrompt` teaches the model to read:
    /// `[index] kind/role · label [state]  @ x,y w×h`, positions normalized to
    /// the window.
    private static func line(_ element: SceneObservation.Element) -> String {
        var line = "[\(element.index)] \(element.kind)"
        if let role = element.role { line += "/\(role)" }
        line += " · \(element.label)"
        if let state = element.state { line += " [\(state)]" }
        return line + String(format: "  @ %.2f,%.2f %.2f×%.2f", element.bounds.minX, element.bounds.minY,
                             element.bounds.width, element.bounds.height)
    }
}
