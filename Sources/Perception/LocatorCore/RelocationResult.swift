import Foundation
import CoreGraphics

/// The outcome of a relocation attempt.
///
/// Deliberately a pure value type: it carries the resolved rectangles, the winning method, and a
/// confidence — but **not** a live `AXUIElement`. Per the concurrency design, the live handle is
/// non-`Sendable` and must not cross actor boundaries; the Relocation layer re-resolves it on the
/// MainActor (via AX path replay) when the caller actually wants to `AXPress`. This keeps
/// `LocatorCore` free of any ApplicationServices dependency and keeps the result freely `Sendable`.
public struct RelocationResult: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case axPath
        case geometryNCC
        case contextNCC
        case textConstellation
        case segmentationScore
        case offscreen          // AX says it exists but it's scrolled out of view
        case notFound
    }

    /// Element rect in window-local pixels.
    public var elementRectImagePx: CGRect?
    /// Element rect in GLOBAL screen points — what a caller clicks.
    public var elementRectScreenPt: CGRect?
    public var method: Method
    public var confidence: Double           // 0..1

    public init(elementRectImagePx: CGRect? = nil, elementRectScreenPt: CGRect? = nil, method: Method, confidence: Double) {
        self.elementRectImagePx = elementRectImagePx
        self.elementRectScreenPt = elementRectScreenPt
        self.method = method
        self.confidence = confidence
    }

    /// A clean miss.
    public static let notFound = RelocationResult(method: .notFound, confidence: 0)

    /// Whether this result represents a usable hit (i.e. an actual location was resolved).
    public var isHit: Bool {
        switch method {
        case .notFound: return false
        case .offscreen: return true       // exists, just not visible — caller may scroll & retry
        default: return elementRectImagePx != nil || elementRectScreenPt != nil
        }
    }
}
