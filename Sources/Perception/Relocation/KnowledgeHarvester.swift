import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

/// Harvests ALL objects in a window into `ObservedObject`s for the knowledge base. AX-FIRST: one bounded
/// tree walk materializes every text-bearing or actionable leaf cheaply (no crops). For OPAQUE or AX-thin
/// windows (Pro Tools/Blender canvas) it augments with a full-window OCR pass — reusing the exact capture +
/// OCR the relocate/scroll engine already uses. @MainActor (AX + capture are MainActor-isolated).
public struct KnowledgeHarvester: Sendable {
    let ax: AXEngine
    let capture: WindowCaptureService
    let ocr: OCREngine
    let segmenter: ConnectedComponentSegmenter
    /// THE PRODUCTION PARSER. When present, every CV harvest goes through `SceneBuilder.detectLayers` —
    /// the same pass `describe_scene` reads: content suppression, image surfaces, icon+caption grouping,
    /// toggle states, the false-group rules. Until 2026-09-06 the harvester ran its OWN raw OCR + segmenter
    /// and kept any segment without a text centre, which is how the knowledge base filled with 3,000
    /// photo fragments from web pages while the agent's scene saw none of them. nil = the raw fallback
    /// (tests, or a process without the icon/knowledge stores).
    let builder: SceneBuilder?

    public init(ax: AXEngine, capture: WindowCaptureService = WindowCaptureService(),
                ocr: OCREngine = OCREngine(), segmenter: ConnectedComponentSegmenter = .init(),
                builder: SceneBuilder? = nil) {
        self.ax = ax; self.capture = capture; self.ocr = ocr; self.segmenter = segmenter; self.builder = builder
    }

    /// The harvester every live command should use: wired to the production parser with the real stores.
    public static func production(ax: AXEngine, capture: WindowCaptureService = WindowCaptureService()) -> KnowledgeHarvester {
        let builder: SceneBuilder? = {
            guard let idir = try? DescriptorPaths.iconsDir(), let kdir = try? DescriptorPaths.knowledgeDir() else { return nil }
            return SceneBuilder(capture: capture, icons: IconStore(directory: idir), knowledge: KnowledgeStore(directory: kdir), learns: false)
        }()
        return KnowledgeHarvester(ax: ax, capture: capture, builder: builder)
    }

    /// Production perception → knowledge objects. Text runs become text objects; a CONTROL (icon + its
    /// caption, a switch + its label) is ONE object named by its label; an unlabeled icon is a
    /// position-keyed object; image surfaces and overlay candidates are not objects at all.
    static func objects(from elements: [ElementGrouper.Grouped], windowPixelSize: CGSize, now: Date) -> [ObservedObject] {
        guard windowPixelSize.width > 0, windowPixelSize.height > 0 else { return [] }
        return elements.compactMap { e in
            guard e.kind == "text" || e.kind == "icon" || e.kind == "control", e.rect.width > 0, e.rect.height > 0 else { return nil }
            let b = e.rect
            let bounds = [Double(b.minX / windowPixelSize.width), Double(b.minY / windowPixelSize.height),
                          Double(b.width / windowPixelSize.width), Double(b.height / windowPixelSize.height)]
            let text = e.unlabeled == true ? nil : e.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (text?.isEmpty == false) ? text : nil
            if e.kind == "text", label == nil { return nil }
            let key = ObservedObject.makeIdentityKey(role: nil, identifier: nil, text: label, boundsNormalized: bounds)
            return ObservedObject(identityKey: key, selfText: label, role: nil, source: .cv,
                                  boundsNormalized: bounds, firstSeen: now, lastSeen: now)
        }
    }

    /// One CV pass over a captured window: the production parser when wired, the raw fallback otherwise.
    func cvObjects(in img: CGImage, bundleID: String, ctx: WindowCoordinateContext, pixelSize: CGSize, now: Date) -> [ObservedObject] {
        if let builder {
            let layers = builder.detectLayers(in: img, appIcons: builder.icons.load(bundleID: bundleID))
            return Self.objects(from: layers.elements, windowPixelSize: pixelSize, now: now)
        }
        let ocrRuns = ocr.recognizeText(in: img, ctx: ctx, accurate: true)
        var objects: [ObservedObject] = ocrRuns.compactMap { Self.objectFromOCR($0, windowPixelSize: pixelSize, now: now) }
        let ocrBoxes = ocrRuns.map(\.boxImagePx)
        for seg in segmenter.segment(in: img, region: nil) {
            if ocrBoxes.contains(where: { seg.bboxPx.contains(CGPoint(x: $0.midX, y: $0.midY)) }) { continue }
            if let o = Self.objectFromSegment(seg.bboxPx, windowPixelSize: pixelSize, now: now) { objects.append(o) }
        }
        return objects
    }

