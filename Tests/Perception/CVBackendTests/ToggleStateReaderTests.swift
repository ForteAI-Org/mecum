import XCTest
import CoreGraphics
@testable import CVBackend

final class ToggleStateReaderTests: XCTestCase {
    /// Synthetic switch: dark track + bright knob on one side (top-left authored coords).
    private func toggle(knobRight: Bool, w: Int = 40, h: Int = 20) -> CGImage {
        makeCGImage(width: w, height: h) { ctx in
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(gray: 0.95, alpha: 1)
            let knob = CGRect(x: knobRight ? w - h : 0, y: 0, width: h, height: h)
            ctx.fillEllipse(in: knob)
        }
    }

    func testKnobRightReadsOn() { XCTAssertEqual(ToggleStateReader.state(of: toggle(knobRight: true)), "on") }
    func testKnobLeftReadsOff() { XCTAssertEqual(ToggleStateReader.state(of: toggle(knobRight: false)), "off") }

    func testFlatCropIsUnknown() {
        let flat = makeCGImage(width: 40, height: 20) { ctx in
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertNil(ToggleStateReader.state(of: flat))   // no guess on ambiguity
    }

    func testShapeGate() {
        XCTAssertTrue(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 36, height: 18)))   // 2.0
        XCTAssertTrue(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 72, height: 36)))   // retina
        XCTAssertFalse(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 18, height: 18)))  // square icon
        XCTAssertFalse(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 200, height: 14))) // divider/text line
        XCTAssertFalse(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 16, height: 8)))   // too small
    }

    func testOversizedPillIsNotToggleShaped() {   // measured: a 161×86 browser box shape-passed as a switch
        XCTAssertFalse(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 161, height: 86)))
        XCTAssertTrue(ToggleStateReader.isToggleShaped(CGRect(x: 0, y: 0, width: 88, height: 44)))    // retina macOS switch
    }
}
