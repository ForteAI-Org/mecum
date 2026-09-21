import Foundation
import CoreGraphics

/// Process-wide relocation tuning, separate from the per-descriptor ``Thresholds``.
///
/// These are the knobs the §7.5 tuning loop adjusts in one place: the stage-4 scorer weights, the
/// geometry gaussian falloff, the multi-scale NCC ladder, and search-region sizes. Defaults encode
/// the spec values so tests can pin known numbers.
public struct RelocationTuning: Codable, Equatable, Sendable {
    // Stage-4 scorer weights (must sum to 1.0 — validated by ``weightsAreNormalized``).
    public var weightVisual: Double         // 0.30
    public var weightText: Double           // 0.25
    public var weightNeighbors: Double      // 0.20
    public var weightGeometry: Double       // 0.15
    public var weightClassSize: Double      // 0.10

    /// Gaussian σ for the geometry term, as a fraction of the window dimension.
    public var geometrySigmaFraction: Double // 0.08
    /// Text score floor for elements that have no text at all.
    public var noTextScoreFloor: Double      // 0.5
    /// Size-match tolerance for the class/size term.
    public var sizeTolerance: Double         // 0.25 (±25%)

    // Search regions (pixels) and the multi-scale ladder for NCC.
    public var stage2SearchRegionPx: CGFloat // 150
    public var captureNeighborhoodPx: CGFloat // 400 (opaque-canvas capture-time ROI)
    public var multiScaleLadder: [CGFloat]   // e.g. [0.8, 0.9, 1.0, 1.1, 1.25]
    /// Only self-heal (re-save drift-corrected geometry) on hits at least this confident, so a marginal
    /// match can't compound drift into the stored descriptor.
    public var selfHealMinConfidence: Double // 0.90
    // An element box bigger than EITHER limit is "coarse" (a panel, not a control) and rejected at
    // capture in favor of a small click-centered box, so a point with no tight element still yields a
    // precise, relocatable crop.
    public var maxElementAreaFraction: Double // 0.15 (of the window)
    public var maxElementSidePx: CGFloat      // 500
    public var fallbackBoxPx: CGFloat         // 64 — click-centered capture box when no precise element
    /// Cap the search image's long side for the full-window context-NCC (stage 3a) so it isn't an
    /// O(window × template) blowup when an element has moved out of the stage-2 region.
    public var stage3aMaxWindowDimension: CGFloat // 900
    // --- scroll-aware engine (Phase 1) — the continuous scroll-into-view loop ---
    public var maxScrollIterations: Int          // 24 — hard cap; steps are 3× smaller since the gentle 12×1 seed, so the hunt needs more room
    public var scrollStepFraction: Double        // 0.2 — outward search step when restoring capture pos misses
    public var contentMovedEpsilon: Double       // 0.003 — below this measured movement counts as "didn't move" (small adaptive steps register ~0.005, so keep this low)
    /// Consecutive sub-epsilon bursts required to declare end-of-list, but only AFTER the pane has moved
    /// at least once (a proven-live pane gets this larger budget; a dead pane still bails after 2 — so a
    /// single dropped burst can't abandon a far target mid-list).
    public var endOfListStallLimit: Int          // 3
    // Opaque synthetic scroll. Pro Tools is a LEGACY wheel consumer (it ignores continuous/`.pixel`
    // gestures), so each step posts a SMALL burst of discrete `.line` wheel events, hover-registered +
    // non-coalesced + settle-until-stable. Steps are kept small (≤ ~half a viewport) so one burst can't
    // skip past the target's visible window; the driver re-infers direction each step (overshoot reverses).
    public var opaqueScrollStepEvents: Int        // 12 — FIXED line events per step (the reliable-delivery count; 8 was flaky). Never shrinks.
    public var opaqueScrollTicksPerEvent: Int     // 1 — SEED line-units per event. Seeded at the CONVERGED size: 12×1 ≈ 4 Pro Tools tracks,
                                                  // which the bisection itself documented as "lands inside the ~8-track window". The old seed
                                                  // of 3 (36 line-units ≈ 360px on a responsive pane) read as violent whole-screen leaps on
                                                  // Slack (Ron: "the scrolls are too heavy") and only bought coarse-phase speed — paid back
                                                  // via a larger iteration budget instead.
    public var opaqueScrollFloorTicks: Int        // 1 — smallest ticks-per-event a halved step may reach (events stay 12, so this never enters the flaky sub-reliable zone)
    public var opaqueScrollEventsPerViewport: Int // 10 — (legacy/unused: superseded by opaqueScrollStepEvents)
    // DEPRECATED — a phased-PIXEL gesture was tried and Pro Tools ignored it entirely (`.pixel`/continuous
    // events move it 0.000); reverted to the `.line` burst above. Kept only so decoded JSON / call sites
    // stay valid; no longer read.
    public var opaqueViewportPixelFraction: Double // 0.85 — (unused)

