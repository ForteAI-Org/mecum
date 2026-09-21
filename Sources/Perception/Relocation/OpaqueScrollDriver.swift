import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

/// `ScrollDriving` for OPAQUE apps (no `AXScrollArea` — Pro Tools track list, games). There is no AX
/// scroll fraction to read or set, so this:
///  • re-captures the window and gates on a perceptual-hash fingerprint of the recorded region (same pane?),
///  • infers a first scroll DIRECTION from the recorded vs visible labels,
///  • scrolls by posting a synthetic `CGEvent` scroll-wheel over the region (cursor warped in first),
///  • measures how far the content MOVED via NCC strip-displacement — the substitute for an AX fraction.
/// The `ContinuousScrollRelocator` loop and the gated cascade are unchanged; this only moves pixels and
/// reports movement, so it can never manufacture a click.
public struct OpaqueScrollDriver: ScrollDriving {
    let ax: AXEngine
    let capture: WindowCaptureService
    let matcher: NCCTemplateMatcher
    let ocr: OCREngine
    let hasher: SobelPerceptualHasher
    let tuning: RelocationTuning
    let settleSeconds: Double
    let session = ScrollSession()

    /// Per-session adaptive-bisection state. A reference box so the value-type driver (reused across all
    /// flow steps) can carry mutable per-session magnitude. `@unchecked Sendable`: `beginPlan`/`apply` are
    /// async but the loop calls them STRICTLY SERIALLY within one session (no concurrency within a
    /// session) — same rationale as `LiveRelocationProbes.RelocateFrame`; no lock needed. Reset per
    /// flow step in `beginPlan` so nothing leaks between targets.
    final class ScrollSession: @unchecked Sendable {
        var currentTicks: Int = 0       // adaptive displacement (line-units per event); 0 = unseeded
        var lastMovingDir: Int?         // last direction that PRODUCED movement (changed > epsilon)
        var searchDir: Int = 1          // BLIND search direction (no text to infer from); flips once on stall
        var blindFlipped = false        // have we already reversed the blind search this step?
        var sawNumericEvidence = false  // inferDirection found the target's number FAMILY on screen at least once
        func reset(seedTicks: Int, seedDir: Int) {
            currentTicks = seedTicks; lastMovingDir = nil; searchDir = seedDir; blindFlipped = false
            sawNumericEvidence = false
        }
    }

    public init(ax: AXEngine, capture: WindowCaptureService = WindowCaptureService(),
                matcher: NCCTemplateMatcher = NCCTemplateMatcher(), ocr: OCREngine = OCREngine(),
                hasher: SobelPerceptualHasher = SobelPerceptualHasher(), tuning: RelocationTuning = .defaults,
                settleSeconds: Double = 0.22) {
        self.ax = ax; self.capture = capture; self.matcher = matcher; self.ocr = ocr
        self.hasher = hasher; self.tuning = tuning; self.settleSeconds = settleSeconds
    }

