import Foundation
import CoreGraphics
import LocatorCore

/// Per-step relocation artifacts for after-the-fact inspection: did each step land on the RIGHT element,
/// via which stage, at what confidence? For every relocated step it writes the captured window, an
/// overlay with the found box + a centre marker (where the synthetic click lands), the cropped found
/// region, and the recorded template — plus a `manifest.json` of the findings. Reading the `found` crop
/// next to the `template` (and the `overlay`) shows immediately whether a step is on target. Reuses
/// ``CropStore`` for atomic PNG I/O; the directory is wiped at the start of each run.
public final class RelocationDebugDumper: @unchecked Sendable {
    private let dir: URL
    private let out: CropStore
    private let crops: CropStore
    private let lock = NSLock()
    private var step = 0
    private var manifest: [[String: String]] = []

    public var directoryPath: String { dir.path }

    public init(directory: URL, crops: CropStore) {
        try? FileManager.default.removeItem(at: directory)   // fresh each run
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.dir = directory
        self.out = CropStore(directory: directory)
        self.crops = crops
    }

    /// Record one resolved step. Called from the (nonisolated) probe at each stage hit; the cascade
    /// short-circuits on the first hit, so exactly one call lands per relocated step.
    public func record(descriptor d: Descriptor, stage: String, window: CGImage,
                        foundRectImagePx rect: CGRect, confidence: Double, note: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        step += 1
        let base = String(format: "step%02d-%@-%@", step, slug(d.text.selfText ?? "untitled"), slug(stage))
        let bounds = CGRect(x: 0, y: 0, width: window.width, height: window.height)

        try? out.writePNG(window, name: "\(base)-window.png")
        if let overlay = Self.overlay(window, rect: rect) { try? out.writePNG(overlay, name: "\(base)-overlay.png") }
        let clipped = rect.integral.intersection(bounds)
        if !clipped.isNull, let found = window.cropping(to: clipped) { try? out.writePNG(found, name: "\(base)-found.png") }
        if let template = try? crops.readPNG(name: d.visual.cropRef) { try? out.writePNG(template, name: "\(base)-template.png") }

        manifest.append([
            "step": "\(step)",
            "selfText": d.text.selfText ?? "(none)",
            "stage": stage,
            "confidence": String(format: "%.3f", confidence),
            "foundRectImagePx": "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))",
            "clickCenterImagePx": "\(Int(rect.midX)),\(Int(rect.midY))",
            "neighbors": d.text.neighbors.map(\.text).joined(separator: " | "),
            "note": note ?? "",
        ])
        writeManifest()
    }

    /// A step that resolved NOTHING — dump just the window + diagnostics (no box) so a miss is
    /// inspectable too (e.g. what OCR actually read when an own-text lookup failed).
    public func recordMiss(descriptor d: Descriptor, stage: String, window: CGImage, note: String?) {
        lock.lock(); defer { lock.unlock() }
        step += 1
        let base = String(format: "step%02d-%@-%@-MISS", step, slug(d.text.selfText ?? "untitled"), slug(stage))
        try? out.writePNG(window, name: "\(base)-window.png")
        manifest.append([
            "step": "\(step)",
            "selfText": d.text.selfText ?? "(none)",
            "stage": "\(stage)-MISS",
            "neighbors": d.text.neighbors.map(\.text).joined(separator: " | "),
            "note": note ?? "",
        ])
        writeManifest()
    }

    private func writeManifest() {
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    private func slug(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(24))
    }

    /// Draw the found box (red) and its centre marker (green) over the window. The window is indexed
    /// top-left; the CGContext is bottom-left, so the rect's y is flipped.
    static func overlay(_ image: CGImage, rect: CGRect) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let box = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height)
        ctx.setLineWidth(max(2, CGFloat(w) / 500))
        ctx.setStrokeColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.stroke(box)
        ctx.setFillColor(red: 0.2, green: 1, blue: 0.2, alpha: 0.9)
        ctx.fill(CGRect(x: box.midX - 5, y: box.midY - 5, width: 10, height: 10))
        return ctx.makeImage()
    }
}
