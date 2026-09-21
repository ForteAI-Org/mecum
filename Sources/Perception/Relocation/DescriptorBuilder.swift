import Foundation
import CoreGraphics
import AppKit
import AXSupport
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

public enum BuilderError: Error, CustomStringConvertible {
    case noElementUnderPoint
    case noWindow
    case noOwningApp
    case captureFailed
    case elementOutsideWindowImage
    case cropFailed

    public var description: String {
        switch self {
        case .noElementUnderPoint: return "No AX element under the point."
        case .noWindow: return "Could not resolve the AX window."
        case .noOwningApp: return "Could not resolve the owning application."
        case .captureFailed: return "Window capture failed (Screen Recording granted?)."
        case .elementOutsideWindowImage: return "Element frame fell outside the captured window image."
        case .cropFailed: return "Failed to crop the element region."
        }
    }
}

/// Pick → persist. Hit-tests a global point, captures the window, and assembles the redundant
/// descriptor (AX path when available + visual crops + edge hash + text + geometry), then saves it.
/// `@MainActor` for the AX calls; the capture hop is async and returns only `Sendable` data.
@MainActor
public struct DescriptorBuilder {
    let ax: AXEngine
    let captureService: WindowCaptureService
    let ocr: OCREngine
    let hasher: SobelPerceptualHasher
    let segmenter: ConnectedComponentSegmenter
    let store: DescriptorStore
    let crops: CropStore
    let tuning: RelocationTuning

    public init(store: DescriptorStore, crops: CropStore,
                ax: AXEngine = AXEngine(), captureService: WindowCaptureService = WindowCaptureService(),
                ocr: OCREngine = OCREngine(), hasher: SobelPerceptualHasher = SobelPerceptualHasher(),
                segmenter: ConnectedComponentSegmenter = ConnectedComponentSegmenter(), tuning: RelocationTuning = .defaults) {
        self.store = store
        self.crops = crops
        self.ax = ax
        self.captureService = captureService
        self.ocr = ocr
        self.hasher = hasher
        self.segmenter = segmenter
        self.tuning = tuning
    }

    public func build(atGlobalPoint point: CGPoint, name: String? = nil) async throws -> Descriptor {
        // Window facts come from AX when an element exists under the point; otherwise PURELY from pixels via
        // ScreenCaptureKit — zero-AX apps (Premiere, some Adobe/Electron) expose no AX in their content
        // panels. The CV cascade relocates either kind; AX is just the fast lane when present.
        let hit = ax.hitTest(globalPoint: point)
        let windowFrame: CGRect, bundleID: String, windowTitle: String?, opaque: Bool, captured: CapturedWindow
        if let hit {
            // Resolve the window directly (kAXWindowAttribute); fall back to scanning the ancestor chain
            // for any AXWindow (not just the top hop) so floating panels / deep trees don't defeat it.
            guard let window = ax.window(of: hit) ?? ax.walkAncestors(hit).last(where: { ax.role($0) == "AXWindow" }),
                  let wf = ax.frameGlobalPt(window) else { throw BuilderError.noWindow }
            guard let pid = ax.pid(of: hit),
                  let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { throw BuilderError.noOwningApp }
            windowFrame = wf; bundleID = bid; windowTitle = ax.title(window)
            opaque = ax.isOpaqueGroup(hit, windowFrame: wf)   // opaque GPU canvas → CV path (ax.available = false)
            guard let cap = try await captureService.captureMatchingWindow(
                bundleID: bid, title: windowTitle, axWindowFrameGlobalPt: wf) else { throw BuilderError.captureFailed }
            captured = cap
        } else {
            // No AX element here → resolve + capture the window under the cursor from pixels alone (opaque),
            // preferring the FRONTMOST app so an overlapping window of another app (Slack/Cap behind the
            // target) can't be grabbed instead.
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let pw = try await captureService.captureWindow(underPoint: point, preferringPID: frontPID) else { throw BuilderError.noElementUnderPoint }
            captured = pw.captured; windowFrame = pw.captured.frameGlobalPt
            bundleID = pw.bundleID; windowTitle = pw.captured.title; opaque = true
        }

        let image = captured.image
        let scale = windowFrame.width > 0 ? CGFloat(image.width) / windowFrame.width : 2
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: windowFrame.origin, backingScale: scale,
                                          imagePixelSize: CGSize(width: image.width, height: image.height))

