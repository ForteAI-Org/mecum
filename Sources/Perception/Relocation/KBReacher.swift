import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

/// Executes a knowledge-base REACH-RECIPE: bring a known-but-off-screen object into view, then return its
/// verified screen point. Phase 2 (scroll reach) reuses the whole shipped engine — it fabricates a minimal
/// TEXT-target descriptor (selfText + a live opaque scroll-container snapshot; no crop, so the cascade
/// safely falls through to the digit-sensitive text-constellation stage) and runs the unchanged
/// `ContinuousScrollRelocator`, which scrolls until the cascade locates the target, re-verifying every step.
/// So the "recipe" is executed and verified, never a blind cached coordinate. (Multi-state navigation —
/// open a menu/panel to reveal a target — is Phase 2b, built on the state-transition graph.)
public struct KBReacher: Sendable {
    let ax: AXEngine
    let crops: CropStore
    let capture: WindowCaptureService
    let ocr: OCREngine
    let hasher: SobelPerceptualHasher

    public init(ax: AXEngine, crops: CropStore, capture: WindowCaptureService = WindowCaptureService(),
                ocr: OCREngine = OCREngine(), hasher: SobelPerceptualHasher = SobelPerceptualHasher()) {
        self.ax = ax; self.crops = crops; self.capture = capture; self.ocr = ocr; self.hasher = hasher
    }

    public struct Reached: Sendable {
        public let found: Bool
        public let method: String
        public let screenPoint: CGPoint?
        /// HOW MUCH OF THE APP THIS HUNT ACTUALLY WALKED. A miss has to be able to say so: a hunt that
        /// stopped on a budget with panes left is not a proof of absence, and a caller with no way to
        /// tell the two apart will report the wrong one (ticket 13).
        public let panesWalked: Int
        public let panesTotal: Int
        public let stoppedEarly: Bool
        public let seconds: Double

        public init(found: Bool, method: String, screenPoint: CGPoint?,
                    panesWalked: Int = 0, panesTotal: Int = 0, stoppedEarly: Bool = false,
                    seconds: Double = 0) {
            self.found = found; self.method = method; self.screenPoint = screenPoint
            self.panesWalked = panesWalked; self.panesTotal = panesTotal
            self.stoppedEarly = stoppedEarly; self.seconds = seconds
        }
    }

    private struct Facts: Sendable { let bundle: String; let title: String; let frame: CGRect }

    /// Line-units per event for the memory-calibrated first jump. Conservative by construction:
    /// aims for ~80% of the estimated distance (undershoot beats overshoot — the target must LAND in
    /// the viewport, not fly past it), floor 1, ceiling 6 (≈2× the old heavy seed; the bisection and
    /// reversal machinery absorb any error). Pure — unit-tested.
    static func calibratedSeedTicks(rowsAway: Int, pitchNorm: Double, windowHpx: Double,
                                    pxPerTick: Double, eventsPerStep: Int) -> Int? {
        guard rowsAway >= 3, pitchNorm > 0, windowHpx > 0, pxPerTick > 0.5, eventsPerStep > 0 else { return nil }
        let desiredPx = Double(rowsAway) * pitchNorm * windowHpx * 0.8
        let ticks = Int((desiredPx / (pxPerTick * Double(eventsPerStep))).rounded())
        return min(6, max(1, ticks))
    }

