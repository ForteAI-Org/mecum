import Foundation
import CoreGraphics
import AppKit
import AXSupport
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

/// Live implementation of the cascade stages, wiring AX / capture / NCC to the real system.
///
/// Nonisolated (so it satisfies the `Sendable` `RelocationProbes` protocol); AX work hops to the main
/// actor via `MainActor.run`, returning only `Sendable` data (frames, outcomes) so no `AXUIElement`
/// crosses a boundary. Each stage captures the current window as needed (re-capture per stage is fine
/// for a user-initiated recall; sharing one capture is a later optimization).
///
/// Stages wired: 1 (axPath), 2 (geometryNCC), 3a (contextNCC). Stages 3b (text constellation) and 4
/// (segmentation score) return `.miss` until their live wiring + the real segmenter (M7) land.
public struct LiveRelocationProbes: RelocationProbes {
    let ax: AXEngine
    let captureService: WindowCaptureService
    let matcher: NCCTemplateMatcher
    let ocr: OCREngine
    let segmenter: ConnectedComponentSegmenter
    let crops: CropStore
    let tuning: RelocationTuning
    let debugDump: RelocationDebugDumper?
    /// Per-relocate memo: the window is captured ONCE and the full-window OCR computed at most ONCE,
    /// then shared across every cascade stage. The window cannot change mid-relocate (actuation happens
    /// only AFTER relocate returns), and a fresh instance is created per relocate, so it never goes
    /// stale. Accessed sequentially (the cascade awaits one stage at a time) → no lock needed.
    let frameCache = RelocateFrame()

    /// Reference box so the value-type probe can memoize across stages. `@unchecked Sendable`: only ever
    /// touched on the single, sequential relocate that owns this instance.
    final class RelocateFrame: @unchecked Sendable {
        var attempted = false
        var resolved: (captured: CapturedWindow, ctx: WindowCoordinateContext, win: WindowRef)?
        var ocrRuns: [(text: String, box: CGRect)]?
    }

    public init(crops: CropStore, ax: AXEngine,
                captureService: WindowCaptureService = WindowCaptureService(),
                matcher: NCCTemplateMatcher = NCCTemplateMatcher(),
                ocr: OCREngine = OCREngine(),
                segmenter: ConnectedComponentSegmenter = ConnectedComponentSegmenter(),
                tuning: RelocationTuning = .defaults,
                debugDump: RelocationDebugDumper? = nil) {
        self.crops = crops
        self.ax = ax
        self.captureService = captureService
        self.matcher = matcher
        self.ocr = ocr
        self.segmenter = segmenter
        self.tuning = tuning
        self.debugDump = debugDump
    }

    struct WindowRef: Sendable { let bundleID: String; let title: String?; let frame: CGRect }

    // MARK: Stage 1 — AX path replay

    public func axPath(_ d: Descriptor) async -> StageOutcome {
        guard d.ax.available, !d.ax.path.isEmpty else { Self.log("stage1 axPath: skipped (ax unavailable)"); return .miss }
        Self.log("stage1 axPath: hopping to MainActor for replay")
        return await MainActor.run { () -> StageOutcome in
            guard let pid = Self.pid(forBundleID: d.app.bundleID) else { Self.log("stage1: no running pid for \(d.app.bundleID)"); return .miss }
            Self.log("stage1: replaying \(d.ax.path.count)-step path in pid \(pid)")
            guard case .resolved(let element) = ax.replayOutcome(d.ax.path, inApp: pid, leafAttrs: d.ax.leafAttrs),
                  let frame = ax.frameGlobalPt(element) else { Self.log("stage1: replay miss"); return .miss }
            Self.log("stage1: HIT at \(frame)")
            return .hit(rectImagePx: nil, rectScreenPt: frame, confidence: 1.0, healed: nil)
        }
    }

    // MARK: Stages 2 / 3a — NCC (small region around expected pos, then full window)

    public func geometryNCC(_ d: Descriptor) async -> StageOutcome { await ncc(d, fullWindow: false) }
    public func contextNCC(_ d: Descriptor) async -> StageOutcome { await ncc(d, fullWindow: true) }

