import CoreGraphics
import ScreenCaptureKit

/// One-shot window capture via `SCScreenshotManager` (not a persistent `SCStream` — the use case is
/// user-initiated, so per-call startup is imperceptible and we sidestep the stream lifecycle).
/// Nonisolated: invoked only from within `WindowCaptureService`'s single nonisolated async domain.
public struct ScreenshotManagerCapture: WindowCapture {
    public init() {}

    public func capture(window: SCWindow) async throws -> CGImage {
        let scale = Self.backingScale(for: window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // Native pixels = points × backing scale, so the image isn't downsampled on Retina.
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// COMPOSITOR-TRUTH region capture: the literal pixels on screen inside `rectGlobalPt`, at native
    /// scale. This is the eye for GPU-drawn pop-ups whose CGWindow is a proxy — capturing Premiere's
    /// format dropdown "window" returned the MAIN window's content squeezed to the popup's size
    /// (measured, frame-perfect wrong); the display region shows what the USER actually sees.
    public func captureRegion(rectGlobalPt rect: CGRect) async throws -> CGImage? {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) })
            ?? content.displays.first else { return nil }
        let scale = Self.backingScale(for: rect)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // sourceRect is in the display's coordinate space (points, origin at the display's top-left).
        config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                                   width: rect.width, height: rect.height)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Backing scale of the display the window sits on, from CoreGraphics (no AppKit, no coordinate
    /// flip — CG display space is top-left global points, matching the window frame). Falls back to 2.0.
    static func backingScale(for frame: CGRect) -> CGFloat {
        var displayID = CGMainDisplayID()
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var matching: UInt32 = 0
        if CGGetDisplaysWithRect(frame, 8, &ids, &matching) == .success, matching > 0 {
            displayID = ids[0]
        }
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2.0 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}
