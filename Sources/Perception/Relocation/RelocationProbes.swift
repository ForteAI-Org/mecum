import CoreGraphics
import LocatorCore

/// The result of running one cascade stage.
public enum StageOutcome: Sendable {
    /// Resolved. `healed`, when non-nil, is an updated descriptor the stage produced (drift-corrected
    /// crop/geometry, bumped version) for the self-heal re-save.
    case hit(rectImagePx: CGRect?, rectScreenPt: CGRect?, confidence: Double, healed: Descriptor?)
    /// The element exists but isn't currently visible (AX says so, or scroll differs from capture).
    case offscreen
    /// Not found at this stage; fall through to the next.
    case miss
}

/// The five cascade capabilities, each independently mockable. The live implementation (M5) wires AX,
/// capture, OCR, the NCC matcher, the segmenter, and the scorer; tests inject a mock to exercise the
/// orchestration without any live dependency.
public protocol RelocationProbes: Sendable {
    func axPath(_ descriptor: Descriptor) async -> StageOutcome              // stage 1
    func geometryNCC(_ descriptor: Descriptor) async -> StageOutcome         // stage 2
    func contextNCC(_ descriptor: Descriptor) async -> StageOutcome          // stage 3a
    func textConstellation(_ descriptor: Descriptor) async -> StageOutcome   // stage 3b
    func segmentationScore(_ descriptor: Descriptor) async -> StageOutcome   // stage 4
}

/// Persists a drift-corrected descriptor (self-heal). The live implementation saves to `DescriptorStore`
/// (which keeps a rollback history); tests record the calls.
public protocol DescriptorHealing: Sendable {
    func heal(_ updated: Descriptor)
}