    private func ncc(_ d: Descriptor, fullWindow: Bool) async -> StageOutcome {
        let tag = fullWindow ? "stage3a contextNCC" : "stage2 geometryNCC"
        guard let (captured, ctx, _) = await frame(d) else { Self.log("\(tag): no current window"); return .miss }
        Self.log("\(tag): captured \(Int(captured.pixelSize.width))×\(Int(captured.pixelSize.height)), matching")
        // Stage 3a normally matches the wider CONTEXT crop (more to disambiguate on). But a NO-TEXT
        // element — its image IS its identity, e.g. an avatar — is matched by its OWN crop full-window:
        // the distinctive picture survives a list reorder, whereas the context's neighbouring rows don't.
        let hasText = d.text.selfText?.isEmpty == false
        let cropName = (fullWindow && hasText) ? d.visual.contextCropRef : d.visual.cropRef
        guard let template = try? crops.readPNG(name: cropName) else { Self.log("\(tag): crop \(cropName) unreadable"); return .miss }

        let currentPx = captured.pixelSize
        let capturePx = CGSize(width: d.app.windowSizeAtCapture.width * d.app.backingScale,
                               height: d.app.windowSizeAtCapture.height * d.app.backingScale)
        let imageRect = CGRect(x: 0, y: 0, width: captured.image.width, height: captured.image.height)

        // Stage 2 only searches near the expected position — crop to that small region BEFORE the NCC so
        // we grayscale ~tens-of-k px, not the whole 5M-px window. Stage 3a genuinely scans the full window.
        // (maxTemplateDimension caps a coarse template so the NCC can't blow up either way.)
        let best: NCCMatch?
        let offset: CGPoint
        if fullWindow {
            best = matcher.match(template: template, in: captured.image, searchRegion: nil,
                                 scales: tuning.multiScaleLadder, maxTemplateDimension: 128,
                                 maxSearchDimension: tuning.stage3aMaxWindowDimension)
            offset = .zero
        } else {
            let expected = DescriptorAssembler.expectedRectImagePx(
                geometry: d.geometry, captureWindowPixelSize: capturePx, currentWindowPixelSize: currentPx)
            let pad = tuning.stage2SearchRegionPx / 2
            let regionRect = expected.insetBy(dx: -pad, dy: -pad).integral.intersection(imageRect)
            guard !regionRect.isNull, let regionCrop = captured.image.cropping(to: regionRect) else {
                Self.log("\(tag): empty search region"); return .miss
            }
            best = matcher.match(template: template, in: regionCrop, searchRegion: nil, scales: [1.0], maxTemplateDimension: 128)
            offset = regionRect.origin
        }
        Self.log("\(tag): best NCC \(best.map { String(format: "%.3f", $0.score) } ?? "nil") (need ≥ \(d.thresholds.nccMin))")
        guard let match = best, match.score >= d.thresholds.nccMin else { return .miss }

        let rectPx = CGRect(x: match.locationPx.x + offset.x, y: match.locationPx.y + offset.y,
                            width: CGFloat(template.width), height: CGFloat(template.height))

        // Look-alike guard: a high NCC in the search region can be a SIBLING that merely looks like the
        // target — "Audio 5"'s template scores ~0.97 on "Audio 6" because the differing digit is a few
        // px. If the element has text, confirm the text AT the matched spot is the SAME identity; if it's
        // a look-alike, miss so the cascade falls through to text-constellation (exact text + neighbours,
        // which disambiguates correctly). OCR only the matched region — cheap; boxes are ignored here.
        if let selfText = d.text.selfText, !selfText.isEmpty {
            let checkRect = rectPx.insetBy(dx: -6, dy: -6).integral.intersection(imageRect)
            let texts = (checkRect.isNull ? nil : captured.image.cropping(to: checkRect))
                .map { ocr.recognizeText(in: $0, ctx: ctx, accurate: true).map(\.text) } ?? []
            if !texts.contains(where: { TextConstellation.identityMatches($0, selfText) }) {
                Self.log("\(tag): NCC \(String(format: "%.3f", match.score)) but text \(texts) ≠ \"\(selfText)\" — look-alike, routing onward")
                return .miss
            }
        } else if !d.text.neighbors.isEmpty {
            // NO-TEXT element with ROW-LABEL neighbors (an identical repeating toggle/checkbox): a high NCC
            // matches EVERY identical instance, so its crop alone can't tell the TikTok toggle from Vimeo's.
            // Accept this box ONLY if a globally-unique recorded neighbor (its row label) sits at its
            // expected offset from it; else miss → the cascade falls through to stage 3b's locateByNeighbors,
            // which anchors the correct row. (A no-text element with NO neighbors — a unique avatar whose
            // IMAGE is its identity — keeps the plain NCC hit, unguarded.)
            let runs = fullWindowOCR(captured, ctx)
            let offsetScale = capturePx.width > 0 ? currentPx.width / capturePx.width : 1
            if !TextConstellation.hasUniqueNeighborSupport(box: rectPx, neighbors: d.text.neighbors,
                                                           offsetScale: offsetScale, tolerancePadPx: 24, runs: runs) {
                Self.log("\(tag): NCC \(String(format: "%.3f", match.score)) but no unique row-label support at the box — routing onward")
                return .miss
            }
        }

        let healed = match.score >= tuning.selfHealMinConfidence
            ? DescriptorAssembler.healed(d, foundRectPx: rectPx, currentWindowPx: currentPx, now: LocatorTime.now()) : nil
        debugDump?.record(descriptor: d, stage: fullWindow ? "stage3a-contextNCC" : "stage2-geometryNCC",
                          window: captured.image, foundRectImagePx: rectPx, confidence: match.score)
        return .hit(rectImagePx: rectPx, rectScreenPt: ctx.imagePxToAXGlobal(rectPx), confidence: match.score, healed: healed)
    }