    public struct Harvest: Sendable {
        public let bundleID: String
        public let windowTitle: String
        public let objects: [ObservedObject]
        public let usedOCR: Bool
        public let fingerprint: StateFingerprint
    }

    /// AX roles worth recording even when they carry no text (icon buttons, disclosure triangles, …).
    static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXLink", "AXTab", "AXSlider", "AXRow", "AXCell",
        "AXStaticText", "AXDisclosureTriangle", "AXImage",
    ]

    /// Text-INPUT roles whose AX `value` is USER-ENTERED CONTENT, not a label — never captured (this also
    /// covers password fields: `AXSecureTextField` is a subrole of `AXTextField`). We still record the
    /// control itself (it's in `actionableRoles`) with its title/description label, just never its value.
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The display TEXT for a leaf — but NEVER a text-input control's typed value. For an input role the
    /// AX `value` is content the user entered (incl. secure-field text), so keep only title/description
    /// (the field's label/placeholder); every other role keeps `value`, where it IS the displayed label
    /// (AXStaticText, steppers, value indicators). Pure → unit-tested.
    static func leafText(role: String?, title: String?, description: String?, value: String?) -> String? {
        let usable = (role.map(textInputRoles.contains) == true) ? [title, description] : [title, description, value]
        return usable.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// AX window facts that can safely cross actor boundaries (no live AXUIElement / SCWindow).
    private struct WindowFacts: Sendable { let bundle: String; let title: String; let frame: CGRect; let objects: [ObservedObject] }

    /// Observe the frontmost window of `bundleID` (or the frontmost app when nil). Returns nil if there is
    /// no usable window. NONISOLATED on purpose: the AX walk hops to the main actor (AXEngine is
    /// @MainActor), but the capture + OCR run OFF it — `WindowCaptureService`/`WindowEnumerator` are
    /// explicitly "never call from the main actor" (non-Sendable SCWindow), and doing so leaks the SCK
    /// continuation. So we gather Sendable AX facts on the main actor, then capture in this async domain.
    public func harvestFrontmost(bundleID: String?, now: Date, minAXTextLeaves: Int = 6) async -> Harvest? {
        let factsOpt: WindowFacts? = await MainActor.run { () -> WindowFacts? in
            guard let app = Self.resolveApp(bundleID: bundleID) else { return nil }
            let bundle = app.bundleIdentifier ?? bundleID ?? ""
            let appEl = ax.reader.applicationElement(pid: app.processIdentifier)
            ax.reader.setMessagingTimeout(appEl, seconds: 2)
            guard let win = ax.reader.windows(of: appEl).first,
                  let winFrame = ax.frameGlobalPt(win), winFrame.width > 1, winFrame.height > 1 else { return nil }
            return WindowFacts(bundle: bundle, title: ax.title(win) ?? "", frame: winFrame,
                               objects: walk(window: win, windowFrame: winFrame, now: now))
        }
        guard let facts = factsOpt else { return nil }

        // ALWAYS augment with OCR (off the main actor). AX gives the chrome (buttons/menus/transport) but
        // for opaque-content apps (Pro Tools track list, Blender canvas) the VALUABLE content is painted
        // pixels AX can't see — and the chrome alone clears `minAXTextLeaves`, so a thin-AX gate would never
        // OCR the canvas. CV objects merge alongside AX ones (dedup prefers AX for an identical key).
        // [P2: spatial AX/CV dedup.]
        var objects = facts.objects
        var usedOCR = false
        _ = minAXTextLeaves
        if let cap = try? await capture.captureMatchingWindow(bundleID: facts.bundle, title: facts.title, axWindowFrameGlobalPt: facts.frame) {
            let scale = facts.frame.width > 0 ? cap.pixelSize.width / facts.frame.width : 2
            let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: facts.frame.origin, backingScale: scale, imagePixelSize: cap.pixelSize)
            objects += cvObjects(in: cap.image, bundleID: facts.bundle, ctx: ctx, pixelSize: cap.pixelSize, now: now)
            usedOCR = true
        }
        let deduped = Self.dedup(objects)
        return Harvest(bundleID: facts.bundle, windowTitle: facts.title, objects: deduped, usedOCR: usedOCR,
                       fingerprint: StateFingerprint.make(title: facts.title, objects: deduped))
    }

    /// One element observed by HOVERING the cursor over it (the ambient watcher). Sendable → crosses actors.
    public struct HoverObservation: Sendable {
        public let bundleID: String
        public let windowTitle: String
        public let object: ObservedObject
    }

    /// Resolve the element under a global (top-left) point into a STRUCTURE-ONLY `ObservedObject` — role +
    /// label + normalized bounds + the hovered cursor affordance, NEVER a text-input control's typed value
    /// (see `leafText`). @MainActor, AX-only (no capture/OCR/synthetic events). Returns nil if there's no
    /// element, no containing window, the element falls outside the window, or it's an unlabelled container.
    /// `affordance` is sampled by the caller at the same instant (cursor shape is AppKit). This is how the
    /// KB builds itself from the user's mouse movement, one hovered element at a time.
    @MainActor
    public func hoverObject(at globalPoint: CGPoint, affordance: CursorAffordance?, now: Date) -> HoverObservation? {
        guard let el = ax.hitTest(globalPoint: globalPoint),
              let win = ax.window(of: el), let winFrame = ax.frameGlobalPt(win),
              winFrame.width > 1, winFrame.height > 1,
              let pid = ax.pid(of: el),
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        let role = ax.role(el)
        let label = Self.leafText(role: role, title: ax.title(el), description: ax.descriptionText(el), value: ax.value(el))
        let actionable = role.map(Self.actionableRoles.contains) ?? false
        guard label != nil || actionable else { return nil }   // skip bare container groups (no identity)
        guard let elFrame = ax.frameGlobalPt(el), elFrame.width > 0, elFrame.height > 0,
              let bounds = Self.normalize(elFrame, in: winFrame) else { return nil }
        let key = ObservedObject.makeIdentityKey(role: role, identifier: ax.identifier(el), text: label, boundsNormalized: bounds)
        let obj = ObservedObject(identityKey: key, selfText: label, role: role, source: .ax,
                                 boundsNormalized: bounds, affordance: affordance, firstSeen: now, lastSeen: now)
        return HoverObservation(bundleID: bundle, windowTitle: ax.title(win) ?? "", object: obj)
    }

    /// A CV-first snapshot of the window under the cursor: ALL OCR objects + the window frame. Sendable.
    public struct CVHarvest: Sendable {
        public let bundleID: String
        public let title: String
        public let frameGlobalPt: CGRect
        public let objects: [ObservedObject]
    }

    /// CV-FIRST capture of the window under `globalPoint` with NO AX: resolve + capture the window from
    /// pixels (the zero-AX path), then OCR it into `ObservedObject`s. This is the primary ambient signal —
    /// it works on apps that expose no Accessibility (Premiere, Pro Tools canvas, Electron). Nonisolated:
    /// the capture must run OFF the main actor (non-Sendable SCWindow leaks the SCK continuation). The
    /// watcher caches the result per window-state so this is paid only on ENTERING a new state, not per hover.
    public func cvWindowUnderCursor(at globalPoint: CGPoint, preferringPID: pid_t?, now: Date) async -> CVHarvest? {
        guard let pw = try? await capture.captureWindow(underPoint: globalPoint, preferringPID: preferringPID) else { return nil }
        let img = pw.captured.image, pixelSize = pw.captured.pixelSize, frame = pw.captured.frameGlobalPt
        let scale = frame.width > 0 ? pixelSize.width / frame.width : 2
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: frame.origin, backingScale: scale, imagePixelSize: pixelSize)
        // The production parser (icons WITH their captions as one control, photos suppressed, states read)
        // — or, without stores, the raw OCR + segmenter fallback. This is what lets hovering an ICON register.
        let objects = cvObjects(in: img, bundleID: pw.bundleID, ctx: ctx, pixelSize: pixelSize, now: now)
        return CVHarvest(bundleID: pw.bundleID, title: pw.captured.title ?? "", frameGlobalPt: frame, objects: Self.dedup(objects))
    }

    /// Is a segment an ICON (not text)? Drops very elongated boxes (text lines / dividers, > 4:1) and any box
    /// meaningfully overlapping an OCR text box (≥25% of the smaller box). Shared by `peek --collect` + `scene`.
    /// Is this segment plausibly an ICON (not a text run, not a sliver)? Two rejections:
    /// aspect ratio beyond `aspectMax`, and overlap with an OCR box beyond `textOverlapMax` of the smaller
    /// area (i.e. "this box IS the text"). Both are exposed as parameters so `locator eval` can sweep them
    /// against the human annotations — the defaults are the long-standing shipped values, so callers that
    /// omit them behave exactly as before.
    /// `textOverlapMax` stays 0.9 — MEASURED, 2026-09-05: 0.6 looked right by eye (a word's dilated segment
    /// scores 0.7–0.85 and wore an "icon" box on DaVinci's sidebar), but the annotated benchmark dropped
    /// Keynote 261→221 and Resolve 738→703 with EVERY other rule held constant, and restoring 0.9 alone
    /// recovered 257/735. The reason: a compact LABELLED BUTTON (a tab, a sidebar row, a format button) is
    /// geometrically the same box-around-text as a word. Pixels cannot tell them apart; only the annotation
    /// says the box is clickable — so the box stays, and the benchmark is the judge, not the eye.
    public static func isLikelyIcon(_ seg: CGRect, ocrBoxes: [CGRect],
                                    aspectMax: CGFloat = 4, textOverlapMax: CGFloat = 0.9) -> Bool {
        let longSide = max(seg.width, seg.height), shortSide = max(1, min(seg.width, seg.height))
        if longSide / shortSide > aspectMax { return false }
        let segArea = seg.width * seg.height
        for o in ocrBoxes {
            let inter = seg.intersection(o)
            guard !inter.isNull else { continue }
            // Reject only when the overlap covers most of the SEGMENT — i.e. the segment IS the text run.
            // The old denominator was min(segArea, ocrArea), which meant a text FIELD or a labelled BUTTON
            // that fully CONTAINS its text scored 1.0 and was always discarded; no threshold value could
            // rescue it (you would need >1.0). Dividing by the segment's own area separates
            // "segment ≈ text" (reject) from "segment contains text" (keep).
            if segArea > 0, (inter.width * inter.height) / segArea > textOverlapMax { return false }
        }
        return true
    }

    /// A text-less ObservedObject from a segmenter box (an icon/graphic) — position-keyed (no text), so the
    /// same icon-slot dedups across captures via the coarse 10×10 bucket in `makeIdentityKey`.
    static func objectFromSegment(_ box: CGRect, windowPixelSize: CGSize, now: Date) -> ObservedObject? {
        guard windowPixelSize.width > 0, windowPixelSize.height > 0, box.width > 0, box.height > 0 else { return nil }
        let bounds = [Double(box.minX / windowPixelSize.width), Double(box.minY / windowPixelSize.height),
                      Double(box.width / windowPixelSize.width), Double(box.height / windowPixelSize.height)]
        let key = ObservedObject.makeIdentityKey(role: nil, identifier: nil, text: nil, boundsNormalized: bounds)
        return ObservedObject(identityKey: key, selfText: nil, role: nil, source: .cv, boundsNormalized: bounds, firstSeen: now, lastSeen: now)
    }

    /// Pure: the smallest observed object whose normalized bounds contain the cursor — mapping the cursor's
    /// global (top-left) point into the window via its frame. `pad` (window-fraction) inflates each box so a
    /// hover a few px off a TIGHT OCR text box still registers; smallest match wins. nil = honest miss (no
    /// false attribution). The "which element am I hovering?" attribution.
    public static func objectUnderCursor(_ objects: [ObservedObject], windowFrameGlobalPt w: CGRect,
                                         cursorGlobalPt c: CGPoint, pad: Double = 0) -> ObservedObject? {
        guard w.width > 0, w.height > 0 else { return nil }
        let p = CGPoint(x: (c.x - w.minX) / w.width, y: (c.y - w.minY) / w.height)
        return objects.filter { $0.boundsRect.insetBy(dx: -pad, dy: -pad).contains(p) }
            .min { ($0.boundsRect.width * $0.boundsRect.height) < ($1.boundsRect.width * $1.boundsRect.height) }
    }

    /// Bounded DFS over the window's AX subtree, collecting text-bearing / actionable leaves as objects.
    @MainActor
    private func walk(window: AXUIElement, windowFrame: CGRect, now: Date,
                      maxVisited: Int = 1500, maxDepth: Int = 50) -> [ObservedObject] {
        var out: [ObservedObject] = []
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (el, depth) = stack.popLast() {
            if visited >= maxVisited { break }
            visited += 1
            if depth < maxDepth { for c in ax.reader.children(el) { stack.append((c, depth + 1)) } }
            if ax.reader.isEqual(el, window) { continue }   // skip the window container itself

            let role = ax.role(el)
            let text = Self.leafText(role: role, title: ax.title(el), description: ax.descriptionText(el), value: ax.value(el))
            let actionable = role.map(Self.actionableRoles.contains) ?? false
            guard text != nil || actionable else { continue }
            guard let frame = ax.frameGlobalPt(el), frame.width > 0, frame.height > 0,
                  let bounds = Self.normalize(frame, in: windowFrame) else { continue }
            let key = ObservedObject.makeIdentityKey(role: role, identifier: ax.identifier(el), text: text, boundsNormalized: bounds)
            out.append(ObservedObject(identityKey: key, selfText: text, role: role, source: .ax,
                                      boundsNormalized: bounds, firstSeen: now, lastSeen: now))
        }
        return out
    }

    // MARK: Pure helpers (testable)

    /// Window-normalized [x,y,w,h] for an element's global-point frame, or nil if it falls well outside the
    /// window (a popover/menu drawn beyond the window bounds is not part of this window's inventory).
    static func normalize(_ frame: CGRect, in window: CGRect) -> [Double]? {
        guard window.width > 0, window.height > 0 else { return nil }
        let x = (frame.minX - window.minX) / window.width
        let y = (frame.minY - window.minY) / window.height
        let w = frame.width / window.width
        let h = frame.height / window.height
        guard x > -0.5, x < 1.5, y > -0.5, y < 1.5, w > 0, w <= 2, h > 0, h <= 2 else { return nil }
        return [Double(x), Double(y), Double(w), Double(h)]
    }

    static func objectFromOCR(_ run: OCRResult, windowPixelSize: CGSize, now: Date) -> ObservedObject? {
        let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, windowPixelSize.width > 0, windowPixelSize.height > 0 else { return nil }
        let b = run.boxImagePx
        let bounds = [Double(b.minX / windowPixelSize.width), Double(b.minY / windowPixelSize.height),
                      Double(b.width / windowPixelSize.width), Double(b.height / windowPixelSize.height)]
        let key = ObservedObject.makeIdentityKey(role: nil, identifier: nil, text: text, boundsNormalized: bounds)
        return ObservedObject(identityKey: key, selfText: text, role: nil, source: .cv,
                              boundsNormalized: bounds, firstSeen: now, lastSeen: now)
    }

    /// Drop duplicate identityKeys within a single harvest, preferring an AX object over a CV one for the
    /// same key (AX is higher-trust / structured).
    static func dedup(_ objects: [ObservedObject]) -> [ObservedObject] {
        var byKey: [String: ObservedObject] = [:]
        for o in objects {
            if let existing = byKey[o.identityKey] {
                if existing.source == .cv, o.source == .ax { byKey[o.identityKey] = o }
            } else { byKey[o.identityKey] = o }
        }
        return byKey.values.sorted { $0.identityKey < $1.identityKey }
    }

    @MainActor
    public static func resolveApp(bundleID: String?) -> NSRunningApplication? {
        if let b = bundleID { return NSRunningApplication.runningApplications(withBundleIdentifier: b).first }
        return NSWorkspace.shared.frontmostApplication
    }
}
