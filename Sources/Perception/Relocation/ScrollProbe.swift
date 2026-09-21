import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import CVBackend
import LocatorCore

/// The MICRO-SCROLL PROBE: nudge a few wheel lines and WATCH A FIXED REGION under the cursor. If those
/// pixels change, something there scrolls — measured, not inferred — and a reverse nudge puts the user's
/// view back. Cheap enough (a couple of captures) to run before committing to a real scroll, so the
/// caller never burns seconds pushing a pane that was never going to move.
///
/// Answers: does it scroll · roughly how many pixels per tick · and (via the watched rect) WHERE.
/// The animation guard is the round trip: undo the nudge and the region must look like it did before.
/// A video or spinner keeps changing and won't come back, so it reports `inconclusive` rather than
/// teaching the memory a lie.
public enum ScrollProbe {
    public struct Result: Sendable {
        /// true = the watched pixels moved and came back; false = genuinely nothing moved;
        /// nil = couldn't tell (capture failed, or the region animates on its own) — learn NOTHING.
        public let scrolled: Bool?
        /// The moved region, normalized to the window (only when scrolled == true).
        public let movedRectNorm: CGRect?
        /// Image pixels the content moved per wheel tick (only when scrolled == true).
        public let pxPerTick: Double?
    }

    /// Probe at `pointNorm` (window-normalized) in `bundleID`'s frontmost window, WATCHING a fixed
    /// region (`watchNorm`, default a patch around the point). Nudges down, then up if down did
    /// nothing (a pane resting at its bottom must not read as dead), and ALWAYS nudges back.
    ///
    /// The decision is deliberately the simplest one that can be right: **did the pixels in that fixed
    /// region change?** An earlier version tried to locate the moved BAND and measure its shift by
    /// template matching — cleverer, and it reported live panes dead, because a window-wide diff drags
    /// in chrome and periodic content defeats the matcher. Watch one region, ask one question.
    public static func probe(bundleID: String, pointNorm: CGPoint, watchNorm: CGRect? = nil,
                             timing: ScrollTiming = .standard,
                             capture: WindowCaptureService = WindowCaptureService()) async -> Result {
        let t = StageTimer("scrollProbe \(bundleID)")
        let axEngine = await MainActor.run { AXEngine() }
        let winOpt = await MainActor.run { ScrollWindow.resolve(bundleID: bundleID, ax: axEngine) }
        guard let win = winOpt else { return Result(scrolled: nil, movedRectNorm: nil, pxPerTick: nil) }
        t.stamp("window-resolve")
        let point = CGPoint(x: win.frame.minX + pointNorm.x * win.frame.width,
                            y: win.frame.minY + pointNorm.y * win.frame.height)

        guard let before = try? await capture.captureMatchingWindow(
            bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame) else {
            return Result(scrolled: nil, movedRectNorm: nil, pxPerTick: nil)
        }
        t.stamp("capture before")

        // The WATCHED region, in image pixels: the caller's rect (the candidate pane) or a patch around
        // the cursor. A pane-sized region is better than a tiny patch — the cursor can easily sit in a
        // gap between cards, where nothing changes however hard the pane scrolls.
        let W = before.pixelSize.width, H = before.pixelSize.height
        let watch = (watchNorm ?? CGRect(x: pointNorm.x - 0.15, y: pointNorm.y - 0.15, width: 0.30, height: 0.30))
        let watchPx = CGRect(x: max(0, watch.minX * W), y: max(0, watch.minY * H),
                             width: min(W, watch.width * W), height: min(H, watch.height * H)).integral
        guard watchPx.width > 24, watchPx.height > 24,
              let beforePatch = before.image.cropping(to: watchPx) else {
            return Result(scrolled: nil, movedRectNorm: nil, pxPerTick: nil)
        }

        // DIRECTION-BLIND on purpose: this asks "does anything here scroll", so it tries one sign and
        // then the other and never claims which way is which. (Which sign means DOWN is a measured
        // property of the machine — see `WheelPolarity` — and the pane-scroll bursts are what measure it.)
        for tick in [Int32(-1), Int32(1)] {
            nudge(bundleID: win.bundle, at: point, wheel: tick)
            try? await Task.sleep(for: .milliseconds(timing.nudgeSettleMs))
            guard let after = try? await capture.captureMatchingWindow(
                    bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame),
                  let afterPatch = after.image.cropping(to: watchPx) else { continue }

            t.stamp("nudge \(tick) + capture")
            let changed = OpaqueScrollDriver.regionChangeFraction(before: beforePatch, after: afterPatch)
            guard changed > 0.01 else { continue }   // this direction is at its end — try the other

            // It moved. Measure how far (nice-to-have), then PUT IT BACK.
            let shiftPx = profileShift(before: rowProfile(beforePatch), after: rowProfile(afterPatch), maxLag: 120)
                .map { Double(abs($0)) }
            nudge(bundleID: win.bundle, at: point, wheel: -tick)
            try? await Task.sleep(for: .milliseconds(timing.nudgeSettleMs))

            // ANIMATION GUARD: after undoing the nudge the region should look like it did before. A
            // video/spinner keeps changing and won't come back — refuse to learn anything from it.
            if let restored = try? await capture.captureMatchingWindow(
                bundleID: win.bundle, title: win.title, axWindowFrameGlobalPt: win.frame),
               let p = restored.image.cropping(to: watchPx),
               OpaqueScrollDriver.regionChangeFraction(before: beforePatch, after: p) > changed * 0.6 {
                return Result(scrolled: nil, movedRectNorm: nil, pxPerTick: nil)
            }
            t.stamp("undo + animation guard — done")
            let norm = CGRect(x: watchPx.minX / W, y: watchPx.minY / H,
                              width: watchPx.width / W, height: watchPx.height / H)
            return Result(scrolled: true, movedRectNorm: norm,
                          pxPerTick: shiftPx.map { $0 / Double(nudgeEvents) })
        }
        t.stamp("both directions dead — done")
        return Result(scrolled: false, movedRectNorm: nil, pxPerTick: nil)
    }

