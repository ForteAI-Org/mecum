import AppKit
import CoreGraphics
import PerceptionCore

/// SceneOverlay owns nonactivating, click-through panels on the current displays. It only renders
/// supplied scenes: no recognition, memory, input posting, or application activation. Main actor only.
/// The caller must call close when its inspection ends, and clear when the observation becomes stale.
public final class SceneOverlay {
    private var panels: [OverlayPanel] = []
    private var displayFrames: [CGRect] = []

    public init() {}

    /// Draws normalized scene boxes in the captured window's global top-left point frame. Drawing
    /// is clipped to supplied visible areas; an empty list draws nothing. Labels are optional.
    public func show(_ scene: SceneSnapshot, frame: CGRect, visibleRegions: [CGRect],
                     sectionsOnly: Bool = false, labels: Bool = false) {
        let screens = NSScreen.screens
        if displayFrames != screens.map(\.frame) {
            close()
            displayFrames = screens.map(\.frame)
            panels = screens.map { screen in
                let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false, screen: screen)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                panel.contentView = SceneOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
                return panel
            }
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        for panel in panels {
            guard let view = panel.contentView as? SceneOverlayView else { continue }
            let screenFrame = OverlayGeometry.appKitFrame(panel.frame, primaryHeight: primaryHeight)
            view.scene = scene
            view.targetFrame = frame
            view.screenFrame = screenFrame
            view.visibleRegions = visibleRegions
            view.sectionsOnly = sectionsOnly
            view.labels = labels
            view.needsDisplay = true
            if visibleRegions.contains(where: { $0.intersects(screenFrame) }) {
                panel.orderFrontRegardless()
                view.displayIfNeeded()
            } else { panel.orderOut(nil) }
        }
    }

    /// Hides every panel immediately. Previously supplied boxes cannot remain on screen.
    public func clear() {
        for panel in panels { panel.orderOut(nil) }
    }

    /// Closes and releases all owned panels. Safe to repeat.
    public func close() {
        for panel in panels { panel.close() }
        panels.removeAll()
        displayFrames.removeAll()
    }
}
