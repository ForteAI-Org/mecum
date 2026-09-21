import CoreGraphics
import Foundation
@testable import Relocation
import LocatorCore

func makeDescriptor(id: UUID = UUID(), selfText: String? = "B") -> Descriptor {
    Descriptor(
        id: id, version: 1,
        created: Date(timeIntervalSince1970: 1_700_000_000),
        lastVerified: Date(timeIntervalSince1970: 1_700_000_000),
        app: AppContext(bundleID: "com.example.app", windowTitlePattern: ".*",
                        windowSizeAtCapture: CGSize(width: 800, height: 600), backingScale: 2),
        ax: AXDescriptor(available: true, path: [AXPathStep(role: "AXButton", title: "B")],
                         leafAttrs: AXLeafAttrs(role: "AXButton", title: "B")),
        visual: VisualDescriptor(cropRef: "\(id.uuidString).default.png", cropSize: CGSize(width: 24, height: 24),
                                 contextCropRef: "\(id.uuidString).context.png", contextMarginPx: 60, edgeHash: "00"),
        text: TextDescriptor(selfText: selfText),
        geometry: GeometryDescriptor(windowRelative: CGPoint(x: 0.5, y: 0.5), sizePx: CGSize(width: 24, height: 24),
                                     anchor: Anchor(type: "window_origin", offsetPx: .zero)),
        appSpecific: [:], thresholds: .defaults
    )
}

/// Records which stages were probed and returns scripted outcomes (default `.miss`).
final class MockProbes: RelocationProbes, @unchecked Sendable {
    private var outcomes: [String: StageOutcome] = [:]
    private(set) var calls: [String] = []

    func set(_ stage: String, _ outcome: StageOutcome) { outcomes[stage] = outcome }
    private func record(_ stage: String) -> StageOutcome { calls.append(stage); return outcomes[stage] ?? .miss }

    func axPath(_ d: Descriptor) async -> StageOutcome { record("axPath") }
    func geometryNCC(_ d: Descriptor) async -> StageOutcome { record("geometryNCC") }
    func contextNCC(_ d: Descriptor) async -> StageOutcome { record("contextNCC") }
    func textConstellation(_ d: Descriptor) async -> StageOutcome { record("textConstellation") }
    func segmentationScore(_ d: Descriptor) async -> StageOutcome { record("segmentationScore") }
}

final class MockHealer: DescriptorHealing, @unchecked Sendable {
    private(set) var healed: [Descriptor] = []
    func heal(_ updated: Descriptor) { healed.append(updated) }
}