    /// Ranked scroll-container candidates from the live section cut (pure — unit-tested against the
    /// frozen fixtures' geometry). Tall panels only; SCROLL EVIDENCE FIRST (a pane whose list runs into
    /// its edge is the pane hiding content — Ron's cue), narrow-first among equals (navigation lists
    /// hold the named targets, the wide content pane comes second); capped at 3; the full window is
    /// always the last, legacy-compatible fallback. `ocrBoxesPx` (text rows) feed the evidence — pass
    /// [] to rank on geometry alone. Names are the sections-v2 roles, so reach can say WHICH pane it
    /// scrolled; each candidate carries its evidence so the caller can seed a scroll DIRECTION.
    static func scrollCandidates(sectionRectsPx: [CGRect], imagePixelSize: CGSize,
                                 ocrBoxesPx: [CGRect] = []) -> [(bounds: CGRect, name: String, evidence: ScrollEvidence)] {
        let W = imagePixelSize.width, H = imagePixelSize.height
        var panels: [(rect: CGRect, evidence: ScrollEvidence)] = []
        if W > 0, H > 0 {
            // Panes carry their members so evidence is judged per RUN: a list the section cut sliced
            // into tiles is one viewport, and its invented boundary must not read as truncation (no
            // names on this path — geometry alone decides which tiles belong together).
            let panes = sectionRectsPx.map { r in
                ScrollScout.Pane(rect: r, members: ocrBoxesPx.filter { r.contains(CGPoint(x: $0.midX, y: $0.midY)) })
            }
            panels = panes.enumerated().map { i, p in
                let r = p.rect
                let e = ScrollScout.assess(paneAt: i, in: panes)
                return (CGRect(x: r.minX / W, y: r.minY / H, width: r.width / W, height: r.height / H), e)
            }
            panels = panels.filter { $0.rect.height >= 0.25 && $0.rect.width >= 0.04 && $0.rect.width <= 0.95 }
            panels.sort { a, b in
                if a.evidence.likelyScrollsV != b.evidence.likelyScrollsV { return a.evidence.likelyScrollsV }
                return a.rect.width != b.rect.width ? a.rect.width < b.rect.width : a.rect.height > b.rect.height
            }
        }
        var out: [(bounds: CGRect, name: String, evidence: ScrollEvidence)] = panels.prefix(3).map { p in
            (p.rect, SceneComposer.role(of: p.rect) ?? "panel", p.evidence)
        }
        out.append((CGRect(x: 0, y: 0, width: 1, height: 1), "window", .none))
        return out
    }

    /// Scroll the frontmost window of `bundleID` to bring `targetText` into view. Nonisolated: AX on a
    /// MainActor hop, capture/OCR + the scroll engine OFF the actor (capture must never run on the main
    /// actor — non-Sendable SCWindow).
    /// - `plan`: how much hunting is authorized, from `HuntPolicy.decide` — the caller consults
    ///   accessibility first, because the cheap answer is available before the expensive one runs. The
    ///   default is the unrestricted hunt, so a caller that knows nothing behaves exactly as before.
    public func reach(bundleID: String, targetText: String, now: Date,
                      plan: HuntPolicy.Plan = .unrestricted) async -> Reached? {
        // A plan that authorizes NO hunting must not even capture (that is the whole saving). The MCP
        // reach handler decides this before calling; honoring it here too keeps the contract in one place.
        guard plan.huntsAtAll else {
            return Reached(found: false, method: "hunt-skipped", screenPoint: nil)
        }
        let factsOpt: Facts? = await MainActor.run { () -> Facts? in
            guard let app = KnowledgeHarvester.resolveApp(bundleID: bundleID), let bundle = app.bundleIdentifier else { return nil }
            let appEl = ax.reader.applicationElement(pid: app.processIdentifier)
            ax.reader.setMessagingTimeout(appEl, seconds: 2)
            guard let win = ax.reader.windows(of: appEl).first,
                  let f = ax.frameGlobalPt(win), f.width > 1, f.height > 1 else { return nil }
            return Facts(bundle: bundle, title: ax.title(win) ?? "", frame: f)
        }
        guard let facts = factsOpt else { return nil }

        // Capture once to seed the opaque scroll-container snapshot (fingerprint + visible texts). The
        // engine re-captures as it scrolls; this just gives `beginPlan` its same-pane reference.
        guard let cap = try? await capture.captureMatchingWindow(bundleID: facts.bundle, title: facts.title, axWindowFrameGlobalPt: facts.frame) else {
            return Reached(found: false, method: "capture-failed", screenPoint: nil)
        }
        let scale = facts.frame.width > 0 ? cap.pixelSize.width / facts.frame.width : 2
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: facts.frame.origin, backingScale: scale, imagePixelSize: cap.pixelSize)
        let runs = ocr.recognizeText(in: cap.image, ctx: ctx, accurate: true)
        let W = cap.pixelSize.width, H = cap.pixelSize.height

