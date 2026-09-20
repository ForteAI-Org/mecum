//
//  StillCapturer.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import ScreenCaptureKit

/// StillCapturer takes one still through ScreenCaptureKit, at the screen's own pixel scale, of a
/// single window or of a region of a display. It is the foreground eye: a window on the real
/// screen, no Seat. The Seat's own capture fills the same need for an adopted window.
///
/// Every call queries the shareable content afresh, so a window that opened a moment ago is seen.
/// Screen Recording must be granted to the process, or every window reads as not shared.
public struct StillCapturer: Sendable {

    public init() {}

    /// A still of one window, cursor hidden, sized to the window's frame in points times the display's
    /// pixel scale.
    public func captureWindow(number: Int, frame: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == number }) else {
            throw CaptureFailure.windowNotShared(number: number)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(max(1, filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width       = Int(frame.width * scale)
        configuration.height      = Int(frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// A still of a region of the screen, in global top-left points, cursor hidden. The region is
    /// clipped to the display that contains its origin. This is how a window and the pop-up floating
    /// beside it are seen as one image.
    public func captureRegion(_ region: CGRect) async throws -> CGImage {
        guard region.width > 0, region.height > 0 else { throw CaptureFailure.emptyRegion }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(region.origin) }) else {
            throw CaptureFailure.displayNotFound(origin: region.origin)
        }
        let clipped = region.intersection(display.frame)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(max(1, filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect  = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width       = Int(clipped.width * scale)
        configuration.height      = Int(clipped.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