        // Refine the element box with CV: segment the click neighborhood, take the smallest box
        // containing the click. Prefer it over a coarse/opaque AX element (precision); when CV wins,
        // drop the AX path (it pointed at the wrong granularity → ax.available = false).
        // Clamp into the image: a window that moved between the AX frame read and the capture would
        // otherwise put the click (and its neighborhood) off-image and turn a soft miss into a throw.
        let rawClick = ctx.axGlobalToImagePx(point)
        let clickPx = CGPoint(x: min(max(rawClick.x, 0), CGFloat(image.width)),
                              y: min(max(rawClick.y, 0), CGFloat(image.height)))
        let axElementPx: CGRect? = hit.flatMap { ax.frameGlobalPt($0) }.map { ctx.axGlobalToImagePx($0).integral.intersection(imageRect) }
        let half = tuning.captureNeighborhoodPx / 2
        let neighborhood = CGRect(x: clickPx.x - half, y: clickPx.y - half, width: tuning.captureNeighborhoodPx, height: tuning.captureNeighborhoodPx)
        let cvBox = segmenter.segment(in: image, region: neighborhood)
            .filter { $0.bboxPx.contains(clickPx) }
            .min { $0.bboxPx.width * $0.bboxPx.height < $1.bboxPx.width * $1.bboxPx.height }?
            .bboxPx

        // OCR the whole window once at capture, ACCURATE level (recall uses the same): the stored text is
        // the identity anchor, and near-identical labels are only distinguishable if the digit is read
        // cleanly. Reused for self-text, neighbors, and the element-box alignment below.
        let ocrResults = ocr.recognizeText(in: image, ctx: ctx, accurate: true)
        let ocrRuns = ocrResults.map { (text: $0.text, box: $0.boxImagePx) }

        let chosen = Self.chooseElementBox(clickPx: clickPx, axElementPx: axElementPx, cvBox: cvBox,
                                           opaque: opaque, imageRect: imageRect, tuning: tuning)
        let axAvailable = chosen.keepAX
        // Align a CV/fallback FRAGMENT up to the full text run it sits inside ("2048" → "3072 x 2048
        // VistaVision", "Master" → "Master Settings"), so the crop/template is the whole label and the
        // stored self-text matches the crop. No-op when a precise AX leaf was kept.
        let elementPx = Self.textAlignedBox(fragment: chosen.box, keepAX: axAvailable,
                                            ocrRuns: ocrRuns, imageRect: imageRect, tuning: tuning)
        guard !elementPx.isNull, elementPx.width >= 1, elementPx.height >= 1 else { throw BuilderError.elementOutsideWindowImage }
        guard let elementCrop = image.cropping(to: elementPx) else { throw BuilderError.cropFailed }

        let elementFrame = ctx.imagePxToAXGlobal(elementPx)   // (refined) element frame in global points

        let id = UUID()
        let margin: CGFloat = 60
        let contextPx = elementPx.insetBy(dx: -margin, dy: -margin).integral.intersection(imageRect)
        let contextCrop = image.cropping(to: contextPx) ?? elementCrop

        let cropName = CropStore.cropName(id: id)
        let contextName = CropStore.contextCropName(id: id)
        try crops.writePNG(elementCrop, name: cropName)
        try crops.writePNG(contextCrop, name: contextName)