    public func beginPlan(for d: Descriptor) async -> ScrollPlan? {
        guard let snap = Self.opaqueSnapshot(d) else { Self.log("no opaque scroll container recorded"); return nil }
        guard let win = await windowFrame(d), let captured = try? await capture.captureMatchingWindow(
            bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame),
            let regionPx = Self.regionPixels(snap.boundsNormalized, imagePixelSize: captured.pixelSize) else {
            Self.log("opaque: no window/capture/region"); return nil }

        // Same pane? Compare the live region's perceptual hash to capture; a changed layout → no scroll.
        if let fp = snap.regionFingerprint, let crop = captured.image.cropping(to: regionPx) {
            let dist = hasher.distance(hasher.edgeHash(of: crop), fp)
            Self.log("opaque: region fingerprint dist \(dist)")
            if dist > 220 { Self.log("opaque: pane changed (dist \(dist)) — not scrolling"); return nil }
        }
        // Direction: trailing-number ordering of the target vs visible labels when available, else up.
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: win.frame.origin,
                                          backingScale: win.frame.width > 0 ? captured.pixelSize.width / win.frame.width : 2,
                                          imagePixelSize: captured.pixelSize)
        let visible = ocr.recognizeText(in: captured.image, ctx: ctx, accurate: true).map(\.text)
        // Direction: a target WITH a trailing number is ordered against the visible labels (Pro Tools
        // "Audio N") — but ONLY when its number family is actually on screen (inferDirection nil = no
        // evidence). A target without evidence (no text, OR a numeric name whose family isn't visible —
        // "Zebra Target 42" over prose, measured live) is BLIND: seed DOWNWARD — targets usually lie
        // further down a list — and let `reverseOnStall` flip it to up if that boundary is hit first.
        let inferred = Self.inferDirection(target: d.text.selfText, visible: visible)
        // Priority: live numeric evidence > the SIBLING-LEDGER seed (remembered list order) > blind down.
        let dir = inferred ?? snap.preferredDirection ?? 1
        // Fresh per-target adaptive state: seed the full reliable displacement, no movement yet (so the
        // first step can never read as a reversal, and a halved/pinned state from a prior target can't leak).
        session.reset(seedTicks: snap.seedTicksPerEvent ?? max(1, tuning.opaqueScrollTicksPerEvent), seedDir: dir)
        if inferred != nil { session.sawNumericEvidence = true }
        Self.log("opaque: region \(Int(regionPx.width))×\(Int(regionPx.height)), direction \(dir > 0 ? "down" : "up")\(inferred != nil ? "" : " (blind)"), scrolling synthetically")
        return ScrollPlanner.makeOpaquePlan(containerID: snap.id, axis: .vertical, direction: dir,
                                            maxSteps: tuning.maxScrollIterations)
    }

    static func log(_ s: String) {
        guard ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[scroll] \(s)\n".utf8))
    }

    public func apply(_ action: ScrollAction, for d: Descriptor) async -> Double {
        guard case .relativeTicks = action.strategy,
              let snap = d.geometry.scrollContainersAtCapture?.first(where: { $0.id == action.containerID }),
              let win = await windowFrame(d),
              let before = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame),
              let regionPx = Self.regionPixels(snap.boundsNormalized, imagePixelSize: before.pixelSize),
              let beforeRegion = before.image.cropping(to: regionPx) else { return 0 }

        // Pro Tools is a LEGACY wheel consumer: it responds to discrete `.line` scroll events and IGNORES
        // continuous/`.pixel` gestures entirely (a phased-pixel attempt moved it exactly 0.000). So post a
        // burst of `.line` events — but layer on the mechanism-agnostic reliability wins the bare old burst
        // lacked: register HOVER with a real mouseMoved (a CGWarpMouseCursorPosition alone generates no
        // event, so a hover-gated track list can ignore the scroll), re-associate the HID cursor so the warp
        // can't suppress synthetic motion, mark every event NON-COALESCED so WindowServer can't merge/drop
        // the burst, and pace ~12ms.
        let scale = win.frame.width > 0 ? before.pixelSize.width / win.frame.width : 2
        // WHERE to deliver the wheel: park the cursor at the recorded CLICK point (windowRelative scaled to
        // the live window), NOT the region's geometric center. macOS routes a wheel event to the pane UNDER
        // THE CURSOR, so this decides WHICH pane scrolls. The recorded click is by construction inside the
        // pane the user actually scrolled, and stays valid after the target scrolls off-screen (a viewport
        // is fixed on screen; only its content moves). The old center landed on a ruler/transport/wrong pane
        // in multi-pane apps → "scrolling at the wrong places". (deliveryPoint falls back to the region
        // center for the KB-reach sentinel, clamps into the region interior, and jiggles inward — see below.)
        let (point, jiggleOff) = Self.deliveryPoint(windowRelative: d.geometry.windowRelative,
                                                    winFrame: win.frame, regionPx: regionPx, scale: scale)
        Self.log("opaque: cursor → \(Int(point.x)),\(Int(point.y)) (click wr \(String(format: "%.2f", d.geometry.windowRelative.x)),\(String(format: "%.2f", d.geometry.windowRelative.y)))")
        // RE-INFER direction every step from what is CURRENTLY visible vs the target, so an overshoot
        // (a step that scrolled PAST the target) SELF-CORRECTS by reversing instead of marching into a
        // boundary. ADAPTIVE BISECTION on the per-event TICK count (not the event count): the event count
        // stays at the empirically reliable 12 (8 was flaky), and only the DISPLACEMENT shrinks — 12×3
        // ≈ 12 tracks, 12×1 ≈ 4 tracks — so a converged step still delivers reliably yet lands inside the
        // ~8-track window instead of perpetually straddling a gap target (the Audio 9 oscillation). Each
        // genuine direction reversal (a real move one way, then a re-inferred need to go the other way)
        // halves the ticks toward `opaqueScrollFloorTicks`. A non-moving burst NEVER halves (see below),
        // so a dropped burst can't be mistaken for crossing the target.
        let beforeCtx = WindowCoordinateContext(axWindowOriginGlobalPt: win.frame.origin, backingScale: scale, imagePixelSize: before.pixelSize)
        let visible = ocr.recognizeText(in: before.image, ctx: beforeCtx, accurate: true).map(\.text)
        // A target whose number FAMILY is visible re-infers/reverses direction each step (the Pro Tools
        // bisection, UNCHANGED). Without that evidence — no text at all, or a numeric name over unrelated
        // content — the step is BLIND: follow the session's search direction, which `reverseOnStall` flips
        // at a boundary, and do NOT bisect (keep the full stride so the blind hunt covers ground fast).
        let inferred = Self.inferDirection(target: d.text.selfText, visible: visible)
        if inferred != nil { session.sawNumericEvidence = true }
        let stepDir = inferred ?? session.searchDir
        if inferred != nil, session.lastMovingDir != nil, stepDir != session.lastMovingDir {   // genuine crossing → refine
            session.currentTicks = Self.halve(session.currentTicks, floor: tuning.opaqueScrollFloorTicks)
        }
        let events = max(1, tuning.opaqueScrollStepEvents)
        let ticks = max(tuning.opaqueScrollFloorTicks, session.currentTicks)
        // WHICH WAY IS DOWN comes from `WheelPolarity`, not from a hard-coded sign. This driver used to
        // spell the convention out itself — and spelled it the OPPOSITE way round from `PaneScroller`,
        // so on any given Mac one of the two was pushing backwards. (This one happened to be right on a
        // natural-scrolling Mac, which is why the Pro Tools hunt worked; the sign posted here is
        // unchanged on such a machine.) The hunt does not TEACH the polarity — its NCC displacement
        // locks to ~0 on periodic track rows, so it has no trustworthy sign to teach — it consumes what
        // the pane-scroll bursts measured.
        let wheelSign = WheelPolarity.sign(requestedTicks: stepDir,
                                           upSign: WheelPolarity.upSign(app: d.app.bundleID, axis: .vertical))
        let perEvent = Int32(ticks) * Int32(wheelSign)
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: d.app.bundleID).first?.activate()
            let src = CGEventSource(stateID: .hidSystemState)
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            // JIGGLE: a mouseMoved to the point the cursor already occupies carries no delta and can be
            // dropped, leaving hover stale so a LATER burst is ignored (the 3rd+ burst dying mid-list).
            // Move off-point then back, so every burst re-establishes hover with real motion deltas. The
            // offset is INWARD (toward the region center, computed in deliveryPoint) so an edge click point
            // can never jiggle off-window onto another window / the desktop.
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: jiggleOff, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(20))   // let the hover register before scrolling
        for _ in 0..<events {
            await MainActor.run {
                guard let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line,
                                      wheelCount: 1, wheel1: perEvent, wheel2: 0, wheel3: 0) else { return }
                e.flags.insert(.maskNonCoalesced)
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }

        // Settle UNTIL STABLE before measuring. A big `.line` burst triggers Pro Tools' own inertial
        // scrolling; a later burst arriving during that decay gets absorbed (the observed "moved 12 tracks,
        // then 0, then 0"). Poll captures until two consecutive frames are ~identical (motion stopped) or a
        // bounded timeout — so every measurement is of the FINAL state and the next burst starts static.
        try? await Task.sleep(for: .seconds(settleSeconds))
        var afterRegion = beforeRegion
        var prevStable: CGImage?
        for _ in 0..<8 {
            guard let cap = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame),
                  let reg = cap.image.cropping(to: regionPx) else { break }
            afterRegion = reg
            if let p = prevStable, Self.regionChangeFraction(before: p, after: reg) < 0.002 { break }   // motion stopped
            prevStable = reg
            try? await Task.sleep(for: .milliseconds(90))
        }
        // Stall signal: a periodicity-proof mean-abs pixel difference — nonzero on ANY real change, ~0 only
        // when the pane is truly static (blocked / end of list). NCC strip-displacement locks to ~0 on the
        // periodic track rows even after a real scroll, so it is kept only as an informational "approx shift".
        let changed = Self.regionChangeFraction(before: beforeRegion, after: afterRegion)
        let shift = Self.verticalDisplacementFraction(before: beforeRegion, after: afterRegion, matcher: matcher)
        // Advance the bisection reference ONLY on a real, measured move: this is what makes a dropped /
        // boundary burst (changed ≈ 0) invisible to reversal detection — it neither updates the reference
        // direction nor (therefore) triggers a halve. A reversal is then provably a real move one way
        // followed by a real need to go the other = a genuine crossing of the target.
        if changed > tuning.contentMovedEpsilon { session.lastMovingDir = stepDir }
        // CALIBRATION: a reliably-measured displacement teaches the living memory this pane's px-per-
        // tick (image px per line-unit), so the NEXT reach can jump rows-away × pitch in one seeded
        // step. Section-scroll ids carry the pane's role ("section-scroll:sidebar"); NCC shift locks
        // to ~0 on periodic rows, so only meaningful shifts calibrate.
        if abs(shift) >= 0.02, changed > tuning.contentMovedEpsilon,
           let snap = Self.opaqueSnapshot(d), snap.id.hasPrefix("section-scroll:") {
            let role = String(snap.id.dropFirst("section-scroll:".count))
            let unitsDelivered = Double(events) * Double(abs(perEvent))
            if unitsDelivered > 0 {
                let sample = abs(shift) * Double(beforeRegion.height) / unitsDelivered
                LocatorMemory.shared.recordPane(app: d.app.bundleID, role: role, axis: "v",
                                                scrollable: true, pxPerTick: sample)
            }
        }
        Self.log("opaque: \(events)×\(perEvent)-line step \(stepDir > 0 ? "down" : "up") → region changed \(String(format: "%.3f", changed)) (approx shift \(String(format: "%.3f", shift)))")
        return changed
    }

    /// The bounded loop is about to give up. When the search has been BLIND (no text at all, or a numeric
    /// name whose family was NEVER seen on screen — "Zebra Target 42" over prose, measured live) the seeded
    /// direction was only a guess, so flip it ONCE and let the loop hunt the other way — the Slack
    /// DM-below-channels case. A target with VISIBLE numeric evidence already self-reverses on overshoot
    /// within its plan, so it never asks for a second pass. One reversal per step: the search stays finite.
    public func reverseOnStall(for d: Descriptor) async -> Bool {
        guard !session.sawNumericEvidence, !session.blindFlipped else { return false }
        session.blindFlipped = true
        session.searchDir = -session.searchDir
        Self.log("opaque: blind search stalled — reversing to \(session.searchDir > 0 ? "down" : "up")")
        return true
    }

    /// Halve a tick count toward `floor` (round-to-nearest), never below it. The bisection refinement.
    static func halve(_ ticks: Int, floor: Int) -> Int { max(floor, Int((Double(ticks) / 2.0).rounded())) }

    /// The cursor point (GLOBAL POINTS) to deliver the synthetic wheel burst at, plus the inward jiggle
    /// endpoint. macOS scrolls the pane UNDER THE CURSOR, so this is what decides WHICH pane moves. We park
    /// at the recorded CLICK point (`windowRelative` scaled to the live window) — by construction inside the
    /// pane the user scrolled, and still valid after the target scrolls off-screen (the viewport is fixed;
    /// only content moves). The region's geometric center (the old behavior) lands on a ruler/transport/wrong
    /// pane in multi-pane apps. Guards: the KB-reach sentinel `windowRelative == (0.5, 0.5)` (no real click)
    /// falls back to the region center; the point is clamped into the recorded region's interior so a
    /// drifted/self-healed coordinate can't warp onto chrome; and `jiggleOff` is offset INWARD (toward the
    /// region center) so an edge click never jiggles off-window. Pure → unit-tested.
    static func deliveryPoint(windowRelative wr: CGPoint, winFrame: CGRect, regionPx: CGRect, scale: CGFloat,
                              margin: CGFloat = 4, jiggle: CGFloat = 8) -> (point: CGPoint, jiggleOff: CGPoint) {
        let s = scale > 0 ? scale : 2
        // The recorded region in live global points (its center == the old delivery point, exactly).
        let region = CGRect(x: winFrame.minX + regionPx.minX / s, y: winFrame.minY + regionPx.minY / s,
                            width: regionPx.width / s, height: regionPx.height / s)
        let regionCenter = CGPoint(x: region.midX, y: region.midY)
        // No real click recorded (KB-reach fabricates windowRelative = (0.5, 0.5)) → keep the old behavior.
        let hasClick = abs(wr.x - 0.5) > 1e-6 || abs(wr.y - 0.5) > 1e-6
        var point = regionCenter
        if hasClick {
            // Inset margins can't exceed half the region (would invert the clamp on a thin pane).
            let mx = min(margin, max(0, region.width / 2 - 1))
            let my = min(margin, max(0, region.height / 2 - 1))
            let rx = winFrame.minX + wr.x * winFrame.width
            let ry = winFrame.minY + wr.y * winFrame.height
            point = CGPoint(x: min(max(rx, region.minX + mx), region.maxX - mx),
                            y: min(max(ry, region.minY + my), region.maxY - my))
        }
        let jx: CGFloat = point.x <= regionCenter.x ? jiggle : -jiggle
        let jy: CGFloat = point.y <= regionCenter.y ? jiggle : -jiggle
        return (point, CGPoint(x: point.x + jx, y: point.y + jy))
    }

    // MARK: Pure helpers (unit-tested)

    static func opaqueSnapshot(_ d: Descriptor) -> ScrollContainerSnapshot? {
        d.geometry.scrollContainersAtCapture?.first { $0.axPath == nil && $0.regionFingerprint != nil }
    }

    /// Map a 0..1 window-normalized region to integer pixel rect in the captured image.
    static func regionPixels(_ norm: CGRect, imagePixelSize: CGSize) -> CGRect? {
        let r = CGRect(x: norm.minX * imagePixelSize.width, y: norm.minY * imagePixelSize.height,
                       width: norm.width * imagePixelSize.width, height: norm.height * imagePixelSize.height)
            .integral.intersection(CGRect(x: 0, y: 0, width: imagePixelSize.width, height: imagePixelSize.height))
        return (r.isNull || r.width < 8 || r.height < 24) ? nil : r
    }

    /// First scroll direction: −1 (up) if the target's number is below all visible ones, +1 (down) if
    /// above all, else −1 (default up). Direction is only a HINT; the opaque plan tries the opposite too.
    ///
    /// Crucially, numbers are compared ONLY within the target's label FAMILY (e.g. "Audio N"). A
    /// full-window OCR drags in numeric NOISE — timecodes ("00:00:14:11"→11), sample counts
    /// ("1172431"), clip names ("A001_111400"→111400) — whose magnitudes dwarf the track range. Without
    /// family filtering the target's number (e.g. 20) always falls *inside* [min,max] and collapses to
    /// the default (up), so a far-DOWN target is never reached (the observed Pro Tools failure). Fall
    /// back to all numbers only when the target has no usable alphabetic family.
    /// Direction from trailing-number ordering — nil when there's NO EVIDENCE (target has no trailing
    /// number, or its number family isn't among the visible labels). nil means "blind": the caller must
    /// use the session's reversible search direction, never a hardcoded guess (a hardcoded "up" marched
    /// into the top edge forever on a numeric-named target over prose — measured live, 2026-07-02).
    static func inferDirection(target: String?, visible: [String]) -> Int? {
        guard let t = lastInt(target), !visible.isEmpty else { return nil }
        let fam = labelPrefix(target)
        let nums = fam.count >= 3
            ? visible.filter { sameFamily(labelPrefix($0), fam) }.compactMap(lastInt)
            : visible.compactMap(lastInt)
        guard let lo = nums.min(), let hi = nums.max() else { return nil }
        if t < lo { return -1 }   // below all visible in its family → it's above → scroll up
        if t > hi { return 1 }    // above all visible → it's below → scroll down
        return -1                 // inside the visible band → nudge up to center it
    }

    /// Leading run of letters, lowercased, skipping any leading non-letters — the "family" of an OCR
    /// label. "Audio 20 ▾" → "audio", "• Aud4" → "aud", "00:00:14:11" → "" (pure numeric noise).
    static func labelPrefix(_ s: String?) -> String {
        guard let s else { return "" }
        var out = ""; var started = false
        for ch in s {
            if ch.isLetter { out.append(contentsOf: ch.lowercased()); started = true }
            else if started { break }
        }
        return out
    }

    /// Same family iff the alphabetic prefixes are IDENTICAL. The SCROLLING track list (edit lanes +
    /// mixer) uses full names ("Audio 9"); Pro Tools' left TRACKS column shows ABBREVIATED, NON-scrolling
    /// names for ALL tracks ("Aud9", "Ad10"…). Those must NOT be conflated with the full-name family — the
    /// always-present "Aud9" would pin the family max at 9 and break direction inference for "Audio 9"
    /// (9 not > 9 → wrong "up"). A prefix-relationship rule ("aud" ⊂ "audio") made exactly that mistake.
    /// Digits/spaces are already stripped by labelPrefix, so an OCR'd "Audio9" still maps to "audio".
    private static func sameFamily(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && a == b
    }

    /// The LAST integer appearing anywhere in the string (robust to trailing chevrons/units), e.g.
    /// "Audio 20 ▾" → 20. Returns nil if there are no digits.
    static func lastInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        var last: Int?
        var cur = ""
        for ch in s {
            if ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { last = Int(cur); cur = "" }
        }
        if !cur.isEmpty { last = Int(cur) }
        return last
    }

    /// Measured vertical content movement (0..1 of region height) between two same-size region crops,
    /// via NCC strip-displacement. A near-flat / incoherent region (animated meters) scores low → 0.
    static func verticalDisplacementFraction(before: CGImage, after: CGImage, matcher: NCCTemplateMatcher) -> Double {
        let h = before.height, w = before.width
        guard h > 48, w > 0, after.height == h, after.width == w else { return 0 }
        let stripH = max(24, h / 3)
        let stripY = (h - stripH) / 2
        guard let strip = before.cropping(to: CGRect(x: 0, y: stripY, width: w, height: stripH)),
              let m = matcher.match(template: strip, in: after, searchRegion: nil, scales: [1.0], maxTemplateDimension: 128),
              m.score >= 0.6 else { return 0 }
        let dy = abs(m.locationPx.y - CGFloat(stripY))
        return min(1.0, Double(dy) / Double(h))
    }

    /// Mean absolute grayscale difference (0..1) between two crops — a periodicity-proof "did the pane
    /// actually change?" signal for stall detection. A scroll shifts pixels AND swaps which labels are
    /// shown, so any real movement registers; only a pixel-identical frame (scroll ignored / end of
    /// list) returns ~0. Unlike NCC strip-displacement it matches nothing, so periodic rows can't fool it.
    static func regionChangeFraction(before: CGImage, after: CGImage) -> Double {
        let w = min(before.width, after.width), h = min(before.height, after.height)
        guard w > 0, h > 0, let a = grayBytes(before, w, h), let b = grayBytes(after, w, h) else { return 0 }
        var sum = 0.0
        for i in 0..<(w * h) { sum += abs(Double(a[i]) - Double(b[i])) }
        return sum / (Double(w * h) * 255.0)
    }

    /// Render `img` into a fixed w×h 8-bit grayscale buffer (deterministic; scales if sizes differ).
    private static func grayBytes(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    // MARK: Live window frame (Sendable out)

    private struct Win: Sendable { let bundle: String; let title: String?; let frame: CGRect }
    private func windowFrame(_ d: Descriptor) async -> Win? {
        await MainActor.run { () -> Win? in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: d.app.bundleID).first?.processIdentifier else { return nil }
            let appEl = ax.reader.applicationElement(pid: pid)
            ax.reader.setMessagingTimeout(appEl, seconds: 2)
            let windows = ax.reader.windows(of: appEl)
            let regex = try? NSRegularExpression(pattern: d.app.windowTitlePattern)
            let chosen = windows.first(where: { w in
                guard let t = ax.reader.title(w) else { return false }
                return regex?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            }) ?? windows.first
            guard let chosen, let frame = ax.reader.frame(chosen) else { return nil }
            return Win(bundle: d.app.bundleID, title: ax.reader.title(chosen), frame: frame)
        }
    }
}
