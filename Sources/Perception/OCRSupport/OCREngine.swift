import Foundation
import CoreGraphics
import Vision
import LocatorCore

/// Vision text recognition tuned for UI labels (not prose): no language correction. `accurate` (vs
/// `.fast`) matters for telling near-identical labels apart: identity matching keys on the differing
/// DIGIT ("Audio 6" vs "Audio 7"), and `.fast` garbles dense small text ("Audio 6" → "Audi06 7-"),
/// which defeats it. Capture and recall MUST pass the same `accurate` so the stored text and the recall
/// text agree. Runs locally (no TCC, no network) on a `CGImage`, so it's fully unit-testable offline.
public struct OCREngine: Sendable {
    public init() {}

    /// Vision loads its text-recognition network on the FIRST request of a process (measured ~40 ms of
    /// Espresso `load_network` inside the first frame). Call once at start-up, off the main thread, so
    /// the first real frame does not pay it. Idempotent and harmless to repeat.
    public static func warmUp() {
        let side = 32
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let img = ctx.makeImage() else { return }
        let wctx = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                           imagePixelSize: CGSize(width: side, height: side))
        _ = OCREngine().recognizeText(in: img, ctx: wctx, accurate: true)
    }

    public func recognizeText(in image: CGImage, ctx: WindowCoordinateContext, accurate: Bool = false) -> [OCRResult] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false   // UI labels aren't prose; correction hurts and slows

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = (request.results) ?? []
        return observations.compactMap { obs -> OCRResult? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // Convert the bottom-left normalized boundingBox to top-left image pixels immediately.
            return OCRResult(text: candidate.string, boxImagePx: ctx.visionNormToImagePx(obs.boundingBox))
        }
    }
}
