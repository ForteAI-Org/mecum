import Foundation
import AppKit
import CoreGraphics
import CaptureSupport
import OCRSupport
import LocatorCore

/// THE FAST-VERIFICATION TIER — the one internal knob where perception is allowed to trade text quality
/// for speed, kept in a file of its own so its blast radius is auditable at a glance.
///
/// STATUS: a DIAGNOSTIC, not a production path. No production path calls this — only
/// `locator debug-compare` and `FastCompareTests` do, deliberately (ticket 17). It was specified as the
/// comparison path for the scroll verb and act, and both declined it on measurement. The scroll verdict
/// is cheaper AND finer as pixels — `PaneScroller`'s frame-change ratio and
/// `HorizontalScroller.contentSlidePx`, both read from frames the gesture captures anyway — and its label
/// witness comes free from scenes the verb builds anyway, so a sample here is a strict ADDITION to a step
/// that already has its answer. Act's "nothing changed" is answered exactly,
/// in 0.15s, by the frame-hash `SceneCache`. What survives is the harness that measured all of that,
/// plus the scope guard below. Before wiring a consumer in, read the two bullets at the end of this
/// comment: between them they rule out every comparison the engine currently makes.
///
/// Measured on a real 3024px frame: OCR `.accurate` 782ms vs `.fast` 104ms, the fast pass finding 122 of
/// the 140 texts. Those 18 missing/garbled runs are fatal to a scene the agent READS (identity matching
/// keys on the differing digit — "Audio 6" vs "Audio 7" — and `.fast` renders it "Audi06 7-"), and
/// harmless to a scene nobody reads: a COMPARISON only asks "is this the same pane content as a moment
/// ago?", and a garble that is stable across both samples cancels out.
///
/// So this tier may only ever feed SET COMPARISONS — a movement or presence check, never a scene — and
/// its output is deliberately a `Set<String>` of folded labels: there is no path from it to a
/// `SceneSnapshot`, no positions, no kinds, no states. Every scene the agent reads still goes through
/// `SceneBuilder.detect` on `.accurate`, unchanged; this helper bypasses the scene pipeline entirely
/// rather than threading a mode flag through it (spec decision), and it touches NO shared state — not
/// the `SceneCache`, not the sightings ledger, not the brain — so a fast sample can never make a scene
/// worse. `FastCompareTests` pins that guard: a full scene's element set is byte-identical around use.
///
/// Two things a consumer must know, both measured with `locator debug-compare` on live windows:
/// • COMPARE FAST WITH FAST. Two fast samples of an untouched window drift by 0–1 labels (Pro Tools'
///   3000×1592 edit window: ≤1; its track list: 0; Premiere: 0), so a set difference of a couple of
///   labels is noise, not movement — judge with a tolerance, never exact equality. Fast-vs-ACCURATE is
///   a different matter: on a dense low-contrast pane the fast pass agreed with the accurate one on
///   only 11 of 29 keys — the garbles are stable frame to frame but they are not the accurate
///   spellings, so a fast sample may not be diffed against a scene's labels except as a coarse
///   presence check.
/// • It is warm-path fast. Cold (first call in a process: Vision's model load + SCK's first capture)
///   0.37–0.50s; warm 0.12–0.18s. In `locator serve` the warm-up is paid once at start.
extension SceneBuilder {

    /// A comparison sample: what text the pane held, plus the frame it was read from (so a caller that
    /// samples twice can tell that both samples came from the same window).
    public struct CompareSample: Sendable {
        public let labels: Set<String>
        public let window: WindowCaptureService.WindowProbe
        public let pixelSize: CGSize

        public init(labels: Set<String>, window: WindowCaptureService.WindowProbe, pixelSize: CGSize) {
            self.labels = labels; self.window = window; self.pixelSize = pixelSize
        }
    }

    /// Capture `bundleID`'s frontmost window (or the frontmost app's) and read the labels inside
    /// `sectionRectNorm` with fast OCR. Nil section = the whole window.
    public func compareLabels(bundleID: String?, sectionRectNorm: CGRect? = nil) async -> CompareSample? {
        struct Resolved: Sendable { let bundle: String; let pid: pid_t }
        let appOpt: Resolved? = await MainActor.run {
            let running = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                ?? NSWorkspace.shared.frontmostApplication
            guard let r = running, let bundle = r.bundleIdentifier else { return nil }
            return Resolved(bundle: bundle, pid: r.processIdentifier)
        }
        guard let app = appOpt, let win = capture.frontmostWindowFrame(pid: app.pid) else { return nil }
        return await compareLabels(bundle: app.bundle, title: win.title,
                                   windowFrameGlobalPt: win.frameGlobalPt, sectionRectNorm: sectionRectNorm)
    }

