import Foundation
import CoreGraphics

/// The minimal window facts ``WindowCorrelator`` needs. The live `SCWindow` conforms to this; tests
/// supply plain structs. There is **no shared public ID** between AX and ScreenCaptureKit, so
/// correlation is done from these public signals (bundle id + frame + title + z-order).
public protocol CorrelatableWindow {
    var bundleID: String? { get }
    var title: String? { get }
    /// Window frame in top-left global points (matches AX window frames and CGWindow bounds).
    var frameGlobalPt: CGRect { get }
    var isOnScreen: Bool { get }
    /// Window layer / z-order; lower is more frontmost.
    var windowLayer: Int { get }
}