    // MARK: Stage 3b — text constellation

    public func textConstellation(_ d: Descriptor) async -> StageOutcome {
        let hasSelfText = d.text.selfText?.isEmpty == false
        guard hasSelfText || !d.text.neighbors.isEmpty else { Self.log("stage3b: no selfText or neighbors"); return .miss }
        guard let (captured, ctx, _) = await frame(d) else { Self.log("stage3b: no window"); return .miss }

        let currentPx = captured.pixelSize
        let capturePx = CGSize(width: d.app.windowSizeAtCapture.width * d.app.backingScale,
                               height: d.app.windowSizeAtCapture.height * d.app.backingScale)

        Self.log("stage3b: OCR")
        let runs = fullWindowOCR(captured, ctx)
        let offsetScale = capturePx.width > 0 ? currentPx.width / capturePx.width : 1
        let hasNeighbors = !d.text.neighbors.isEmpty
        // Diagnostic for the debug dump: which OCR runs even loosely resemble the self-text (so a dump
        // shows whether the exact label was read at all, vs. lost to OCR / merged into another run).
        let debugNote: String? = debugDump == nil ? nil
            : "ocr-selfText-candidates: [" + (d.text.selfText.map { st in runs.filter { TextConstellation.matches(st, $0.text) }.map(\.text) } ?? []).joined(separator: " | ") + "]"

        // (a) Self-text constellation — best when the element's own text is unchanged. A UNIQUE identity
        // match needs NO neighbor confirmation: "Audio 4" matched exactly one run, so it's unambiguous
        // even if some recorded neighbors scrolled off-screen (which would otherwise drag the fraction
        // below the gate and lose a perfectly good hit). Neighbor agreement is only REQUIRED to
        // disambiguate when MORE than one run matches the identity (e.g. two "Cancel" buttons). Self-heal
        // still only fires with strong neighbor corroboration, so a marginal match can't poison geometry.
        let identityCount = (d.text.selfText.map { st in runs.filter { TextConstellation.identityMatches(st, $0.text) }.count }) ?? 0
        if let selfText = d.text.selfText, !selfText.isEmpty,
           let located = TextConstellation.locate(selfText: selfText, neighbors: d.text.neighbors,
                                                  offsetScale: offsetScale, tolerancePadPx: 24, runs: runs),
           identityCount <= 1 || !hasNeighbors || located.neighborFraction >= 0.5 {
            Self.log("stage3b: self-text located (identityCount \(identityCount), neighborFraction \(String(format: "%.2f", located.neighborFraction)))")
            let confidence = hasNeighbors ? 0.6 + 0.4 * located.neighborFraction : 0.6
            let healed = (hasNeighbors && located.neighborFraction >= 0.9 && confidence >= tuning.selfHealMinConfidence)
                ? DescriptorAssembler.healed(d, foundRectPx: located.box, currentWindowPx: currentPx, now: LocatorTime.now()) : nil
            debugDump?.record(descriptor: d, stage: "stage3b-textConstellation",
                              window: captured.image, foundRectImagePx: located.box, confidence: confidence, note: debugNote)
            return .hit(rectImagePx: located.box, rectScreenPt: ctx.imagePxToAXGlobal(located.box),
                        confidence: confidence, healed: healed)
        }

        // (b) Neighbor-anchored fallback — the element's OWN text/appearance changed (e.g. a dropdown
        // whose value was edited). Triangulate its position from the STABLE surrounding labels. Don't
        // self-heal: we located the slot, not a verified element, so the stored crop/geometry stay put.
        if hasNeighbors {
            let elementSizePx = CGSize(width: d.visual.cropSize.width * offsetScale,
                                       height: d.visual.cropSize.height * offsetScale)
            // Two DISCRIMINATING neighbours agreeing is a strong anchor — generic per-row labels are
            // already filtered out inside locateByNeighbors, so this isn't a 2-of-many coincidence.
            let minAgree = 2
            let imgBounds = CGRect(x: 0, y: 0, width: captured.image.width, height: captured.image.height)
            if let anchored = TextConstellation.locateByNeighbors(
                neighbors: d.text.neighbors, offsetScale: offsetScale, tolerancePadPx: 24,
                elementSizePx: elementSizePx, minAgree: minAgree, runs: runs),
               imgBounds.contains(CGPoint(x: anchored.box.midX, y: anchored.box.midY)),
               TextConstellation.hasUniqueNeighborSupport(box: anchored.box, neighbors: d.text.neighbors,
                                                          offsetScale: offsetScale, tolerancePadPx: 24, runs: runs),
               neighborAnchorIdentityOK(d, anchoredBox: anchored.box, window: captured.image, imageRect: imgBounds) {
                // Triangulated inside the window (not extrapolated off-screen), anchored by a GLOBALLY-
                // UNIQUE neighbor (so the repeating per-row layout alone can't pin a wrong instance — the
                // "Audio 3" → clicked "Audio 28" false positive), AND — for a no-text element whose IMAGE
                // is its identity (an avatar) — the recorded crop actually appears there.
                Self.log("stage3b: neighbor-anchored, anchorFraction \(String(format: "%.2f", anchored.anchorFraction))")
                let confidence = 0.5 + 0.4 * anchored.anchorFraction
                debugDump?.record(descriptor: d, stage: "stage3b-neighborAnchored",
                                  window: captured.image, foundRectImagePx: anchored.box, confidence: confidence, note: debugNote)
                return .hit(rectImagePx: anchored.box, rectScreenPt: ctx.imagePxToAXGlobal(anchored.box),
                            confidence: confidence, healed: nil)
            }
        }
        Self.log("stage3b: no self-text or neighbor anchor")
        debugDump?.recordMiss(descriptor: d, stage: "stage3b", window: captured.image, note: debugNote)
        return .miss
    }

