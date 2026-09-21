import CoreGraphics
import LocatorCore

/// The confidence cascade: cheapest/most-semantic stage first, short-circuiting on the first hit.
/// Stage 1 (AX path) is the canonical baseline and never self-heals; any *lower* stage that succeeds
/// re-saves a drift-corrected descriptor via the healer. An `.offscreen` from any stage short-circuits
/// (the element exists but isn't visible — the caller can scroll and retry), which is distinct from a
/// genuine `.notFound`.
public struct Relocator: Sendable {
    public let probes: any RelocationProbes
    public let healer: (any DescriptorHealing)?

    public init(probes: any RelocationProbes, healer: (any DescriptorHealing)? = nil) {
        self.probes = probes
        self.healer = healer
    }

    public func relocate(_ descriptor: Descriptor) async -> RelocationResult {
        // (method, runsSelfHeal, probe). Order is the cascade; stage 1 doesn't self-heal.
        // Stage 3b (text) vs 3a (context-NCC) order is DATA-DEPENDENT:
        //  • A TEXT element that MOVED is found by its OCR'd label in ~ms → text BEFORE context-NCC.
        //  • A NO-TEXT element (icon/avatar) has no label to find, so text-constellation only wastes a
        //    full-window OCR (and its neighbor-anchor branch even runs a full-window NCC) — so for it,
        //    run context-NCC (which matches the element's OWN crop full-window) FIRST.
        let text: (RelocationResult.Method, Bool, (Descriptor) async -> StageOutcome) =
            (.textConstellation, true, { await probes.textConstellation($0) })
        let context: (RelocationResult.Method, Bool, (Descriptor) async -> StageOutcome) =
            (.contextNCC, true, { await probes.contextNCC($0) })
        let hasText = descriptor.text.selfText?.isEmpty == false
        let stages: [(RelocationResult.Method, Bool, (Descriptor) async -> StageOutcome)] =
            [(.axPath, false, { await probes.axPath($0) }),
             (.geometryNCC, true, { await probes.geometryNCC($0) })]
            + (hasText ? [text, context] : [context, text])
            + [(.segmentationScore, true, { await probes.segmentationScore($0) })]

        for (method, runsSelfHeal, probe) in stages {
            switch await probe(descriptor) {
            case let .hit(rectImagePx, rectScreenPt, confidence, healed):
                if runsSelfHeal, let healed { healer?.heal(healed) }
                return RelocationResult(elementRectImagePx: rectImagePx, elementRectScreenPt: rectScreenPt,
                                        method: method, confidence: confidence)
            case .offscreen:
                return RelocationResult(method: .offscreen, confidence: 0)
            case .miss:
                continue
            }
        }
        return .notFound
    }
}
