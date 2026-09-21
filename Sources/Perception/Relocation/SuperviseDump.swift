import Foundation
import CoreGraphics
import ImageIO
import LocatorCore

/// SUPERVISED MODE — the engine's flight recorder. When `LOCATOR_SUPERVISE_DIR` is set on the serve
/// process, every scene build drops its evidence there: the EXACT frame that was parsed, the map the
/// LLM reads, the full element JSON, and an overlay of every box. This is how a human (or a
/// supervising model) checks the engine's claims against the pixels instead of hypothesizing —
/// map says "Export in top bar", overlay shows where that box actually sits on the frame.
///
/// Debug-only by construction: nothing here runs unless the env var is set, dumps are best-effort
/// (a failed write never breaks perception), and the directory is local. Cache-hit builds record a
/// one-line marker instead of re-dumping identical pixels.
enum SuperviseDump {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["LOCATOR_SUPERVISE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func stamp(now: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
        return String(format: "%02d%02d%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000)
    }

    /// Full dump for a fresh parse. Returns the stamp so callers can narrate it.
    @discardableResult
    static func dump(frame: CGImage, scene: SceneSnapshot, now: Date) -> String? {
        guard let dir = directory else { return nil }
        let ts = stamp(now: now)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writePNG(frame, to: dir.appendingPathComponent("\(ts)-frame.png"))
        try? scene.mapText().data(using: .utf8)?
            .write(to: dir.appendingPathComponent("\(ts)-map.txt"))
        if let json = try? DescriptorStore.makeEncoder().encode(scene) {
            try? json.write(to: dir.appendingPathComponent("\(ts)-scene.json"))
        }
        if let over = overlay(frame, scene: scene) {
            writePNG(over, to: dir.appendingPathComponent("\(ts)-overlay.png"))
        }
        FileHandle.standardError.write(Data("🔬 supervise: dumped \(ts) (\(scene.elements.count) elements)\n".utf8))
        return ts
    }

    /// Cache hits mean pixel-identical frames — record THAT (it is evidence too) without re-writing images.
    static func markCacheHit(scene: SceneSnapshot, now: Date) {
        guard let dir = directory else { return }
        let line = "\(stamp(now: now)) cache-hit token=\(scene.token)\n"
        let url = dir.appendingPathComponent("cache-hits.log")
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)) }
        else { try? Data(line.utf8).write(to: url) }
    }

    static func writePNG(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Every element box on the frame: controls green, icons cyan, unlabeled red, text thin gray;
    /// section seams orange. Kind is visible at a glance, misplaced boxes jump out.
    static func overlay(_ img: CGImage, scene: SceneSnapshot) -> CGImage? {
        let (w, h) = (img.width, img.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        func rect(_ pos: [Double]) -> CGRect {   // normalized top-left → CG bottom-left pixels
            CGRect(x: pos[0] * Double(w), y: (1 - pos[1] - pos[3]) * Double(h),
                   width: pos[2] * Double(w), height: pos[3] * Double(h))
        }
        for s in scene.sections where s.pos.count == 4 {
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.6, blue: 0, alpha: 0.9))
            ctx.setLineWidth(3)
            ctx.stroke(rect(s.pos))
        }
        for e in scene.elements where e.pos.count == 4 {
            let color: CGColor
            switch (e.kind, e.unlabeled == true) {
            case (_, true):        color = CGColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: 0.95)
            case ("control", _):   color = CGColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 0.95)
            case ("icon", _):      color = CGColor(srgbRed: 0.2, green: 0.85, blue: 1, alpha: 0.95)
            default:               color = CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 0.6)
            }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(e.kind == "text" ? 1 : 2)
            ctx.stroke(rect(e.pos))
        }
        return ctx.makeImage()
    }
}