    /// Hop-free entry for a caller that already knows the window it is watching — it saves the
    /// app-resolve and the CGWindowList probe, which is most of what is left after the OCR got cheap.
    /// Built for the scroll verb, which never took it (see the STATUS note above), so this entry has no
    /// caller at all — `debug-compare` measures the `bundleID:` one above, which PAYS the app-resolve and
    /// the probe. Read the harness's numbers as the pessimistic bound on this entry, and keep it: it is
    /// the shape any future consumer wants.
    public func compareLabels(bundle: String, title: String?, windowFrameGlobalPt: CGRect,
                              sectionRectNorm: CGRect? = nil) async -> CompareSample? {
        let t = StageTimer("compareLabels \(bundle)")
        guard let shot = (try? await capture.captureMatchingWindow(
                  bundleID: bundle, title: title, axWindowFrameGlobalPt: windowFrameGlobalPt)) ?? nil
        else { t.stamp("captureMatchingWindow → nil"); return nil }
        t.stamp("captureMatchingWindow")
        let labels = Self.compareLabels(in: shot.image, sectionRectNorm: sectionRectNorm, ocr: ocr)
        t.stamp("fastOCR (\(labels.count) labels) — done")
        return CompareSample(labels: labels,
                             window: WindowCaptureService.WindowProbe(title: shot.title ?? title,
                                                                      frameGlobalPt: shot.frameGlobalPt),
                             pixelSize: shot.pixelSize)
    }

    /// The pure core: fast-OCR label set for a window-normalized region of an already-captured frame.
    /// Cropping BEFORE the OCR is not just scoping — it is most of the speed on a large window.
    public static func compareLabels(in img: CGImage, sectionRectNorm: CGRect?,
                                     ocr: OCREngine = OCREngine()) -> Set<String> {
        let region = regionPx(sectionRectNorm, in: img)
        guard region.width >= 8, region.height >= 8,
              let crop = region == fullRectPx(of: img) ? img : img.cropping(to: region) else { return [] }
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                          imagePixelSize: CGSize(width: crop.width, height: crop.height))
        // accurate: false — THE knob. Nothing else in the engine passes it.
        return Set(ocr.recognizeText(in: crop, ctx: ctx, accurate: false)
            .lazy
            .filter { !ElementGrouper.isKnobGlyph($0.text) }   // knob circles misread as "O" are not text
            .compactMap { compareKey($0.text) })
    }

    /// A window-normalized rect as pixels of `img`, clamped to it. Nil = the whole frame.
    public static func regionPx(_ sectionRectNorm: CGRect?, in img: CGImage) -> CGRect {
        let full = fullRectPx(of: img)
        guard let r = sectionRectNorm else { return full }
        return CGRect(x: r.minX * CGFloat(img.width), y: r.minY * CGFloat(img.height),
                      width: r.width * CGFloat(img.width), height: r.height * CGFloat(img.height))
            .integral.intersection(full)
    }

    private static func fullRectPx(of img: CGImage) -> CGRect {
        CGRect(x: 0, y: 0, width: img.width, height: img.height)
    }

    /// Fold a raw OCR run into a comparison key — the SAME fold the scene diff uses
    /// (`KnowledgeText.normalize`: lowercased alphanumerics), so a fast sample and a scene's labels are
    /// at least keyed alike. That does NOT make them comparable: the fast pass's garbles are stable
    /// frame to frame but they are not the accurate spellings (11 of 29 keys agreed on a dense pane), so
    /// a shared fold buys a coarse presence check and nothing more — compare fast with fast. Runs that
    /// fold to nothing — the stray ticks and dashes the fast pass sprays, which flicker frame to frame —
    /// are dropped: counting those as content would report movement where nothing moved, the one lie a
    /// comparison must never tell.
    public static func compareKey(_ raw: String) -> String? {
        let folded = KnowledgeText.normalize(raw)
        return folded.isEmpty ? nil : folded
    }
}
