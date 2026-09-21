import CoreGraphics
import Foundation
import LocatorCore

/// Locator scene → the kit's observation. Indices are assigned here, 1-based,
/// in scene order, and the text lists them so an action can name one.
enum LocatorSceneMapper {
    static func observation(from scene: PerceivedScene, image: CGImage, capture: Duration = .zero) -> SceneObservation {
        var timing = scene.timing
        timing.capture = capture
        let elements = scene.snapshot.elements.enumerated().compactMap { offset, e -> SceneElement? in
            guard e.pos.count == 4 else { return nil }
            return SceneElement(index: offset + 1, id: e.id, kind: e.kind, label: e.label,
                                role: e.role, state: e.state, value: e.value,
                                bounds: CGRect(x: e.pos[0], y: e.pos[1], width: e.pos[2], height: e.pos[3]))
        }
        return SceneObservation(image: image, elements: elements,
                                text: text(app: scene.snapshot.app, title: scene.snapshot.windowTitle, elements: elements),
                                token: scene.snapshot.token, timing: timing)
    }

    static func text(app: String, title: String, elements: [SceneElement]) -> String {
        var lines = ["app: \(app) — \"\(title)\"", "\(elements.count) elements"]
        for e in elements {
            var line = "[\(e.index)] \(e.kind)"
            if let role = e.role { line += "/\(role)" }
            line += " · \(e.label)"
            if let state = e.state { line += " [\(state)]" }
            line += String(format: "  @ %.2f,%.2f %.2f×%.2f", e.bounds.minX, e.bounds.minY, e.bounds.width, e.bounds.height)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
