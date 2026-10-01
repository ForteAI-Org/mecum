import AutomationRuntime
import CoreGraphics
import Foundation
import Perception
import PerceptionCore
import Synchronization
import Testing

struct ProductionPerceptionTests {
    @Test func unchangedPixelsReuseOCRButChangingWindowOrCaptureInvalidatesIt() async throws {
        let reader = CountingText()
        let pipeline = ProductionPerception.pipeline(text: reader)
        let image = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        var window = ScenePipeline.Window(bundleID: "synthetic", appName: "Synthetic", title: "A", windowNumber: 1)
        _ = try await pipeline.perceive(image, of: window)
        _ = try await pipeline.perceive(image, of: window)
        #expect(reader.count == 1)
        window.windowNumber = 2
        _ = try await pipeline.perceive(image, of: window)
        #expect(reader.count == 2)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        _ = try await pipeline.perceive(image, of: window)
        #expect(reader.count == 3)
        window.title = "Popup"
        _ = try await pipeline.perceive(image, of: window)
        #expect(reader.count == 4)
    }
}

private final class CountingText: TextRecognizing {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
        calls.withLock { $0 += 1 }
        return []
    }
}