    /// Events per nudge. NOT one: this codebase already learned that single wheel events get dropped
    /// (the opaque driver posts 12 per step, "8 was flaky"), and a one-event probe duly reported every
    /// pane dead — including panes that visibly scroll. Four 1-line events is still a MICRO scroll
    /// (~4 rows) and still ~50ms, but it actually lands.
    static let nudgeEvents = 4

    /// A micro wheel nudge at a point, with the hover discipline the opaque driver paid for (warp +
    /// real motion deltas so the app registers hover; `.line` units; non-coalesced).
    private static func nudge(bundleID: String, at point: CGPoint, wheel: Int32) {
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
            let src = CGEventSource(stateID: .hidSystemState)
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: point.x - 5, y: point.y - 5), mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            for _ in 0..<nudgeEvents {
                if let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                   wheel1: wheel, wheel2: 0, wheel3: 0) {
                    e.flags.insert(.maskNonCoalesced)
                    e.post(tap: .cghidEventTap)
                }
                usleep(UInt32(ScrollTiming.standard.burstGapMs) * 1000)
            }
            sem.signal()
        }
        sem.wait()
    }

    /// Row-mean brightness profile of a patch — the 1-D signal a VERTICAL shift slides.
    static func rowProfile(_ img: CGImage) -> [Double] {
        let h = min(512, img.height)
        guard h > 8, let p = grayPixels(img, w: 48, h: h) else { return [] }
        return (0..<h).map { y in (0..<48).reduce(0.0) { $0 + Double(p[y * 48 + $1]) } / 48 }
    }

    /// Per-row INK SIGNATURE: each row's mean brightness in each of 8 column bands, so two rows that
    /// share an average but put their ink in different places stay distinguishable.
    ///
    /// This exists because the row MEAN above cannot answer "which way". Averaging a row to one number
    /// throws away everything except how much ink it holds — and on EVENLY SPACED content (a text
    /// document's lines, a file list's rows, a track list) all that survives is the pitch, which looks
    /// the same slid either way. Measured live: a 900-line TextEdit document and a Finder list both
    /// scrolled visibly and read as "direction unreadable" on the mean, every single burst, so the wheel
    /// sign could never be learned from the two surfaces that matter most. Eight bands keep the
    /// horizontal layout of each line ("Arial Black" and "Arial Narrow" differ in where the ink falls),
    /// which is what breaks the tie.
    static func rowSignature(_ img: CGImage, bands: Int = 8) -> [[Double]] {
        let h = min(512, img.height)
        let w = bands * 8
        guard h > 8, bands > 0, let p = grayPixels(img, w: w, h: h) else { return [] }
        return (0..<h).map { y in
            (0..<bands).map { b in
                (0..<8).reduce(0.0) { $0 + Double(p[y * w + b * 8 + $1]) } / 8
            }
        }
    }

    /// Column-mean brightness profile — the same signal for the SIDEWAYS axis, which the horizontal
    /// scroll verb aligns to learn which way a strip slid (`HorizontalScroller.contentSlidePx`).
    static func columnProfile(_ img: CGImage) -> [Double] {
        let w = min(512, img.width)
        guard w > 8, let p = grayPixels(img, w: w, h: 48) else { return [] }
        return (0..<w).map { x in (0..<48).reduce(0.0) { $0 + Double(p[$1 * w + x]) } / 48 }
    }

    /// Best lag aligning two 1-D brightness profiles, by SAD over the overlap — rows for the vertical
    /// axis, columns for the horizontal one. nil when the best alignment is no better than not moving at
    /// all: same geometry, changed pixels = a repaint, not a scroll. The lag is the NEGATIVE of the
    /// content's displacement (it indexes `after` by `y - lag`), which is why the callers that care
    /// about direction flip its sign.
    static func profileShift(before: [Double], after: [Double], maxLag: Int) -> Int? {
        align(before: before.map { [$0] }, after: after.map { [$0] }, maxLag: maxLag)?.lag
    }

    /// WHICH WAY DID THE VIEW GO, from the pixels alone: POSITIVE = the view scrolled UP (the content
    /// moved down the screen, revealing what was above it), negative = the view scrolled down, nil = no
    /// direction that can be trusted.
    ///
    /// The sign is MEASURED, not derived: real captures of a TextEdit view scrolled visibly down (checked
    /// by eye) align at lag −120, and up at +120, so the lag IS the view's direction. Magnitude is in
    /// signature rows (at most 512 for the pane), which for a pane shorter than that are its own pixels.
    ///
    /// This is the FALLBACK direction witness — for a pane with no labels to compare, an opaque canvas.
    /// The primary one is `UserScrollCalibration.rigidShift`, which watches named rows move, because on
    /// EVENLY SPACED content this pixel reading refuses to answer (see `signedSlide`) — and evenly spaced
    /// is what a text document and a file list are.
    static func contentSlidePx(before: CGImage, after: CGImage) -> Int? {
        signedSlide(before: rowSignature(before), after: rowSignature(after), maxLag: 120)
    }

    /// The displacement of two row SIGNATURES, but only when its DIRECTION is trustworthy.
    ///
    /// EVENLY SPACED content aligns about as well one way as the other, so the winning lag's sign is a
    /// coin toss. That is harmless for "did it move" (all `profileShift` is asked) and poison for
    /// polarity: one coin toss learned as a wheel sign inverts every later scroll in that app. So a
    /// signed reading also has to WIN AGAINST ITS OWN MIRROR — the best alignment of the opposite sign
    /// must be clearly worse. Content that is *identical* row to row (a table of empty cells, a striped
    /// canvas) can never clear that bar, which is correct: there is nothing there to read a direction
    /// from, and refusing is the honest answer.
    static func signedSlide(before: [[Double]], after: [[Double]], maxLag: Int) -> Int? {
        guard let a = align(before: before, after: after, maxLag: maxLag),
              a.sadOppositeSign > a.sad * directionMargin else { return nil }
        return a.lag
    }

    /// How much worse the mirrored alignment has to be before a slide's SIGN is believed.
    ///
    /// MEASURED, on grained synthetic panes (`VerticalSlideTests`' frames plus ±8 levels of independent
    /// per-frame noise, so the SAD floor is realistic rather than exactly zero) AND on real captures
    /// dumped by `debug-scroll --dump`:
    ///
    ///   aperiodic content, real slide     ratio **56–78** (6px…90px, both directions)
    ///   periodic rows, synthetic          ratio **1.01–1.09** — and a wildly wrong lag with it
    ///                                     (a 4px slide read as −84)
    ///   real TextEdit prose               ratio **1.04–1.34** (the lag's sign was right, but the
    ///                                     mirror fits nearly as well: text lines are evenly spaced)
    ///   real Finder list rows             no alignment at all, at any burst size
    ///
    /// So 1.5 accepts the aperiodic case by three orders of magnitude and REFUSES real text and lists.
    /// That is deliberate, not a failure to tune: the reading it would give there is a coin toss, and a
    /// coin toss learned as a wheel sign inverts every later scroll in that app. Those surfaces have a
    /// witness that cannot alias — their own named rows (`UserScrollCalibration.rigidShift`) — and this
    /// one exists for the panes that have no labels to offer.
    static let directionMargin = 1.5

    struct Alignment {
        /// The winning lag: `after[y - lag]` holds what `before[y]` did, so the content moved by `-lag`.
        let lag: Int
        /// Mean absolute profile difference at `lag` — how well that alignment fits.
        let sad: Double
        /// The best fit among lags of the OPPOSITE sign: how well the profiles align if the content had
        /// moved the other way. Close to `sad` means the direction cannot be read (periodic content).
        let sadOppositeSign: Double
    }

    /// The alignment behind both readings above, over rows of one or more channels (a row mean is the
    /// one-channel case; a row signature the eight-channel one). Scans each sign's lags separately so
    /// the mirror's fit falls out of the same pass the winner does.
    static func align(before: [[Double]], after: [[Double]], maxLag: Int) -> Alignment? {
        let n = min(before.count, after.count)
        guard n > 3 * maxLag, let channels = before.first?.count, channels > 0,
              after.first?.count == channels else { return nil }
        func sad(_ lag: Int) -> Double {
            var s = 0.0; var c = 0
            for y in max(0, lag)..<min(n, n + lag) where y - lag < n {
                let b = before[y], a = after[y - lag]
                for k in 0..<channels { s += abs(b[k] - a[k]) }
                c += channels
            }
            return c > 0 ? s / Double(c) : .infinity
        }
        var down = (lag: 0, sad: Double.infinity)   // negative lags: the content moved DOWN
        var up = (lag: 0, sad: Double.infinity)     // positive lags: the content moved UP
        for lag in -maxLag...maxLag where lag != 0 {
            let s = sad(lag)
            if lag < 0 { if s < down.sad { down = (lag, s) } }
            else if s < up.sad { up = (lag, s) }
        }
        let best = down.sad <= up.sad ? down : up
        let mirror = down.sad <= up.sad ? up.sad : down.sad
        // A real scroll aligns MARKEDLY better at its lag than at zero; require a clear win and a
        // non-trivial distance.
        let s0 = sad(0)
        guard abs(best.lag) >= 2, best.sad < s0 * 0.6 else { return nil }
        return Alignment(lag: best.lag, sad: best.sad, sadOppositeSign: mirror)
    }

    /// Bounding rect of rows/columns whose pixels differ meaningfully. Coarse by design (8× downsample):
    /// this finds WHERE the change lives; the shift measurement above decides WHAT it was.
    static func changedBand(before: CGImage, after: CGImage) -> CGRect? {
        let w = before.width, h = before.height
        guard w > 32, h > 32, after.width == w, after.height == h else { return nil }
        let dw = max(32, w / 8), dh = max(32, h / 8)
        guard let gb = grayPixels(before, w: dw, h: dh), let ga = grayPixels(after, w: dw, h: dh) else { return nil }
        var rowChanged = [Bool](repeating: false, count: dh)
        var colChanged = [Bool](repeating: false, count: dw)
        for y in 0..<dh {
            var diffs = 0
            for x in 0..<dw where abs(Int(gb[y * dw + x]) - Int(ga[y * dw + x])) > 12 {
                diffs += 1
                colChanged[x] = true
            }
            rowChanged[y] = diffs > dw / 50   // ≥2% of the row's pixels changed
        }
        guard let y0 = rowChanged.firstIndex(of: true), let y1 = rowChanged.lastIndex(of: true),
              let x0 = colChanged.firstIndex(of: true), let x1 = colChanged.lastIndex(of: true),
              y1 > y0 else { return nil }
        let sx = Double(w) / Double(dw), sy = Double(h) / Double(dh)
        return CGRect(x: Double(x0) * sx, y: Double(y0) * sy,
                      width: Double(x1 - x0 + 1) * sx, height: Double(y1 - y0 + 1) * sy).integral
    }

    private static func grayPixels(_ img: CGImage, w: Int, h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