        // Self-text: trust the AX title/description ONLY when we kept a precise AX leaf. For an opaque
        // (GPU-painted) control the AX hit resolves to a coarse ancestor whose title is the WINDOW title
        // ("Edit: GAME • v4" for every Pro Tools track — useless and identical across controls), so for
        // those derive it from the OCR run that best overlaps the element box instead.
        let selfText = (axAvailable ? hit.flatMap { ax.title($0) ?? ax.descriptionText($0) } : nil)
            ?? ocrResults
                .filter { $0.boxImagePx.intersects(elementPx) }
                .max { overlapArea($0.boxImagePx, elementPx) < overlapArea($1.boxImagePx, elementPx) }?
                .text
        let neighbors = nearestNeighbors(ocrResults, elementPx: elementPx, max: 6)

        let now = LocatorTime.now()
        var appSpecific: [String: String] = [:]
        if let name { appSpecific["name"] = name }

        // Scroll containers (Phase 1): record the AX scroll area(s) enclosing the element + their current
        // fraction, so the continuous relocator can scroll the element back into view at replay. Works
        // for CV elements too — the opaque leaf still has a scrollable AX ancestor (e.g. a chat list).
        var scrollContainers: [ScrollContainerSnapshot] = []
        var scrollState: [String: Double] = [:]
        for container in (hit.map { ax.scrollableAncestors(of: $0) } ?? []).prefix(2) {
            var axes: [ScrollAxis] = []
            var fx = 0.0, fy = 0.0
            if let v = ax.scrollFraction(of: container, axis: .vertical) { axes.append(.vertical); fy = v }
            if let h = ax.scrollFraction(of: container, axis: .horizontal) { axes.append(.horizontal); fx = h }
            guard !axes.isEmpty, let cFrame = ax.visibleContentRect(of: container), windowFrame.width > 0, windowFrame.height > 0 else { continue }
            let cid = "scroll-" + String(ax.capturePath(from: container).map(\.role).joined(separator: ">").suffix(40))
            let boundsNorm = CGRect(x: (cFrame.minX - windowFrame.minX) / windowFrame.width,
                                    y: (cFrame.minY - windowFrame.minY) / windowFrame.height,
                                    width: cFrame.width / windowFrame.width, height: cFrame.height / windowFrame.height)
            scrollContainers.append(ScrollContainerSnapshot(
                id: cid, axPath: ax.capturePath(from: container), axes: axes,
                boundsNormalized: boundsNorm, scrollFractionAtCapture: CGPoint(x: fx, y: fy)))
            scrollState[cid] = fy
        }
        var geometry = DescriptorAssembler.geometry(elementGlobalPt: elementFrame, windowGlobalPt: windowFrame, backingScale: scale)
        if !scrollContainers.isEmpty {
            geometry.scrollContainersAtCapture = scrollContainers
            geometry.scrollStateAtCapture = scrollState
        } else if !axAvailable {
            // No AX scroll area AND the element is CV-relocated (no usable AX leaf — e.g. a Pro Tools
            // track row): record a CV-only scroll region so the continuous relocator can scroll it
            // synthetically at replay — the tightest opaque ancestor that contains the element and is
            // smaller than the window, else the whole window content area.
            let elemCenter = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
            let windowArea = windowFrame.width * windowFrame.height
            let region = (hit.map { ax.walkAncestors($0) } ?? []).dropFirst().compactMap { a -> CGRect? in
                guard ax.isOpaqueGroup(a, windowFrame: windowFrame), let f = ax.frameGlobalPt(a),
                      f.contains(elemCenter), f.width * f.height < windowArea * 0.95 else { return nil }
                return f
            }.min { $0.width * $0.height < $1.width * $1.height } ?? windowFrame
            if windowFrame.width > 0, windowFrame.height > 0 {
                let boundsNorm = CGRect(x: (region.minX - windowFrame.minX) / windowFrame.width,
                                        y: (region.minY - windowFrame.minY) / windowFrame.height,
                                        width: region.width / windowFrame.width, height: region.height / windowFrame.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let regionPx = CGRect(x: boundsNorm.minX * CGFloat(image.width), y: boundsNorm.minY * CGFloat(image.height),
                                      width: boundsNorm.width * CGFloat(image.width), height: boundsNorm.height * CGFloat(image.height))
                    .integral.intersection(imageRect)
                if !regionPx.isNull, let regionCrop = image.cropping(to: regionPx) {
                    geometry.scrollContainersAtCapture = [ScrollContainerSnapshot(
                        id: "opaque-scroll", axPath: nil, axes: [.vertical], boundsNormalized: boundsNorm,
                        scrollFractionAtCapture: .zero, regionFingerprint: hasher.edgeHash(of: regionCrop),
                        ocrTextsAtCapture: ocrResults.filter { $0.boxImagePx.intersects(regionPx) }.map(\.text))]
                }
            }
        } else if windowFrame.width > 0, windowFrame.height > 0, elementFrame.width > 0, elementFrame.height > 0 {
            // AX leaf present, but NO AX scroll area was found (scrollableAncestors empty). Apps like Slack /
            // Electron expose an AX element under the cursor yet no settable AXScrollArea, so previously these
            // recorded NO scroll container — the relocator then saw "hasContainer=false" and could NEVER
            // scroll-search the element back into view (a missed step just halted the flow). Record a CV-only
            // opaque scroll region ANCHORED ON THE CLICK (the scrollable content is where the user clicked);
            // the opaque driver delivers the synthetic wheel at that click point (OpaqueScrollDriver.
            // deliveryPoint). axPath = nil ⇒ the composite driver routes it to the synthetic-wheel path.
            let boundsNorm = DescriptorAssembler.clickAnchoredRegionNorm(elementGlobalPt: elementFrame, windowGlobalPt: windowFrame)
            let regionPx = CGRect(x: boundsNorm.minX * CGFloat(image.width), y: boundsNorm.minY * CGFloat(image.height),
                                  width: boundsNorm.width * CGFloat(image.width), height: boundsNorm.height * CGFloat(image.height))
                .integral.intersection(imageRect)
            if !regionPx.isNull, let regionCrop = image.cropping(to: regionPx) {
                geometry.scrollContainersAtCapture = [ScrollContainerSnapshot(
                    id: "opaque-scroll", axPath: nil, axes: [.vertical], boundsNormalized: boundsNorm,
                    scrollFractionAtCapture: .zero, regionFingerprint: hasher.edgeHash(of: regionCrop),
                    ocrTextsAtCapture: ocrResults.filter { $0.boxImagePx.intersects(regionPx) }.map(\.text))]
            }
        }

        // Stateful-control intent: if the clicked element is an AX checkbox/radio, record its kind + current
        // state so replay can set it IDEMPOTENTLY (click only if not already in the desired state). The
        // recorder finalizes desiredState to the POST-action state for ⌘⇧H (mark-and-click). A CV-only
        // (no-AX) toggle gets no AX state here → the CV-state phase fills it.
        let control: ControlIntent? = hit.flatMap { el -> ControlIntent? in
            switch ax.role(el) {
            case "AXCheckBox": return ControlIntent(kind: .checkbox, desiredState: ax.toggleState(el) ?? .unknown)
            case "AXRadioButton": return ControlIntent(kind: .radio, desiredState: ax.toggleState(el) ?? .unknown)
            default: return nil
            }
        }

        let descriptor = Descriptor(
            id: id, version: 1, created: now, lastVerified: now,
            app: AppContext(
                bundleID: bundleID,
                windowTitlePattern: windowTitle.map { NSRegularExpression.escapedPattern(for: $0) } ?? ".*",
                windowSizeAtCapture: windowFrame.size, backingScale: scale),
            ax: AXDescriptor(
                available: axAvailable,
                path: axAvailable ? (hit.map { ax.capturePath(from: $0) } ?? []) : [],
                leafAttrs: axAvailable ? hit.map { ax.leafAttrs(of: $0) } : nil),
            visual: VisualDescriptor(
                cropRef: cropName, cropSize: elementPx.size,
                contextCropRef: contextName, contextMarginPx: margin,
                edgeHash: hasher.edgeHash(of: elementCrop)),
            text: TextDescriptor(selfText: selfText, neighbors: neighbors),
            geometry: geometry,
            appSpecific: appSpecific,
            thresholds: .defaults,
            control: control)

        try store.save(descriptor)
        return descriptor
    }

