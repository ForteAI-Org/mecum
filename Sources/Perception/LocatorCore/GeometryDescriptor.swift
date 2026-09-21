import Foundation
import CoreGraphics

/// The spatial view of a picked element, resize-tolerant via window-normalized coordinates.
public struct GeometryDescriptor: Codable, Equatable, Sendable {
    /// Normalized 0..1 within the window — survives window resize.
    public var windowRelative: CGPoint
    public var sizePx: CGSize
    public var anchor: Anchor
    /// Optional scroll position(s) of containing scroll views at capture time, for offscreen detection.
    public var scrollStateAtCapture: [String: Double]?
    // --- scroll-aware engine (Phase 1; all additive + optional → legacy descriptors decode with nil) ---
    /// Scroll containers enclosing the element at capture (innermost last), for scroll-into-view.
    public var scrollContainersAtCapture: [ScrollContainerSnapshot]?
    /// The element's position in the innermost container's scroll-INVARIANT frame (elementFrame −
    /// scrollOffset, in window px). "Make this coordinate visible" — deterministic scroll target.
    public var contentSpaceRect: CGRect?
    /// Cheap signature of the scroll-region layout at capture; if it changed at recall, recorded scroll
    /// calibration is stale and is re-discovered rather than trusted.
    public var windowScrollFingerprint: String?

    public init(windowRelative: CGPoint, sizePx: CGSize, anchor: Anchor, scrollStateAtCapture: [String: Double]? = nil,
                scrollContainersAtCapture: [ScrollContainerSnapshot]? = nil, contentSpaceRect: CGRect? = nil,
                windowScrollFingerprint: String? = nil) {
        self.windowRelative = windowRelative
        self.sizePx = sizePx
        self.anchor = anchor
        self.scrollStateAtCapture = scrollStateAtCapture
        self.scrollContainersAtCapture = scrollContainersAtCapture
        self.contentSpaceRect = contentSpaceRect
        self.windowScrollFingerprint = windowScrollFingerprint
    }
}

public enum ScrollAxis: String, Codable, Equatable, Sendable { case vertical, horizontal }

/// A scrollable container enclosing a picked element, captured for scroll-into-view at replay. The AX
/// path lets it be re-resolved on native apps; `nil` marks a CV-only (opaque-app) container.
public struct ScrollContainerSnapshot: Codable, Equatable, Sendable {
    public var id: String                          // stable key (axPath hash or app-specific, e.g. "track_list")
    public var axPath: [AXPathStep]?               // path to the AXScrollArea (nil ⇒ CV-only/opaque)
    public var axes: [ScrollAxis]
    public var boundsNormalized: CGRect            // viewport within the window (0..1, resize-tolerant)
    public var scrollFractionAtCapture: CGPoint    // (x, y) 0..1 at capture (AX); .zero for opaque (no fraction)
    public var contentSizeAtCapture: CGSize?       // for px↔fraction conversion (nil if unknown)
    // --- opaque (no-AX) containers: the CV substitutes for an AX scroll fraction ---
    /// Perceptual hash of the region at capture — a "is this the same pane?" gate at replay (nil for AX).
    public var regionFingerprint: String?
    /// OCR runs inside the region at capture — recorded evidence for inferring scroll DIRECTION (nil for AX).
    public var ocrTextsAtCapture: [String]?
    /// Memory-seeded search direction (+1 down / −1 up) from the SIBLING ledger ("fritz is 3 ranks below
    /// the visible Michele"). Optional + additive: absent in stored descriptors ⇒ nil ⇒ old behavior.
    public var preferredDirection: Int?
    /// Memory-CALIBRATED first-step size (line-units per event): rows-away × remembered row pitch ÷
    /// measured px-per-tick. The bisection refines from here; absent ⇒ the gentle default seed.
    public var seedTicksPerEvent: Int?

    public init(id: String, axPath: [AXPathStep]? = nil, axes: [ScrollAxis],
                boundsNormalized: CGRect, scrollFractionAtCapture: CGPoint, contentSizeAtCapture: CGSize? = nil,
                regionFingerprint: String? = nil, ocrTextsAtCapture: [String]? = nil, preferredDirection: Int? = nil, seedTicksPerEvent: Int? = nil) {
        self.id = id
        self.axPath = axPath
        self.axes = axes
        self.boundsNormalized = boundsNormalized
        self.scrollFractionAtCapture = scrollFractionAtCapture
        self.contentSizeAtCapture = contentSizeAtCapture
        self.regionFingerprint = regionFingerprint
        self.ocrTextsAtCapture = ocrTextsAtCapture
        self.preferredDirection = preferredDirection
        self.seedTicksPerEvent = seedTicksPerEvent
    }
}

/// What the element's position tracks against under non-uniform resize.
public struct Anchor: Codable, Equatable, Sendable {
    public var type: String                 // "container_edge" / "window_origin"
    public var container: String?           // e.g. "track_list"
    public var offsetPx: CGPoint

    public init(type: String, container: String? = nil, offsetPx: CGPoint) {
        self.type = type
        self.container = container
        self.offsetPx = offsetPx
    }
}
