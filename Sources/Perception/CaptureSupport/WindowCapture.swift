import CoreGraphics
import ScreenCaptureKit

/// Captures a single window to a native-scale `CGImage`. Behind a protocol so a persistent-`SCStream`
/// backend can replace the one-shot `SCScreenshotManager` later without touching callers.
///
/// Intentionally **nonisolated** (not `@MainActor`): `SCWindow` is non-`Sendable`, so all SCK work is
/// confined to a single nonisolated async domain (see `WindowCaptureService`) and the window reference
/// never crosses an actor boundary. Only `Sendable` data (the `CGImage`) leaves.
public protocol WindowCapture: Sendable {
    func capture(window: SCWindow) async throws -> CGImage
}