    /// Choose the element box and whether to keep the AX path. Prefers a precise box (CV when tighter,
    /// AX when comparable so its replay path survives); if NEITHER is precise (only a coarse panel-sized
    /// box, or nothing), falls back to a small click-centered box so the capture is still relocatable.
    /// Pure + unit-tested — this is the reliability-critical decision.
    nonisolated static func chooseElementBox(clickPx: CGPoint, axElementPx: CGRect?, cvBox: CGRect?,
                                             opaque: Bool, imageRect: CGRect, tuning: RelocationTuning) -> (box: CGRect, keepAX: Bool) {
        let windowArea = Double(imageRect.width * imageRect.height)
        func coarse(_ r: CGRect) -> Bool {
            Double(r.width * r.height) > tuning.maxElementAreaFraction * windowArea
                || max(r.width, r.height) > tuning.maxElementSidePx
        }
        let axPrecise = !opaque && (axElementPx.map { !coarse($0) } ?? false)

        if let cv = cvBox, !coarse(cv) {
            // CV is a precise box. Keep AX only if AX is also precise and CV isn't much tighter,
            // so the (fast) AX replay path is preserved for native apps.
            if axPrecise, let ax = axElementPx, Double(cv.width * cv.height) >= 0.5 * Double(ax.width * ax.height) {
                return (ax, true)
            }
            return (cv, false)
        }
        if axPrecise, let ax = axElementPx {
            return (ax, true)
        }
        // Neither precise → small click-centered box (capture the local pixels under the cursor).
        let s = tuning.fallbackBoxPx
        let box = CGRect(x: clickPx.x - s / 2, y: clickPx.y - s / 2, width: s, height: s)
            .integral.intersection(imageRect)
        return (box, false)
    }

