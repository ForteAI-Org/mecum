import CoreGraphics
import Foundation
import ScreenCaptureKit
import SeatCore
import WindowPlacement

/// What ScreenCaptureKit itself says about a window the driver could not get
/// a frame of. Run only on failure; the text goes straight into the error so
/// the person can report it without a debugger.
enum CaptureDiagnostics {
    static func report(windowNumber: Int, displayID: CGDirectDisplayID?, staged: Bool) async -> String {
        var lines: [String] = []
        lines.append("seat staged: \(staged)")
        if let server = WindowServerProbe.geometry(of: windowNumber) {
            let f = server.frame
            lines.append("server frame: \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) pt")
        } else {
            lines.append("server frame: unavailable")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let window = content.windows.first(where: { Int($0.windowID) == windowNumber }) {
                lines.append("SCK window: onScreen \(window.isOnScreen), layer \(window.windowLayer), "
                             + "frame \(Int(window.frame.width))×\(Int(window.frame.height)), "
                             + "app \(window.owningApplication?.applicationName ?? "?")")
                let filter = SCContentFilter(desktopIndependentWindow: window)
                lines.append("SCK window shot: " + (await probe(filter, size: window.frame.size)))
                lines.append("SCK window attachments: " + (await attachments(filter, size: window.frame.size)))
            } else {
                lines.append("SCK window: not in shareable content (\(content.windows.count) windows listed)")
            }
            if let displayID, let display = content.displays.first(where: { $0.displayID == displayID }) {
                lines.append("SCK display shot: " + (await probe(
                    SCContentFilter(display: display, excludingWindows: []),
                    size: CGSize(width: display.width, height: display.height))))
            } else {
                lines.append("SCK display: virtual display \(displayID.map(String.init) ?? "?") not listed")
            }
        } catch {
            lines.append("SCK shareable content failed: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// One direct screenshot through SCK, and whether it is all black.
    private static func probe(_ filter: SCContentFilter, size: CGSize) async -> String {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(size.width))
        configuration.height = max(1, Int(size.height))
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return "\(image.width)×\(image.height) px, \(isBlack(image) ? "all black" : "has content")"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    /// The geometry attachments of one sample buffer: what the kit's frame
    /// validation reads, so a rejected frame can be explained.
    private static func attachments(_ filter: SCContentFilter, size: CGSize) async -> String {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(size.width))
        configuration.height = max(1, Int(size.height))
        configuration.showsCursor = false
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { buffer, error in
                guard let buffer else {
                    continuation.resume(returning: "no buffer: \(error?.localizedDescription ?? "no error")")
                    return
                }
                let pixels = buffer.imageBuffer.map { "\(CVPixelBufferGetWidth($0))×\(CVPixelBufferGetHeight($0)) px" } ?? "no image buffer"
                let list = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
                guard let attachment = list?.first else {
                    continuation.resume(returning: "\(pixels), no attachments")
                    return
                }
                func rect(_ key: SCStreamFrameInfo) -> String {
                    let value = attachment[key]
                    let r = (value as? CGRect) ?? (value as? NSValue)?.rectValue
                    return r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil"
                }
                let status = (attachment[.status] as? NSNumber).map { String($0.intValue) } ?? "nil"
                continuation.resume(returning: "\(pixels), status \(status), screenRect \(rect(.screenRect)), "
                                    + "contentRect \(rect(.contentRect)), scaleFactor \(attachment[.scaleFactor] ?? "nil"), "
                                    + "contentScale \(attachment[.contentScale] ?? "nil")")
            }
        }
    }

    private static func isBlack(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let count = CFDataGetLength(data)
        var samples = 0
        var lit = 0
        var offset = 0
        while offset < count, samples < 4096 {
            if bytes[offset] > 16 || bytes[offset + 1] > 16 || bytes[offset + 2] > 16 { lit += 1 }
            samples += 1
            offset += max(4, count / 4096 / 4 * 4)
        }
        return lit == 0
    }
}