    /// For a NO-TEXT element (its image IS its identity, e.g. an avatar) confirm the recorded crop
    /// actually appears at a neighbor-anchored position — otherwise the triangulation landed on a
    /// neighbouring row's *different* picture. Text elements (whose value may legitimately have changed)
    /// are trusted without this check.
    private func neighborAnchorIdentityOK(_ d: Descriptor, anchoredBox: CGRect, window: CGImage, imageRect: CGRect) -> Bool {
        if d.text.selfText?.isEmpty == false { return true }
        guard let tmpl = try? crops.readPNG(name: d.visual.cropRef) else { return false }
        let region = anchoredBox.insetBy(dx: -8, dy: -8).integral.intersection(imageRect)
        guard !region.isNull, let crop = window.cropping(to: region) else { return false }
        let score = matcher.match(template: tmpl, in: crop, searchRegion: nil,
                                  scales: tuning.multiScaleLadder, maxTemplateDimension: 128)?.score ?? 0
        Self.log("stage3b: neighbor-anchor visual check NCC \(String(format: "%.3f", score)) (need ≥ \(d.thresholds.nccMin))")
        return score >= d.thresholds.nccMin
    }

    // MARK: Stage 4 — segmentation + score (last resort)

    public func segmentationScore(_ d: Descriptor) async -> StageOutcome {
        guard let (captured, ctx, _) = await frame(d) else { return .miss }

        let currentPx = captured.pixelSize
        let capturePx = CGSize(width: d.app.windowSizeAtCapture.width * d.app.backingScale,
                               height: d.app.windowSizeAtCapture.height * d.app.backingScale)

        // Segment a region around the expected position (not the whole window — perf).
        let expected = DescriptorAssembler.expectedRectImagePx(geometry: d.geometry, captureWindowPixelSize: capturePx, currentWindowPixelSize: currentPx)
        let pad = max(expected.width, expected.height) + 100
        Self.log("stage4: segmenting region around expected \(expected)")
        let candidates = segmenter.segment(in: captured.image, region: expected.insetBy(dx: -pad, dy: -pad))
        guard !candidates.isEmpty else { Self.log("stage4: no candidates"); return .miss }
        guard let template = try? crops.readPNG(name: d.visual.cropRef) else { return .miss }

        let runs = fullWindowOCR(captured, ctx)
        let expectedSize = CGSize(width: expected.width, height: expected.height)
        let imageRect = CGRect(x: 0, y: 0, width: captured.image.width, height: captured.image.height)

        // Bound the work: score only the candidates nearest the expected position.
        let center = CGPoint(x: expected.midX, y: expected.midY)
        let ranked = Array(candidates.sorted {
            hypot($0.bboxPx.midX - center.x, $0.bboxPx.midY - center.y) < hypot($1.bboxPx.midX - center.x, $1.bboxPx.midY - center.y)
        }.prefix(40))

        let features = ranked.map { candidate -> CandidateFeatures in
            let box = candidate.bboxPx
            // NCC over the small candidate region only (crop first) — not the whole window per candidate.
            let regionCrop = box.insetBy(dx: -8, dy: -8).integral.intersection(imageRect)
            let ncc = captured.image.cropping(to: regionCrop).flatMap {
                matcher.match(template: template, in: $0, searchRegion: nil, scales: tuning.multiScaleLadder, maxTemplateDimension: 128)?.score
            } ?? 0
            let hasText = d.text.selfText?.isEmpty == false
            let exact = d.text.selfText.map { st in runs.contains { box.intersects($0.box) && TextConstellation.matches(st, $0.text) } } ?? false
            let cxFrac = currentPx.width > 0 ? box.midX / currentPx.width : 0
            let cyFrac = currentPx.height > 0 ? box.midY / currentPx.height : 0
            let dist = hypot(cxFrac - d.geometry.windowRelative.x, cyFrac - d.geometry.windowRelative.y)
            let sizeRatio = expectedSize.width > 0 ? Double(box.width / expectedSize.width) : 1
            return CandidateFeatures(visualNCC: ncc, elementHasText: hasText, textExactMatch: exact,
                                     textFuzzyRatio: exact ? 1 : 0, neighborFraction: 0,
                                     positionDistanceFraction: Double(dist), classMatches: false, sizeRatio: sizeRatio)
        }

        let decision = Scorer(tuning: tuning, thresholds: d.thresholds).evaluate(features)
        Self.log("stage4: best \(String(format: "%.3f", decision.best)) accepted=\(decision.accepted)")
        guard decision.accepted, let idx = decision.bestIndex else { return .miss }

        let box = ranked[idx].bboxPx
        let healed = decision.best >= tuning.selfHealMinConfidence
            ? DescriptorAssembler.healed(d, foundRectPx: box, currentWindowPx: currentPx, now: LocatorTime.now()) : nil
        debugDump?.record(descriptor: d, stage: "stage4-segmentationScore",
                          window: captured.image, foundRectImagePx: box, confidence: decision.best)
        return .hit(rectImagePx: box, rectScreenPt: ctx.imagePxToAXGlobal(box), confidence: decision.best, healed: healed)
    }

