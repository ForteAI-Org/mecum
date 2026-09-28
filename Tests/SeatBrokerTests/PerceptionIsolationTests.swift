//
//  PerceptionIsolationTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation
import Perception
import PerceptionCore
import Testing

/// Records the thread the pipeline's own synchronous work ran on. A section
/// detector is called inline in `perceive`, not from one of its child tasks,
/// so it answers for the body itself.
private final class ThreadWitness: SectionDetecting, @unchecked Sendable {
    private(set) var ranOnMainThread: Bool?
    func sections(in image: CGImage, protecting text: [CGRect]) throws -> [CGRect] {
        ranOnMainThread = Thread.isMainThread
        return []
    }
}

/// The seat observes from the main actor, and the pipeline's synchronous
/// stages — the region filter, the sections, `assemble`, and the pixel control
/// state reader, which renders the frame once per candidate — must not run
/// there: while they do, nothing else on the main thread runs, the cursor
/// fence's tap included.
///
/// `ScenePipeline.perceive` is `@concurrent`, which is what holds this. The
/// targets enable `NonisolatedNonsendingByDefault`, so without that attribute
/// a nonisolated async function would inherit this test's main actor and every
/// stage below would be main-thread work.
@MainActor
@Test func perceivesOffTheMainThreadWhenTheCallerIsTheMainActor() async throws {
    let witness = ThreadWitness()
    let pipeline = ScenePipeline(text: EmptyTextRecognizer(), sections: witness)
    let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    _ = try await pipeline.perceive(context.makeImage()!,
                                    of: ScenePipeline.Window(bundleID: "b", appName: "App", title: "T"))

    #expect(witness.ranOnMainThread == false)
}

private struct EmptyTextRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
}
