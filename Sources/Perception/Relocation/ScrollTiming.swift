
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
    /// (one event gets dropped), and it leaves about half the pane in view.
    public static var calibrationNudge: ScrollTiming {
        var t = standard
        t.burstEvents = 4
        return t
    }

    public init() {}
    public init(burstSettleMs: Int, nudgeSettleMs: Int, burstGapMs: Int, hoverMs: Int, burstEvents: Int) {
        self.burstSettleMs = burstSettleMs; self.nudgeSettleMs = nudgeSettleMs
        self.burstGapMs = burstGapMs; self.hoverMs = hoverMs; self.burstEvents = burstEvents
    }
}
