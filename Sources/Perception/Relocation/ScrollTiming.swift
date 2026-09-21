import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import LocatorCore

/// THE SCROLL CLOCK — every sleep the scroll verb pays, in one place, each one carrying the measurement
/// that set it. They used to be literals scattered across `PaneScroller`, `ScrollProbe` and
/// `HorizontalScroller` (350ms + 200ms×2 + 12×12ms + 320ms + …), which is how a 3.1–3.7s scroll step
/// happened: nobody could see the sum.
///
/// MEASURED 2026-08-21 with `locator debug-scroll` (the harness below), release build, on four live
/// surfaces that break scrolling differently: TextEdit (AppKit text view, 600 lines), Finder (list view
/// and — for the sideways axis — column view), Pro Tools (opaque canvas, legacy `.line`-only) and
/// Premiere. The harness posts one burst and then captures the watched pane back to back; a capture is
/// ~0.11s, so its resolution is ~110ms and "stable at the first sample" is the strongest statement it
/// can make.
///
///   settle after a full burst   Every surface, every config: the pane was ALREADY FINAL at the first
///                               capture (+109…175ms after the last wheel event) and Δ-to-previous was
///                               0.0000 for every later sample. TextEdit moved 14.4% of the pane's
///                               pixels, Finder column view slid 111px, Pro Tools 1.6%. Nothing was
///                               still in flight. 350ms → 150ms (and the judging capture itself adds
///                               ~110ms on top).
///   settle after a micro nudge  Same, with a 4-event nudge: final at the first capture (+148ms),
///                               shift 23px, Δprev 0.0000 after. 200ms → 120ms.
///   burst gap                   12 events at 12ms / 6ms / 3ms on TextEdit delivered the SAME scroll:
///                               Δbefore 0.1443 and shift 6px in all three, both directions. So the gap
///                               was pure waiting. 12ms → 6ms (saves 72ms per burst; 3ms saves 36ms
///                               more and sits closer to the "dropped events" edge — not worth it).
///   burst events                UNCHANGED at 12. "8 was flaky" is a scar from the opaque driver, and
///                               the matrix confirms 8 events deliver a genuinely shorter scroll
///                               (Δbefore 0.0734 vs 0.1443) — events are the scroll, not the wait.
///   hover                       20ms after the warp + jiggle. Measured by delivering the whole
///                               sideways burst on Finder's column view at hover=20 (111px slide, i.e.
///                               nothing dropped); the horizontal path used to wait 60ms with a WEAKER
///                               hover (one mouseMoved, no warp) — it now uses the same discipline as
///                               the vertical one, which is what was measured.
///
/// Anything here that changes must change with a printed `debug-scroll` run in the commit message.
public struct ScrollTiming: Sendable {
    /// After a full wheel burst, before judging movement.
    public var burstSettleMs: Int = 150
    /// After a 4-event micro nudge (the probe) — less inertia to wait out than a full burst.
    public var nudgeSettleMs: Int = 120
    /// Between wheel events inside one burst.
    public var burstGapMs: Int = 6
    /// After the warp + jiggle that establishes hover, before the first wheel event.
    public var hoverMs: Int = 20
    /// Wheel events per burst. 12, because "8 was flaky" on the opaque driver — a measured scar, kept.
    public var burstEvents: Int = 12

    public static let standard = ScrollTiming()

    /// The one-time WHEEL-SIGN calibration nudge: the standard clock, but FOUR events instead of twelve.
    ///
    /// Measured: even 12 events of ONE line each scrolls a Finder list further than a whole viewport (a
    /// wheel "line" is ~3 rows there) — the pixel change was 0.0576 against a full 12×3 burst's 0.0553,
    /// i.e. indistinguishable, and not one named row survived in both frames. A step with no overlap has
    /// no direction to read. Four events is this codebase's smallest burst that reliably lands
    /// (`ScrollProbe.nudgeEvents`; one event gets dropped), and it leaves about half the pane in view.
    public static var calibrationNudge: ScrollTiming {
        var t = standard
        t.burstEvents = ScrollProbe.nudgeEvents
        return t
    }

    public init() {}
    public init(burstSettleMs: Int, nudgeSettleMs: Int, burstGapMs: Int, hoverMs: Int, burstEvents: Int) {
        self.burstSettleMs = burstSettleMs; self.nudgeSettleMs = nudgeSettleMs
        self.burstGapMs = burstGapMs; self.hoverMs = hoverMs; self.burstEvents = burstEvents
    }
}