    public init(
        weightVisual: Double = 0.30,
        weightText: Double = 0.25,
        weightNeighbors: Double = 0.20,
        weightGeometry: Double = 0.15,
        weightClassSize: Double = 0.10,
        geometrySigmaFraction: Double = 0.08,
        noTextScoreFloor: Double = 0.5,
        sizeTolerance: Double = 0.25,
        stage2SearchRegionPx: CGFloat = 150,
        captureNeighborhoodPx: CGFloat = 400,
        multiScaleLadder: [CGFloat] = [0.8, 0.9, 1.0, 1.1, 1.25],
        selfHealMinConfidence: Double = 0.90,
        maxElementAreaFraction: Double = 0.15,
        maxElementSidePx: CGFloat = 500,
        fallbackBoxPx: CGFloat = 64,
        stage3aMaxWindowDimension: CGFloat = 900,
        maxScrollIterations: Int = 24,
        scrollStepFraction: Double = 0.2,
        contentMovedEpsilon: Double = 0.003,
        endOfListStallLimit: Int = 3,
        opaqueViewportPixelFraction: Double = 0.85,
        opaqueScrollStepEvents: Int = 12,
        opaqueScrollTicksPerEvent: Int = 1,
        opaqueScrollFloorTicks: Int = 1,
        opaqueScrollEventsPerViewport: Int = 10
    ) {
        self.weightVisual = weightVisual
        self.weightText = weightText
        self.weightNeighbors = weightNeighbors
        self.weightGeometry = weightGeometry
        self.weightClassSize = weightClassSize
        self.geometrySigmaFraction = geometrySigmaFraction
        self.noTextScoreFloor = noTextScoreFloor
        self.sizeTolerance = sizeTolerance
        self.stage2SearchRegionPx = stage2SearchRegionPx
        self.captureNeighborhoodPx = captureNeighborhoodPx
        self.multiScaleLadder = multiScaleLadder
        self.selfHealMinConfidence = selfHealMinConfidence
        self.maxElementAreaFraction = maxElementAreaFraction
        self.maxElementSidePx = maxElementSidePx
        self.fallbackBoxPx = fallbackBoxPx
        self.stage3aMaxWindowDimension = stage3aMaxWindowDimension
        self.maxScrollIterations = maxScrollIterations
        self.scrollStepFraction = scrollStepFraction
        self.contentMovedEpsilon = contentMovedEpsilon
        self.endOfListStallLimit = endOfListStallLimit
        self.opaqueViewportPixelFraction = opaqueViewportPixelFraction
        self.opaqueScrollStepEvents = opaqueScrollStepEvents
        self.opaqueScrollTicksPerEvent = opaqueScrollTicksPerEvent
        self.opaqueScrollFloorTicks = opaqueScrollFloorTicks
        self.opaqueScrollEventsPerViewport = opaqueScrollEventsPerViewport
    }

    public static let defaults = RelocationTuning()

    /// The five scorer weights should sum to 1.0 (within a small epsilon).
    public var weightsAreNormalized: Bool {
        let sum = weightVisual + weightText + weightNeighbors + weightGeometry + weightClassSize
        return abs(sum - 1.0) < 1e-9
    }
}