        // SECTION-ANCHORED containers (sections v2): the window's live panels are the real scroll
        // containers. The old full-window container delivered the wheel at WINDOW CENTER — over Slack
        // that scrolls the message pane while the target sits in the sidebar (measured; Ron's exact
        // complaint). Candidates: tall panels, NARROW FIRST (navigation lists hold the named targets;
        // the wide content pane second), then the full window as the legacy fallback. A non-scrollable
        // candidate stalls out in 2 no-move bursts, so wrong guesses are cheap; every candidate's pass
        // starts with a full-frame locate, so a target revealed by an earlier candidate is found
        // immediately.
        var candidates = Self.scrollCandidates(
            sectionRectsPx: SectionDetector.detect(in: cap.image), imagePixelSize: cap.pixelSize,
            ocrBoxesPx: runs.map(\.boxImagePx))
        // Ranking, lowest to highest precedence (stable sorts, later dominates):
        //   visual evidence (base, from scrollCandidates) < ledger-scrollable (a REAL scroll beats an
        //   inference) < the target's REMEMBERED section family ("go to fritz" scrolls the sidebar
        //   immediately) — and known-UNscrollable panes sink to the end regardless.
        // The ledger's verdict per candidate pane, read ONCE each. A sort comparator runs O(n log n)
        // times over an answer that cannot change mid-sort, so asking inside the comparator was repeated
        // SQL for a constant — and once reads are counted it would measure the SORT, not the question.
        var paneTruth: [String: Bool] = [:]
        for name in Set(candidates.map(\.name)) {
            if let known = LocatorMemory.shared.paneScrollable(app: bundleID, role: name) { paneTruth[name] = known }
        }
        // READ-HIT ACCOUNTING: a consultation counts as USEFUL only if it moved the probe order — the
        // ranking is the only thing these reads feed, so an unchanged order means the memory agreed with
        // the visual evidence and changed nothing. Off the gate this is one bool test per reach.
        let accounting = LocatorMemory.shared.readHitsEnabled
        func order() -> [String] { accounting ? candidates.map(\.name) : [] }
        var rankingBefore = order()
        candidates.sort { a, b in
            let aKnown = paneTruth[a.name] == true
            let bKnown = paneTruth[b.name] == true
            return aKnown != bKnown ? aKnown : false
        }
        var paneRankingMattered = accounting && order() != rankingBefore
        if let seen = LocatorMemory.shared.sighting(app: bundleID, target: targetText),
           let sec = seen.section {
            let family = sec   // sections are stored CANONICAL now (bare role) — no truncation needed
            rankingBefore = order()
            candidates.sort { a, b in
                let am = a.name.hasPrefix(family), bm = b.name.hasPrefix(family)
                return am != bm ? am : false
            }
            if accounting, order() != rankingBefore { LocatorMemory.shared.noteUsefulRead(.sighting, app: bundleID) }
        }
        rankingBefore = order()
        candidates.sort { a, b in
            let aUn = paneTruth[a.name] == false
            let bUn = paneTruth[b.name] == false
            return aUn != bUn ? bUn : false
        }
        if accounting, order() != rankingBefore { paneRankingMattered = true }
        if paneRankingMattered { LocatorMemory.shared.noteUsefulRead(.scrollPane, app: bundleID) }
        ScrollLog.d("reach: candidates → " + candidates.map { c in
            c.evidence.likelyScrollsV ? "\(c.name)(evidence: \(c.evidence.why))" : c.name
        }.joined(separator: " · "))

        // INTERACTIVE budget: reach serves a conversing agent, not a flow replay. The default 24
        // scroll iterations × ~1.3s of capture+OCR each meant one wrong pane could eat ~30s and a full
        // miss 40+ (measured: 'Premiere Rush', 38.6s). Half the iterations still cover a couple of
        // screens of list (bisection shrinks steps); memory-seeded jumps land near the target anyway.
        var reachTuning = RelocationTuning.defaults
        reachTuning.maxScrollIterations = 12
        let relocator = ContinuousScrollRelocator(
            inner: LiveStepRelocator(crops: crops, ax: ax),
            driver: CompositeScrollDriver(live: LiveScrollDriver(ax: ax), opaque: OpaqueScrollDriver(ax: ax)),
            tuning: reachTuning)