/// The harness that produced the numbers above, kept so they can be re-measured instead of re-guessed
/// (same reason `debug-compare` is kept for the fast-verification tier). Drives the real wheel at a real
/// window and reports, sample by sample, how the watched pane settles.
public enum ScrollLab {
    public struct Sample: Sendable {
        /// Milliseconds after the LAST wheel event of the burst that this capture completed.
        public let atMs: Int
        /// Fraction of the watched region's pixels differing from the pre-burst frame.
        public let changedVsBefore: Double
        /// …and from the previous sample: this is the one that says "still moving".
        public let changedVsPrevious: Double
        /// Rows the pane content slid since the pre-burst frame, where measurable.
        public let shiftPx: Int?
    }

    public struct Run: Sendable {
        public let window: CGRect
        public let pixelSize: CGSize
        public let samples: [Sample]
        /// The watched crop before the burst and after it settled, when the caller asked for them.
        /// Written to disk by `debug-scroll --dump`, so the alignment maths can be re-tuned OFFLINE
        /// against real pixels instead of synthetic ones — the same discipline `debug-segment` gets.
        public let frames: (before: CGImage, after: CGImage)?
    }

    /// Post a burst at `aimNorm` and watch `watchNorm` (both window-normalized) settle.
    ///
    /// `lines` is wheel lines per event, posted RAW: this harness deliberately does NOT go through
    /// `WheelPolarity`, because measuring which sign moves a view which way is one of the things it is
    /// for. (On a natural-scrolling Mac — the default — positive lines scroll the view DOWN; that
    /// measurement, taken here, is what set `WheelPolarity.assumedUpSign`.)
    public static func measure(bundleID: String?, aimNorm: CGPoint, watchNorm: CGRect,
                               events: Int, gapMs: Int, lines: Int, samples: Int,
                               horizontal: Bool = false, hoverMs: Int = ScrollTiming.standard.hoverMs,
                               pixelUnits: Bool = false,
                               capture: WindowCaptureService = WindowCaptureService()) async -> Run? {
        // A named bundle that is not running is a MISS, never a silent fall back to whatever is in
        // front: a harness that measures the wrong app teaches the wrong number. (And the window it
        // picks is the frontmost SUBSTANTIAL one — measuring a 157×17pt phantom is the same lie in a
        // different coat; see `ScrollWindow`.)
        let winOpt = await MainActor.run { ScrollWindow.resolve(bundleID: bundleID, ax: AXEngine()) }
        guard let win = winOpt else { return nil }
        func shoot() async -> (img: CGImage, size: CGSize)? {
            guard let s = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title,
                                                                   axWindowFrameGlobalPt: win.frame) else { return nil }
            return (s.image, s.pixelSize)
        }
        func watched(_ shot: (img: CGImage, size: CGSize)) -> CGImage? {
            shot.img.cropping(to: CGRect(x: watchNorm.minX * shot.size.width, y: watchNorm.minY * shot.size.height,
                                         width: watchNorm.width * shot.size.width,
                                         height: watchNorm.height * shot.size.height).integral)
        }
        guard let first = await shoot(), let before = watched(first) else { return nil }

        let aim = CGPoint(x: win.frame.minX + aimNorm.x * win.frame.width,
                          y: win.frame.minY + aimNorm.y * win.frame.height)
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: win.bundle).first?.activate()
            let src = CGEventSource(stateID: .hidSystemState)
            CGWarpMouseCursorPosition(aim)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: aim.x - 5, y: aim.y - 5), mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: aim, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(hoverMs))
        for _ in 0..<max(1, events) {
            await MainActor.run {
                let units: CGScrollEventUnit = pixelUnits ? .pixel : .line
                guard let e = horizontal
                        ? CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: units,
                                  wheelCount: 2, wheel1: 0, wheel2: Int32(lines), wheel3: 0)
                        : CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: units,
                                  wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0) else { return }
                e.flags.insert(.maskNonCoalesced)
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(gapMs))
        }
        let burstEnd = Date()

        var out: [Sample] = []
        var previous = before
        for _ in 0..<max(1, samples) {
            guard let shot = await shoot(), let patch = watched(shot) else { continue }
            out.append(Sample(atMs: Int(Date().timeIntervalSince(burstEnd) * 1000),
                              changedVsBefore: OpaqueScrollDriver.regionChangeFraction(before: before, after: patch),
                              changedVsPrevious: OpaqueScrollDriver.regionChangeFraction(before: previous, after: patch),
                              shiftPx: horizontal
                                ? HorizontalScroller.contentSlidePx(before: before, after: patch)
                                : ScrollProbe.profileShift(before: ScrollProbe.rowProfile(before),
                                                           after: ScrollProbe.rowProfile(patch), maxLag: 120)))
            previous = patch
        }
        return Run(window: win.frame, pixelSize: first.size, samples: out,
                   frames: (before: before, after: previous))
    }
}
