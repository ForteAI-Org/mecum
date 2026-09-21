import CoreGraphics
import ScreenCaptureKit

/// Enumerates capturable windows. The first call to `SCShareableContent.current` triggers the
/// Screen Recording TCC prompt. Nonisolated — call only from within a nonisolated async domain
/// (e.g. `WindowCaptureService`), never directly from the main actor, since `[SCWindow]` is
/// non-`Sendable` and must not cross an actor boundary.
public enum WindowEnumerator {
    public static func windows() async throws -> [SCWindow] {
        try await SCShareableContent.current.windows
    }
}

/// `SCWindow` already exposes `title` (`String?`), `isOnScreen` (`Bool`), and `windowLayer` (`Int`),
/// which satisfy the protocol directly; only the two renamed accessors are needed here.
extension SCWindow: CorrelatableWindow {
    public var bundleID: String? { owningApplication?.bundleIdentifier }
    public var frameGlobalPt: CGRect { frame }
}
