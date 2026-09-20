import AppKit
import CoreGraphics
import PerceptionCore

/// SceneOverlayView renders an immutable scene in top-left point coordinates. It does no detection.
final class SceneOverlayView: NSView {
    var scene: SceneSnapshot?
    var targetFrame = CGRect.zero
    var screenFrame = CGRect.zero
    var visibleRegions: [CGRect] = []
    var sectionsOnly = false
    var labels = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.addRects(visibleRegions.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) })
        context.clip()

        func box(_ bounds: NormalizedRect) -> CGRect {
            CGRect(x: targetFrame.minX - screenFrame.minX + bounds.x * targetFrame.width,
                   y: targetFrame.minY - screenFrame.minY + bounds.y * targetFrame.height,
                   width: bounds.width * targetFrame.width, height: bounds.height * targetFrame.height)
        }
        func drawLabel(_ label: String, at rect: CGRect, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: color, .backgroundColor: NSColor.black.withAlphaComponent(0.85)
            ]
            (String(label.prefix(60)) as NSString).draw(
                at: CGPoint(x: rect.minX + 2, y: max(0, rect.minY - 13)), withAttributes: attributes)
        }
        if !sectionsOnly {
            for element in scene.elements {
                let color: NSColor
                if element.role != nil { color = .systemCyan }
                else {
                    switch element.kind {
                        case .icon: color = .systemGreen
                        case .image: color = .systemPurple
                        case .overlayCandidate: color = .systemYellow
                        default: color = .systemOrange
                    }
                }
                color.setStroke()
                let rect = box(element.bounds)
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 1.2
                path.stroke()
                if labels { drawLabel(element.label, at: rect, color: color) }
            }
        }
        for section in scene.sections {
            let rect = box(section.bounds).insetBy(dx: 1, dy: 1)
            NSColor.systemPink.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.setLineDash([7, 4], count: 2, phase: 0)
            path.stroke()
            if labels { drawLabel(section.name, at: rect, color: .systemPink) }
        }
    }
}
