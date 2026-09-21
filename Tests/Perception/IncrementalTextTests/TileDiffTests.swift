//
//  TileDiffTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import XCTest
@testable import IncrementalText

/// Builds a deterministic sRGB RGBA8 image on a light background.
func tileImage(width: Int, height: Int, paint: (CGContext) -> Void = { _ in }) throws -> CGImage {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    paint(context)
    return try XCTUnwrap(context.makeImage())
}

/// The hash grid a partial read stands on: identical frames dirty nothing, one pixel dirties one
/// tile, and two frames that are not comparable say so rather than guess.
final class TileDiffTests: XCTestCase {

    func testIdenticalFramesHaveNoDirtyTiles() throws {
        let first = try XCTUnwrap(TileDiff.grid(try tileImage(width: 300, height: 200), tile: 128))
        let second = try XCTUnwrap(TileDiff.grid(try tileImage(width: 300, height: 200), tile: 128))
        XCTAssertEqual(first.cols, 3)
        XCTAssertEqual(first.rows, 2)
        XCTAssertEqual(TileDiff.dirtyRects(from: first, to: second), [])
    }

    func testOnePixelChangeDirtiesExactlyItsTile() throws {
        let before = try tileImage(width: 300, height: 200)
        let after = try tileImage(width: 300, height: 200) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 200, y: 200 - 150 - 1, width: 1, height: 1))   // image pixel (200, 150)
        }
        let dirty = try XCTUnwrap(TileDiff.dirtyRects(
            from: try XCTUnwrap(TileDiff.grid(before, tile: 128)),
            to  : try XCTUnwrap(TileDiff.grid(after, tile: 128))
        ))
        XCTAssertEqual(dirty, [CGRect(x: 128, y: 128, width: 128, height: 72)], "tile (1,1), clipped to the frame")
    }

    func testDifferentGeometryIsNotComparable() throws {
        let grid = try XCTUnwrap(TileDiff.grid(try tileImage(width: 300, height: 200), tile: 128))
        let wider = try XCTUnwrap(TileDiff.grid(try tileImage(width: 301, height: 200), tile: 128))
        let finer = try XCTUnwrap(TileDiff.grid(try tileImage(width: 300, height: 200), tile: 64))
        XCTAssertNil(TileDiff.dirtyRects(from: grid, to: wider))
        XCTAssertNil(TileDiff.dirtyRects(from: grid, to: finer))
    }

    func testCoalesceMergesTouchingRects() {
        let merged = TileDiff.coalesce([
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 10, y: 0, width: 10, height: 10),
            CGRect(x: 50, y: 50, width: 5, height: 5),
        ])
        XCTAssertEqual(merged, [CGRect(x: 0, y: 0, width: 20, height: 10),
                                CGRect(x: 50, y: 50, width: 5, height: 5)])
    }
}
