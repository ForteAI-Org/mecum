//
//  IncrementalTextRecognizerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore
import XCTest
@testable import IncrementalText

/// Records every image it is handed and answers a fixed script, so a test can say exactly how much
/// of a frame was read again. Test-only: one recognizer is driven by one test method in sequence,
/// which is the invariant the unchecked conformance stands on.
private final class RecordingRecognizer: TextRecognizing, @unchecked Sendable {

    private(set) var sizes: [CGSize] = []
    /// Answers runs for one image, given its size and how many calls came before.
    private let script: (CGSize) -> [RecognizedText]

    init(script: @escaping (CGSize) -> [RecognizedText]) {
        self.script = script
    }

    func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
        let size = CGSize(width: image.width, height: image.height)
        sizes.append(size)
        return script(size)
    }
}

/// The decorator's two promises: an unchanged frame costs no recognition at all, and a changed tile
/// costs exactly the line it touched.
final class IncrementalTextRecognizerTests: XCTestCase {

    private let whole = CGSize(width: 400, height: 300)
    private let lineA = RecognizedText(text: "Format", pixelBox: CGRect(x: 20, y: 20, width: 200, height: 20))
    private let lineB = RecognizedText(text: "Stereo", pixelBox: CGRect(x: 20, y: 200, width: 200, height: 20))

    private func frame(paint: (CGContext) -> Void = { _ in }) throws -> CGImage {
        try tileImage(width: 400, height: 300, paint: paint)
    }

    func testAnUnchangedFrameAnswersTheRetainedRunsWithoutReadingAgain() throws {
        let inner = RecordingRecognizer { [lineA, lineB] _ in [lineA, lineB] }
        let recognizer = IncrementalTextRecognizer(inner: inner)

        let first = try recognizer.recognizeText(in: try frame(), accuracy: .accurate)
        let second = try recognizer.recognizeText(in: try frame(), accuracy: .accurate)

        XCTAssertEqual(first, [lineA, lineB])
        XCTAssertEqual(second, [lineA, lineB], "the second frame answers what the first one read")
        XCTAssertEqual(inner.sizes, [whole], "not one tile moved, so the recognizer was never asked again")
    }

    func testAChangedTileReadsOnlyThatLinesRect() throws {
        // The rect the plan grows to around the changed tile (0,1) and the line it touches.
        let expected = CGSize(width: 240, height: 142)
        let reread = RecognizedText(text: "Mono", pixelBox: CGRect(x: 20, y: 79, width: 200, height: 20))
        let inner = RecordingRecognizer { [whole, lineA, lineB, reread] size in
            size == whole ? [lineA, lineB] : [reread]
        }
        let recognizer = IncrementalTextRecognizer(inner: inner)

        _ = try recognizer.recognizeText(in: try frame(), accuracy: .accurate)
        let runs = try recognizer.recognizeText(in: try frame { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 300 - 200 - 4, width: 4, height: 4))   // image pixel (30, 200)
        }, accuracy: .accurate)

        XCTAssertEqual(inner.sizes, [whole, expected], "only the changed line's rect was cropped and read")
        // The untouched line survives verbatim; the fresh run comes back in frame coordinates.
        XCTAssertEqual(runs, [lineA, RecognizedText(text: "Mono",
                                                    pixelBox: CGRect(x: 20, y: 200, width: 200, height: 20))])
    }

    func testAFrameOfADifferentSizeIsReadWhole() throws {
        let inner = RecordingRecognizer { [lineA] _ in [lineA] }
        let recognizer = IncrementalTextRecognizer(inner: inner)

        _ = try recognizer.recognizeText(in: try frame(), accuracy: .accurate)
        _ = try recognizer.recognizeText(in: try tileImage(width: 401, height: 300), accuracy: .accurate)

        XCTAssertEqual(inner.sizes, [whole, CGSize(width: 401, height: 300)],
                       "a resized window has no comparable grid, so the whole frame is read")
    }

    func testADifferentAccuracyIsReadWhole() throws {
        let inner = RecordingRecognizer { [lineA] _ in [lineA] }
        let recognizer = IncrementalTextRecognizer(inner: inner)

        _ = try recognizer.recognizeText(in: try frame(), accuracy: .accurate)
        _ = try recognizer.recognizeText(in: try frame(), accuracy: .fast)

        XCTAssertEqual(inner.sizes, [whole, whole],
                       "runs read at one level never stand in for the other")
    }
}