        // SIBLING-LEDGER seed: if memory knows the target's position in a remembered list relative to
        // something VISIBLE right now, the blind search starts in the right direction ("fritz is 4 rows
        // BELOW the visible Michele" ⇒ down). Numeric on-screen evidence still outranks it in the driver.
        let visibleCores = Set(runs.map { LocatorMemory.core($0.text) }.filter { $0.count >= 3 })
        let seed = LocatorMemory.shared.memberSeed(app: bundleID, target: targetText, visibleCores: visibleCores)
        // Claimed ONCE per reach however this returns (the hunt has many exits), so `useful` stays a
        // subset of the consultations counted above rather than one mark per candidate.
        var seedSteered = false, calibrationUsed = false
        defer {
            if seedSteered { LocatorMemory.shared.noteUsefulRead(.sectionMember, app: bundleID) }
            if calibrationUsed {
                LocatorMemory.shared.noteUsefulRead(.sectionList, app: bundleID)    // the row pitch
                LocatorMemory.shared.noteUsefulRead(.scrollPane, app: bundleID)     // px-per-tick
            }
        }
        if let seed {
            ScrollLog.d("reach: memory seed — '\(targetText)' is \(seed.rowsAway) row(s) \(seed.direction > 0 ? "below" : "above") '\(seed.anchorLabel)' in \(seed.family)")
        }
        // COLD target: never sighted in this app, no order memory. The full probe (every pane + the
        // whole window, each with bisection and stall reversal) is how a wrong guess costs 40+ seconds
        // (measured: 'Desktop', which lived in a dropdown). With no evidence anywhere, probe only the
        // two most likely panes and fail fast — the honest miss with guidance beats the long hunt.
        if seed == nil, LocatorMemory.shared.sighting(app: bundleID, target: targetText) == nil,
           candidates.count > 2 {
            ScrollLog.d("reach: cold target — capping probe to 2 candidates (was \(candidates.count))")
            candidates = Array(candidates.prefix(2))
        }

        // THE PLAN'S PANE CAP, on top of the cold-target one above: accessibility already told the
        // caller how much this hunt can still teach it, and a capped hunt reports the cap rather than
        // presenting its short search as the whole app (`panesTotal` below).
        let panesTotal = candidates.count
        if let cap = plan.panes, candidates.count > cap {
            ScrollLog.d("reach: hunt plan caps the probe to \(cap) of \(candidates.count) candidates")
            candidates = Array(candidates.prefix(cap))
        }

