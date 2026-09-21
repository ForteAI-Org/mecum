import XCTest
import CoreGraphics
@testable import Relocation

/// The activation decision an act makes before its gesture. Pure, because the two rules it encodes are
/// scars: activating with a pop-up open closes the menu (Pro Tools), and activating an app that is
/// ALREADY frontmost buys nothing while costing the 200ms that follows it (measured: 0.21s of a 1.7s
/// round trip).
final class ActivationPolicyTests: XCTestCase {
    func testActivatesWhenAnotherAppIsFrontmost() {
        XCTAssertTrue(ActivationPolicy.needsActivation(targetPid: 42, frontmostPid: 7, popupOpen: false))
    }

    func testSkipsWhenTheTargetAppIsAlreadyFrontmost() {
        XCTAssertFalse(ActivationPolicy.needsActivation(targetPid: 42, frontmostPid: 42, popupOpen: false))
    }

    func testNeverActivatesWhileAPopupIsOpen() {
        // Even when the popup's owner is NOT frontmost: the activation event cancels menu tracking and
        // the click that follows lands on the window behind the menu.
        XCTAssertFalse(ActivationPolicy.needsActivation(targetPid: 42, frontmostPid: 7, popupOpen: true))
        XCTAssertFalse(ActivationPolicy.needsActivation(targetPid: 42, frontmostPid: 42, popupOpen: true))
    }

    func testActivatesWhenTheFrontmostAppIsUnknown() {
        // No answer from the workspace is not evidence that we are already in front — activate.
        XCTAssertTrue(ActivationPolicy.needsActivation(targetPid: 42, frontmostPid: nil, popupOpen: false))
    }
}
