import XCTest
import CoreGraphics
@testable import CVBackend

final class ConnectedComponentSegmenterTests: XCTestCase {
    func testColorOnlyControlSurvivesBesideBrightChrome() {
        let img = makeCGImage(width: 800, height: 600) { ctx in
            ctx.translateBy(x: 0, y: 600); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(CGColor(srgbRed: 200.0/255, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 40))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 102.0/255, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 300, y: 200, width: 150, height: 60))
        }
        let center = CGPoint(x: 375, y: 230)
        let gray = ConnectedComponentSegmenter(params: .init(useColorEdges: false)).segment(in: img, region: nil)
        let color = ConnectedComponentSegmenter(params: .init(useColorEdges: true)).segment(in: img, region: nil)
        XCTAssertFalse(gray.contains { $0.bboxPx.contains(center) })
        XCTAssertTrue(color.contains { $0.bboxPx.contains(center) && $0.bboxPx.width < 180 })
    }

    func testFindsSeparatedElements() {
        let img = patternImage(width: 300, height: 200, bg: 1.0, rects: [
            (CGRect(x: 20, y: 20, width: 60, height: 40), 0.0),
            (CGRect(x: 150, y: 30, width: 50, height: 50), 0.2),
            (CGRect(x: 100, y: 120, width: 80, height: 50), 0.4),
        ])
        let boxes = ConnectedComponentSegmenter().segment(in: img, region: nil)
        for center in [CGPoint(x: 50, y: 40), CGPoint(x: 175, y: 55), CGPoint(x: 140, y: 145)] {
            XCTAssertTrue(boxes.contains { $0.bboxPx.contains(center) }, "no box covers \(center); boxes=\(boxes.map(\.bboxPx))")
        }
    }

    func testMinAreaFiltersTinyElements() {
        let img = patternImage(width: 200, height: 200, bg: 1.0, rects: [
            (CGRect(x: 10, y: 10, width: 4, height: 4), 0.0),     // tiny
            (CGRect(x: 80, y: 80, width: 60, height: 60), 0.0),   // big
        ])
        let boxes = ConnectedComponentSegmenter(params: .init(minAreaPx: 200)).segment(in: img, region: nil)
        XCTAssertTrue(boxes.contains { $0.bboxPx.contains(CGPoint(x: 110, y: 110)) }, "big element should pass")
        XCTAssertFalse(boxes.contains { $0.bboxPx.contains(CGPoint(x: 12, y: 12)) }, "tiny element should be filtered")
    }

    func testRegionOffsetsBoxesIntoFullImageCoords() {
        let img = patternImage(width: 300, height: 200, bg: 1.0, rects: [
            (CGRect(x: 200, y: 120, width: 50, height: 40), 0.0),
        ])
        let boxes = ConnectedComponentSegmenter().segment(in: img, region: CGRect(x: 180, y: 100, width: 100, height: 80))
        XCTAssertTrue(boxes.contains { $0.bboxPx.contains(CGPoint(x: 225, y: 140)) },
                      "box should cover the element center in full-image coords; boxes=\(boxes.map(\.bboxPx))")
    }

    func testEmptyImageYieldsNoBoxes() {
        let blank = patternImage(width: 100, height: 100, bg: 0.5, rects: [])
        XCTAssertTrue(ConnectedComponentSegmenter().segment(in: blank, region: nil).isEmpty)
    }
}