    /// Expand a CV/fallback fragment box up to the full OCR text run it lies within, so the crop is the
    /// whole label ("Master Settings", "3072 x 2048 VistaVision") rather than a clipped word, and the
    /// stored self-text matches the crop. Returns `fragment` unchanged when a precise AX leaf was kept,
    /// when no text run contains the fragment's center, or when the only such run is coarse (a merged
    /// panel-width run). Requiring the run to contain the fragment's CENTER is what distinguishes "this
    /// fragment is a piece of this label" from a wide run that merely overlaps the click region.
    nonisolated static func textAlignedBox(fragment: CGRect, keepAX: Bool,
                                           ocrRuns: [(text: String, box: CGRect)],
                                           imageRect: CGRect, tuning: RelocationTuning) -> CGRect {
        guard !keepAX else { return fragment }
        let center = CGPoint(x: fragment.midX, y: fragment.midY)
        let windowArea = Double(imageRect.width * imageRect.height)
        func coarse(_ r: CGRect) -> Bool {
            Double(r.width * r.height) > tuning.maxElementAreaFraction * windowArea
                || max(r.width, r.height) > tuning.maxElementSidePx
        }
        let run = ocrRuns
            .filter { !$0.text.isEmpty && !coarse($0.box) && $0.box.insetBy(dx: -2, dy: -2).contains(center) }
            .min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        guard let run else { return fragment }
        let aligned = run.box.integral.intersection(imageRect)
        return aligned.isNull ? fragment : aligned
    }

    private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Nearest OCR runs that don't overlap the element, with offsets relative to the element origin.
    private func nearestNeighbors(_ results: [OCRResult], elementPx: CGRect, max: Int) -> [TextNeighbor] {
        Self.rowAwareNeighbors(runs: results.map { (text: $0.text, box: $0.boxImagePx) }, elementPx: elementPx, limit: max)
    }