        var lastMethod = "no-container"
        var panesWalked = 0
        var stoppedEarly = false
        let reachClock = ContinuousClock()
        let reachStart = reachClock.now
        func elapsed() -> Double {
            Double(reachStart.duration(to: reachClock.now).components.seconds)
                + Double(reachStart.duration(to: reachClock.now).components.attoseconds) / 1e18
        }
        for (bounds, name, evidence) in candidates {
            // Total wall budget: don't START another pane past it — the guided honest_miss the caller
            // composes from memory beats a minute of probing (the model can always call reach again).
            if reachStart.duration(to: reachClock.now) > .seconds(plan.seconds) {
                ScrollLog.d("reach: \(plan.seconds)s budget spent — stopping before '\(name)'")
                lastMethod = "budget-exhausted"
                stoppedEarly = true
                break
            }
            let regionPx = CGRect(x: bounds.minX * W, y: bounds.minY * H,
                                  width: bounds.width * W, height: bounds.height * H).integral
            let regionTexts = runs.filter { regionPx.contains(CGPoint(x: $0.boxImagePx.midX, y: $0.boxImagePx.midY)) }.map(\.text)
            let fingerprint = hasher.edgeHash(of: cap.image.cropping(to: regionPx) ?? cap.image)
            // Calibrated first jump: only for the pane family the target is REMEMBERED in, only with
            // real measurements (pitch from the sibling ledger, px-per-tick from past scrolls of this
            // pane), and clamped hard — the verify loop turns any overshoot into one correction step.
            var seedTicks: Int?
            if let seed, name.hasPrefix(seed.family),
               let pitch = LocatorMemory.shared.rowPitch(app: bundleID, family: seed.family),
               let pxPerTick = LocatorMemory.shared.panePxPerTick(app: bundleID, role: name) {
                seedTicks = Self.calibratedSeedTicks(rowsAway: seed.rowsAway, pitchNorm: pitch,
                                                     windowHpx: Double(H), pxPerTick: pxPerTick,
                                                     eventsPerStep: 12)
                // A calibrated first jump exists ONLY because two measurements were remembered — with
                // no memory the search starts blind. Both stores earned this one.
                if seedTicks != nil { calibrationUsed = true; seedSteered = true }
            }
            // Direction: the sibling-ledger seed (knows where the TARGET sits) wins; with no memory,
            // the pane's LIVE evidence orients the blind search — flush with the top ⇒ the hidden
            // content is below ⇒ start down, and vice versa. Both silent ⇒ the driver's default.
            let evidenceDir: Int? = evidence.moreBelow != evidence.moreAbove
                ? (evidence.moreBelow ? 1 : -1) : nil
            // The seed is useful when it points somewhere the LIVE evidence would not have: agreeing
            // with the pixels is not the ledger changing an outcome.
            if let d = seed?.direction, d != evidenceDir { seedSteered = true }
            let snapshot = ScrollContainerSnapshot(
                id: "section-scroll:\(name)", axPath: nil, axes: [.vertical],
                boundsNormalized: bounds, scrollFractionAtCapture: .zero,
                contentSizeAtCapture: nil, regionFingerprint: fingerprint, ocrTextsAtCapture: regionTexts,
                preferredDirection: seed?.direction ?? evidenceDir, seedTicksPerEvent: seedTicks)
            let descriptor = Descriptor(
                id: UUID(), version: 1, created: now, lastVerified: now,
                app: AppContext(bundleID: facts.bundle, windowTitlePattern: facts.title,
                                windowSizeAtCapture: CGSize(width: facts.frame.width, height: facts.frame.height), backingScale: scale),
                ax: AXDescriptor(available: false, path: [], leafAttrs: nil),
                visual: VisualDescriptor(cropRef: "", cropSize: .zero, contextCropRef: "", contextMarginPx: 0, edgeHash: "", stateVariants: []),
                text: TextDescriptor(selfText: targetText, neighbors: []),
                geometry: GeometryDescriptor(windowRelative: CGPoint(x: bounds.midX, y: bounds.midY), sizePx: .zero,
                                             anchor: Anchor(type: "window_origin", offsetPx: .zero),
                                             scrollContainersAtCapture: [snapshot]),
                appSpecific: [:], thresholds: .defaults)
            // The shipped scroll-aware relocate, verbatim: scrolls THIS pane until the cascade's
            // text-constellation stage locates `targetText`, verifying each hop. No crop ⇒ stages
            // 2/3a/4 miss cleanly; stage 3b carries it.
            let result = await relocator.relocate(descriptor)
            lastMethod = result.method.rawValue
            panesWalked += 1
            if result.isHit, result.method != .offscreen, let rect = result.elementRectScreenPt {
                LocatorMemory.shared.recordPane(app: bundleID, role: name, axis: "v", scrollable: true, pxPerTick: nil)
                return Reached(found: true, method: "\(result.method.rawValue) in \(name)",
                               screenPoint: CGPoint(x: rect.midX, y: rect.midY),
                               panesWalked: panesWalked, panesTotal: panesTotal, seconds: elapsed())
            }
            ScrollLog.d("reach: '\(targetText)' not in \(name) (\(result.method.rawValue)) — next candidate")
        }
        return Reached(found: false, method: lastMethod, screenPoint: nil,
                       panesWalked: panesWalked, panesTotal: panesTotal,
                       stoppedEarly: stoppedEarly || panesWalked < panesTotal, seconds: elapsed())
    }
}
