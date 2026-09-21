//
//  IncrementalTextRecognizer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore
import Synchronization
import VisionText

/// IncrementalTextRecognizer fills `TextRecognizing` by decorating another recognizer: it hashes the
/// frame by tiles, reads only the lines the changed tiles touch, and merges the result with the runs
/// it kept from the frame before.
///
/// The state is the point, and it is the decorator's own. `ScenePipeline` reads no environment and
/// keeps nothing between calls, and that rule stands: the pipeline still asks one question and gets
/// one answer. What is remembered, the previous tile grid and the previous runs, lives behind a
/// mutex here, in the adapter that earns something by remembering.
///
/// The whole frame is read again whenever the memory cannot be trusted: no previous frame, a frame
/// of a different size, a different accuracy than the retained runs were read at, a crop the image
/// refuses, or a plan whose rects are not worth cropping for. Every one of those answers exactly
/// what the inner recognizer alone would have answered, so nothing downstream can tell the
/// difference except in time.
///
/// The mutex is held across the inner read. Recognition of one window is a sequence, not a fan-out,
/// and serializing it is what keeps the retained frame and the runs describing the same instant.
public final class IncrementalTextRecognizer: TextRecognizing {

    /// What the previous frame left behind: its tile grid, its runs, and the level they were read
    /// at. All three have to match for a partial read to be honest.
    private struct Retained {
        var grid    : TileGrid
        var runs    : [RecognizedText]
        var accuracy: TextRecognitionAccuracy
    }

    private let inner : any TextRecognizing
    private let tile  : Int
    private let memory = Mutex<Retained?>(nil)

    /// Creates a recognizer over `inner`, Vision by default. `tile` is the hash granularity; the
    /// default is the measured one and a caller has no reason to move it outside a benchmark.
    public init(inner: any TextRecognizing = VisionTextRecognizer(), tile: Int = TileDiff.defaultTile) {
        self.inner = inner
        self.tile  = tile
    }

    /// Forgets the previous frame, so the next call reads the whole image. For a caller that knows
    /// the window it is watching has changed to a different one.
    public func forget() {
        memory.withLock { $0 = nil }
    }

    public func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return try memory.withLock { retained -> [RecognizedText] in

            func readWholeFrame(retaining grid: TileGrid?) throws -> [RecognizedText] {
                let runs = try inner.recognizeText(in: image, accuracy: accuracy)
                retained = grid.map { Retained(grid: $0, runs: runs, accuracy: accuracy) }
                return runs
            }

            guard frame.width > 0, frame.height > 0 else { return try readWholeFrame(retaining: nil) }
            guard let grid = TileDiff.grid(image, tile: tile) else { return try readWholeFrame(retaining: nil) }
            guard let previous = retained, previous.accuracy == accuracy,
                  let dirty = TileDiff.dirtyRects(from: previous.grid, to: grid)
            else { return try readWholeFrame(retaining: grid) }

            // Not one tile moved: the answer is last frame's answer, and the recognizer is not asked.
            guard !dirty.isEmpty else {
                retained = Retained(grid: grid, runs: previous.runs, accuracy: accuracy)
                return previous.runs
            }

            let (rects, kept) = IncrementalTextPlan.plan(dirty: dirty, previous: previous.runs, frame: frame)
            guard !IncrementalTextPlan.prefersFullRead(rects: rects, in: frame) else {
                return try readWholeFrame(retaining: grid)
            }

            var fresh: [RecognizedText] = []
            for rect in rects {
                let clipped = rect.integral.intersection(frame)
                guard clipped.width >= 1, clipped.height >= 1,
                      let crop = image.cropping(to: clipped) else {
                    return try readWholeFrame(retaining: grid)
                }
                fresh += try inner.recognizeText(in: crop, accuracy: accuracy).map {
                    RecognizedText(
                        text    : $0.text,
                        pixelBox: $0.pixelBox.offsetBy(dx: clipped.minX, dy: clipped.minY)
                    )
                }
            }
            let runs = kept + fresh
            retained = Retained(grid: grid, runs: runs, accuracy: accuracy)
            return runs
        }
    }
}