    // MARK: Helpers (main-actor AX; return only Sendable data)

    /// Resolve + capture the current window ONCE per relocate, shared across stages. The capture is a
    /// frame instant; since the UI can't change mid-relocate, every stage matching against the same
    /// frame is byte-identical to re-capturing per stage — just without the redundant AX-enumerate +
    /// ScreenCaptureKit cost (a fall-through used to capture up to 4×).
    private func frame(_ d: Descriptor) async -> (captured: CapturedWindow, ctx: WindowCoordinateContext, win: WindowRef)? {
        if frameCache.attempted { return frameCache.resolved }
        frameCache.attempted = true
        guard let win = await currentWindow(d) else { return nil }
        Self.log("frame: capturing window \(win.frame)")
        guard let captured = try? await captureService.captureMatchingWindow(
            bundleID: win.bundleID, title: win.title, axWindowFrameGlobalPt: win.frame) else { Self.log("frame: capture failed/no match"); return nil }
        let scale = win.frame.width > 0 ? captured.pixelSize.width / win.frame.width : 2
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: win.frame.origin, backingScale: scale, imagePixelSize: captured.pixelSize)
        let r = (captured, ctx, win)
        frameCache.resolved = r
        return r
    }

    /// Full-window OCR computed at most ONCE per relocate (lazy — stages 1/2 never call it). NOTE: the
    /// stage-2/3a look-alike guard deliberately does its OWN small-REGION OCR, not this, so digit
    /// identity stays precise.
    private func fullWindowOCR(_ captured: CapturedWindow, _ ctx: WindowCoordinateContext) -> [(text: String, box: CGRect)] {
        if let r = frameCache.ocrRuns { return r }
        let r = ocr.recognizeText(in: captured.image, ctx: ctx, accurate: true).map { (text: $0.text, box: $0.boxImagePx) }
        frameCache.ocrRuns = r
        return r
    }

    private func currentWindow(_ d: Descriptor) async -> WindowRef? {
        await MainActor.run { () -> WindowRef? in
            guard let pid = Self.pid(forBundleID: d.app.bundleID) else { Self.log("currentWindow: no pid"); return nil }
            let appEl = ax.reader.applicationElement(pid: pid)
            ax.reader.setMessagingTimeout(appEl, seconds: 2)
            Self.log("currentWindow: reading app windows")
            let windows = ax.reader.windows(of: appEl)
            Self.log("currentWindow: \(windows.count) windows")
            // Pick the window matching the descriptor. Among title-matches (or all windows if none match —
            // a dialog/sheet's AX title rarely matches the recorded pattern), choose the one whose SIZE is
            // closest to `windowSizeAtCapture`. This disambiguates a multi-window app (Premiere main window
            // vs. a much-smaller AAF Export dialog) — title-only fell back to `windows.first` = the main
            // window, so a dialog element was sought in the wrong window.
            let regex = try? NSRegularExpression(pattern: d.app.windowTitlePattern)
            let titleMatches = windows.filter { w in
                guard let t = ax.reader.title(w) else { return false }
                return regex?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            }
            let pool = titleMatches.isEmpty ? windows : titleMatches
            let target = d.app.windowSizeAtCapture
            let scored = pool.map { w -> (AXUIElement, CGFloat) in
                let dist = ax.reader.frame(w).map { abs($0.width - target.width) + abs($0.height - target.height) } ?? .greatestFiniteMagnitude
                return (w, dist)
            }
            let chosen = scored.min(by: { $0.1 < $1.1 })?.0 ?? windows.first
            guard let chosen, let frame = ax.reader.frame(chosen) else { return nil }
            Self.log("currentWindow: chose \(Int(frame.width))×\(Int(frame.height)) (recorded \(Int(target.width))×\(Int(target.height)))")
            return WindowRef(bundleID: d.app.bundleID, title: ax.reader.title(chosen), frame: frame)
        }
    }

    @MainActor
    private static func pid(forBundleID id: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
    }

    /// Stage diagnostics to stderr, gated behind `LOCATOR_DEBUG` so normal runs emit only the JSON.
    static func log(_ s: String) {
        guard ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[relocate] \(s)\n".utf8))
    }
}

/// Persists self-heal updates to the store (which keeps a rollback history).
public struct StoreHealer: DescriptorHealing {
    let store: DescriptorStore
    public init(store: DescriptorStore) { self.store = store }
    public func heal(_ updated: Descriptor) { try? store.save(updated) }
}
