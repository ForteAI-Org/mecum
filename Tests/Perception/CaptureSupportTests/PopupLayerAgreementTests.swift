import XCTest
@testable import CaptureSupport
@testable import LocatorCore

/// `MissGuide` must call an opened pop-up a pop-up and not "a new window", but it lives in the LEAF
/// module — it cannot import the capture layer that owns the layer range, so it mirrors it. This test
/// is the seam that keeps the mirror honest: the two ranges are asserted equal here, where both are
/// visible, so a future change to the capture-side range fails a test instead of silently making a
/// guided miss describe DaVinci's dropdown as a window that appeared.
final class PopupLayerAgreementTests: XCTestCase {
    func testTheMirroredPopupLayerRangeStillMatchesTheCaptureLayer() {
        for layer in -5...600 {
            XCTAssertEqual(WindowCaptureService.isPopupLayer(layer), MissGuide.popupLayers.contains(layer),
                           "layer \(layer): the mirror drifted from WindowCaptureService.isPopupLayer")
        }
    }
}
