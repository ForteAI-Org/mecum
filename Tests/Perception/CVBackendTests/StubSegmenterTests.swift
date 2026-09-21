import XCTest
import CoreGraphics
@testable import CVBackend

final class StubSegmenterTests: XCTestCase {
    func testReturnsEmpty() {
        let img = makeCGImage(width: 16, height: 16) {
            $0.setFillColor(gray: 0.5, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        XCTAssertTrue(StubSegmenter().segment(in: img, region: nil).isEmpty)
    }
}
