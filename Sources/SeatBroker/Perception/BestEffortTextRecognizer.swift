//
//  BestEffortTextRecognizer.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import IncrementalText
import OSLog
import PerceptionCore
import VisionText

/// `TextRecognizing` over Vision that answers no runs where Vision cannot run
/// at all, instead of failing the whole perception.
///
/// The Perception layer's rule is that a recognizer which cannot run fails the
/// perception, and it is the right rule for an engine whose scene is built out
/// of pixels. The lab is the other case: the seat harvests the accessibility
/// tree in the same pass, so a machine whose Vision text models do not load
/// still perceives a window worth acting on. This Mac is such a machine, and
/// its `CRImageReaderError 1` on every frame is what refusing here costs: no
/// scene at all, rather than a scene without OCR labels.
///
/// The failure is not swallowed. It is logged under the kit's own subsystem
/// each time it happens, so a missing model is read in the log rather than
/// guessed from a map with no text in it.
///
/// Vision is reached through `IncrementalTextRecognizer`, which reads only the
/// lines the changed tiles touch: the seat perceives the same window over and
/// over, so most of each frame is the frame before it. The swallow stays out
/// here, where the policy is, rather than inside a recognizer whose contract
/// is to throw.
struct BestEffortTextRecognizer: TextRecognizing {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    private let vision = IncrementalTextRecognizer(inner: VisionTextRecognizer())

    func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
        do {
            return try vision.recognizeText(in: image, accuracy: accuracy)
        } catch {
            Self.log.error("""
                text recognition unavailable, perceiving this frame without it: \
                \(error.localizedDescription, privacy: .public)
                """)
            return []
        }
    }
}