    /// ROW-AWARE neighbor selection (pure → unit-tested). For an element that lives in a LIST ROW (an on/off
    /// toggle, a checkbox), the only RELIABLE anchor is its OWN row's label; adjacent-row labels
    /// (Facebook/Vimeo above & below a TikTok toggle) are decoys that, stored as neighbors, vote for the
    /// WRONG row in `TextConstellation.locateByNeighbors` and smear the cluster. So prefer, in order: the
    /// SAME-ROW left label (the row's name), then a same-row right run (a "⋯" menu — records toggle-vs-menu
    /// geometry), then the section header above (loose tolerance — confirms the section), then fall through
    /// to nearest off-row runs EXACTLY as before (so non-list elements are unaffected).
    nonisolated static func rowAwareNeighbors(runs: [(text: String, box: CGRect)], elementPx: CGRect, limit: Int) -> [TextNeighbor] {
        guard limit > 0 else { return [] }
        let center = CGPoint(x: elementPx.midX, y: elementPx.midY)
        let rowBand = Swift.max(8, elementPx.height * 0.7)
        let indexed = Array(runs.filter { !$0.box.intersects(elementPx) && !$0.text.isEmpty }.enumerated())
        func neighbor(_ r: (text: String, box: CGRect), tol: CGFloat) -> TextNeighbor {
            TextNeighbor(text: r.text, offset: CGPoint(x: r.box.minX - elementPx.minX, y: r.box.minY - elementPx.minY), tolerancePx: tol)
        }
        var picked: [TextNeighbor] = []
        var used = Set<Int>()
        let sameRow = indexed.filter { abs($0.element.box.midY - center.y) <= rowBand }

        // PRIMARY: leftmost real LABEL in this row, to the element's left.
        if let label = sameRow.filter({ $0.element.box.midX < center.x && isRowLabel($0.element.text, box: $0.element.box) })
            .min(by: { $0.element.box.minX < $1.element.box.minX }) {
            picked.append(neighbor(label.element, tol: rowBand)); used.insert(label.offset)
        }
        // SECONDARY: nearest same-row run to the RIGHT (e.g. a "⋯" menu) — records toggle-vs-menu X geometry.
        if let right = sameRow.filter({ $0.element.box.midX > center.x && !used.contains($0.offset) })
            .min(by: { $0.element.box.minX < $1.element.box.minX }) {
            picked.append(neighbor(right.element, tol: rowBand)); used.insert(right.offset)
        }
        // COARSE: nearest section header ABOVE, loose Y tolerance (confirms the SECTION, not precise position).
        if let header = indexed.filter({ $0.element.box.midY < center.y && !used.contains($0.offset) && isSectionHeader($0.element.text) })
            .max(by: { $0.element.box.midY < $1.element.box.midY }) {
            picked.append(neighbor(header.element, tol: abs(header.element.box.midY - center.y) + rowBand)); used.insert(header.offset)
        }
        // FALL-THROUGH: nearest off-row runs (today's behavior) fill the remaining slots.
        if picked.count < limit {
            for r in indexed.filter({ !used.contains($0.offset) })
                .sorted(by: { hypot($0.element.box.midX - center.x, $0.element.box.midY - center.y)
                            < hypot($1.element.box.midX - center.x, $1.element.box.midY - center.y) }) {
                if picked.count >= limit { break }
                picked.append(neighbor(r.element, tol: 12))
            }
        }
        return picked
    }

    /// A real text LABEL, not a 1-char icon glyph / decoration. Drops runs that normalize to empty
    /// (•, ⋯, logos OCR'd as punctuation); a 1-char run is a label only if its box is clearly wide text
    /// (not a square icon glyph). (A genuine single-char label like "X" with a square box is a known weak
    /// case → falls through.)
    nonisolated static func isRowLabel(_ text: String, box: CGRect) -> Bool {
        let n = TextConstellation.normalize(text)
        guard !n.isEmpty else { return false }
        return n.count >= 2 || box.width >= box.height * 1.8
    }

    /// Section-header-like: short and predominantly UPPERCASE letters (PUBLISH / CLOUD).
    nonisolated static func isSectionHeader(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard (2...16).contains(letters.count) else { return false }
        return Double(letters.filter { $0.isUppercase }.count) / Double(letters.count) >= 0.8
    }
}
